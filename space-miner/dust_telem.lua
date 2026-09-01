-- =============================================================================
-- Node ID: MEDINA-DustRelay
-- File:    dust_telem.lua
-- Purpose: Queries the dust storage ME subnet; displays the 10 most critical
--          items (lowest stock/threshold ratio) and broadcasts all tracked
--          stock levels to the broker on port 2026.
--
-- OpenComputers Sides Reference Matrix:
--   0 = Bottom / Down (-Y) | 1 = Top / Up (+Y) | 2 = North (-Z)
--   3 = South (+Z)         | 4 = West (-X)     | 5 = East (+X)
-- =============================================================================

local component     = require("component")
local serialization = require("serialization")
local term          = require("term")
local event         = require("event")
local computer      = require("computer")

local config = dofile("/home/config.lua")

if not component.isAvailable("modem") then error("Missing network card.") end
if not component.isAvailable("gpu")   then error("Requires GPU.")         end

local modem = component.modem
if not modem.isWireless or not modem.isWireless() then
  error("Node requires a T2 Wireless Network Card.")
end

-- Read stock through an ME Interface (via adapter) — it exposes the same
-- network query API as a controller, so this node can sit on a dust subnet
-- without one. A controller is still accepted if that is what is attached.
local me = nil
for addr in component.list("me_interface") do me = component.proxy(addr) break end
if not me then
  for addr in component.list("me_controller") do me = component.proxy(addr) break end
end
if not me then
  error("Missing ME Interface (attach one via an Adapter to read network stock).")
end
-- Proxy methods are callable tables here, not functions, so probe by calling.
if me.getItemsInNetwork == nil then
  error("ME device cannot query the network - check it is joined to the dust subnet.")
end
do
  local ok, err = pcall(me.getItemsInNetwork)
  if not ok then
    -- Report what actually went wrong: on a large network this is usually an
    -- out-of-memory throw, not a wiring problem, and the two need different fixes.
    error("ME query failed: " .. tostring(err))
  end
end

local gpu      = component.gpu
local nodeName = "MEDINA-DustRelay"

modem.setStrength(400)
gpu.setResolution(80, 25)
modem.open(config.ports.command)   -- inbound: broker -> this node (watchlist)

-- ---------------------------------------------------------------------------
-- WATCHLIST
-- What to scan and what each target is. This node cannot dump an entire ME
-- network into one modem packet, so it filters against this list.
--
-- The list is the BROKER's config.conditions, pushed over the command port. It
-- used to be read from this machine's own copy of config.lua, which meant
-- editing what to mine in two places -- and when they drifted, the broker
-- displayed a permanent 0% for every item this node was not scanning.
--
-- Resolution order:
--   1. whatever the broker last sent (authoritative)
--   2. the cached copy of that, so a restart here survives a broker outage
--   3. this machine's config.conditions, so a standalone node still works
-- ---------------------------------------------------------------------------
local WATCHLIST_CACHE = "/home/dust_watchlist.lua"

local thresholds  = {}
local listSource  = "local config"
local listCount   = 0

local function applyWatchlist(list, source)
  thresholds = list
  listSource = source
  listCount  = 0
  for _ in pairs(list) do listCount = listCount + 1 end
end

local function saveWatchlist(list)
  local f = io.open(WATCHLIST_CACHE, "w")
  if not f then return end
  f:write("return {\n")
  for name, threshold in pairs(list) do
    f:write(string.format("  [%q] = %d,\n", name, threshold))
  end
  f:write("}\n")
  f:close()
end

do
  local ok, cached = pcall(dofile, WATCHLIST_CACHE)
  if ok and type(cached) == "table" and next(cached) then
    applyWatchlist(cached, "cache")
  else
    local fallback = {}
    for _, cond in ipairs(config.conditions) do
      fallback[cond.itemName] = cond.amountToMaintain
    end
    applyWatchlist(fallback, "local config")
  end
end

-- Accept a watchlist push from the broker. Cached so the next restart does not
-- have to wait for the broker to come back before it can scan anything.
local function handleMessage(_, _, _, _, _, rawMsg)
  local ok, msg = pcall(serialization.unserialize, rawMsg)
  if not ok or type(msg) ~= "table" then return end
  if msg.protocol ~= "MEDINA_COMMAND" then return end
  if msg.payloadType ~= "DUST_WATCHLIST" or type(msg.data) ~= "table" then return end
  if not next(msg.data) then return end   -- never let an empty list blind us
  applyWatchlist(msg.data, "broker")
  saveWatchlist(msg.data)
end

-- Last scan's outcome, for the status line. A failed query and a genuinely
-- empty network both used to render as an all-red board of zeroes, which is
-- indistinguishable at a glance -- so record which one it was.
local scanState = { ok = true, err = nil, seen = 0, matched = 0 }

local function scanDustStock()
  local stocks = {}
  local success, items = pcall(me.getItemsInNetwork)
  if not success or not items then
    -- Most likely out of memory: getItemsInNetwork builds a table entry per
    -- stack, and on a large main network that can exceed what this machine
    -- has left after loading config.lua.
    scanState = { ok = false, err = tostring(items), seen = 0, matched = 0 }
    return stocks
  end

  local seen, matched = 0, 0
  for _, item in ipairs(items) do
    if item and item.label then
      seen = seen + 1
      if thresholds[item.label] then
        matched = matched + 1
        stocks[item.label] = (stocks[item.label] or 0) + item.size
      end
    end
  end
  scanState = { ok = true, err = nil, seen = seen, matched = matched }
  return stocks
end

local function buildSortedList(stocks)
  local list = {}
  for name, threshold in pairs(thresholds) do
    local stock = stocks[name] or 0
    table.insert(list, { name=name, stock=stock, threshold=threshold, ratio=stock/threshold })
  end
  table.sort(list, function(a, b) return a.ratio < b.ratio end)
  return list
end

local function drawStaticFrame()
  term.clear()
  gpu.setForeground(0x00FF00)
  print("================================================================================")
  print(" MEDINA RELAY NETWORK  |  NODE: " .. nodeName)
  print("================================================================================")
  gpu.setForeground(0x888888)
  term.setCursor(2, 5)
  io.write(string.format("  %-29s  %20s  %s", "ITEM (lowest fill first)", "STOCK / TARGET", "FILL"))
  term.setCursor(2, 6)
  io.write(string.rep("-", 76))
end

local function formatQty(n)
  if n >= 1000000 then return string.format("%.1fm", n / 1000000)
  elseif n >= 1000 then return string.format("%.0fk", n / 1000)
  else return tostring(n) end
end

local function updateDashboard(sorted)
  -- Display top 10 most critical items (rows 7-16)
  for i = 1, 10 do
    local row = 6 + i
    term.setCursor(2, row)
    gpu.fill(2, row, 76, 1, " ")
    local item = sorted[i]
    if item then
      local pct = item.ratio > 0 and math.floor(item.ratio * 100) or 0
      local color
      if pct < 25      then color = 0xFF4444
      elseif pct < 75  then color = 0xFFAA00
      else                 color = 0x00FFFF
      end
      gpu.setForeground(color)
      -- Right-align stock/target in 20-char field
      local stockTarget = string.format("%10s / %8s", formatQty(item.stock), formatQty(item.threshold))
      local line = string.format("  %-29s  %20s  %3d%%",
        item.name, stockTarget, pct)
      io.write(line)
    end
  end
  gpu.setForeground(0x555555)
  term.setCursor(2, 4)
  io.write(string.format("watchlist: %-13s (%d items)   ", listSource, listCount))
  term.setCursor(55, 2)
  io.write("LAST_SYNC: " .. os.date("%X"))

  -- Why the board is empty, when it is. "0 seen" means the query died; "N seen
  -- / 0 matched" means it worked and no label on this network is on the list.
  local row = 17
  gpu.fill(2, row, 76, 1, " ")
  term.setCursor(2, row)
  if not scanState.ok then
    gpu.setForeground(0xFF4444)
    io.write(string.sub("SCAN FAILED: " .. (scanState.err or "?"), 1, 76))
  elseif scanState.matched == 0 then
    gpu.setForeground(0xFFAA00)
    io.write(string.format("scan ok: %d stacks seen, 0 on watchlist - wrong network or labels differ",
      scanState.seen))
  else
    gpu.setForeground(0x555555)
    io.write(string.format("scan ok: %d stacks seen, %d matched   mem free: %dk",
      scanState.seen, scanState.matched, math.floor(computer.freeMemory() / 1024)))
  end
end

drawStaticFrame()

while true do
  local stocks = scanDustStock()
  local sorted = buildSortedList(stocks)
  updateDashboard(sorted)

  -- Stock only: the broker holds the thresholds it sent us, and echoing them
  -- back just gave a stale node a way to overwrite live policy.
  local payload = {}
  for name in pairs(thresholds) do
    payload[name] = { stock = stocks[name] or 0 }
  end

  modem.broadcast(config.ports.telemetry, serialization.serialize({
    protocol    = "MEDINA_TELEMETRY",
    sender      = nodeName,
    payloadType = "DUST_UPDATE",
    data        = payload
  }))

  -- Wait out the scan interval in short hops so a watchlist push is picked up
  -- promptly instead of up to 10s late.
  local nextScan = computer.uptime() + 10
  while computer.uptime() < nextScan do
    local ev = { event.pull(0.5, "modem_message") }
    if ev[1] == "modem_message" then handleMessage(table.unpack(ev)) end
  end
end
