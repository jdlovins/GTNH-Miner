-- =============================================================================
-- Node ID: MEDINA-DustRelay
-- File:    dust_telem.lua
-- Purpose: Queries the dust storage ME subnet; displays the 10 most critical
--          items (lowest stock/threshold ratio) and broadcasts all tracked
--          stock levels to the broker.
--
-- This node holds NO policy and needs NO config file. What to scan and how
-- often both arrive from the broker; the only thing written down here is the
-- pair of port numbers it cannot be told over the air. It deliberately does not
-- load config.lua -- three thousand lines of asteroid data parsed into the
-- memory of the machine that then has to hold a full ME network scan was the
-- direct cause of this node's out-of-memory failures, and not one line of it
-- was read here.
--
-- Laid out to the same skeleton as fluid_telem.lua -- wiring, hardware,
-- settings, inbound, scanning, dashboard, main loop -- so that knowing one node
-- means knowing the other.
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

-- ---------------------------------------------------------------------------
-- WIRING
--
-- The only things this node cannot be told over the air. OpenComputers makes
-- you modem.open() an explicit port number, so a node cannot discover which
-- port to listen on -- it has to know. That makes these two integers
-- irreducible, and they are the entire local configuration of this machine.
--
-- They must match config.ports on the broker. fluid_telem.lua and hw_telem.lua
-- carry the same pair for the same reason; SETTINGS.md lists all four places.
-- Change them together, or this node simply never hears anything -- which the
-- status line shows as a settings source stuck on "defaults".
-- ---------------------------------------------------------------------------
local PORT_TELEMETRY = 2026   -- outbound: this node -> broker
local PORT_COMMAND   = 2027   -- inbound:  broker -> this node

-- Cold-start values, and the schema for what a push may contain: applySettings
-- accepts a key only if it already appears here, with the same type. Replaced
-- by the cache on boot and by the broker's NODE_SETTINGS whenever it arrives.
-- The broker's defaults for these live in settings.lua; see SETTINGS.md.
local settings = {
  dustScanInterval = 10,
  wirelessStrength = 400,
  nodeDashboard    = true,
}

local SETTINGS_CACHE = "/home/node_settings.lua"

-- Where the values above came from, for the status line. A node still showing
-- "defaults" long after boot is not hearing the broker.
local settingsSource = "defaults"

-- ---------------------------------------------------------------------------
-- HARDWARE
-- ---------------------------------------------------------------------------

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
  -- Two distinct failures, and only one of them is a throw. An unpowered or
  -- channel-starved network does not raise: the call returns nil plus a reason
  -- string, so pcall reports success and the reason lands in the THIRD value.
  local ok, items, why = pcall(me.getItemsInNetwork)
  if not ok then
    error("ME query failed: " .. tostring(items))
  elseif items == nil then
    error("ME query returned nothing: " .. (why or "no reason given")
      .. " - check the network is powered and the interface has a channel.")
  end
end

local gpu      = component.gpu
local nodeName = "MEDINA-DustRelay"

-- ---------------------------------------------------------------------------
-- SETTINGS FROM THE BROKER
--
-- Accept only keys this node already holds, and only with the same type. A
-- broadcast does not get to invent keys or hand a string to something used as
-- a number -- `settings` above is the schema as well as the defaults. The
-- broker sends one payload to every node, so the keys meant for the fluid node
-- are filtered out here simply by not appearing above.
--
-- Returns how many values actually moved, so a caller can skip re-applying
-- side effects (modem strength) when a re-broadcast changed nothing.
-- ---------------------------------------------------------------------------
local function applySettings(values)
  if type(values) ~= "table" then return 0 end
  local changed = 0
  for key, cur in pairs(settings) do
    local v = values[key]
    if v ~= nil and type(v) == type(cur) and v ~= cur then
      settings[key] = v
      changed = changed + 1
    end
  end
  return changed
end

local function saveSettingsCache()
  local f = io.open(SETTINGS_CACHE, "w")
  if not f then return end
  f:write("return {\n")
  for key, v in pairs(settings) do
    if type(v) == "number" then
      f:write(string.format("  %s = %s,\n", key, tostring(v)))
    elseif type(v) == "boolean" then
      f:write(string.format("  %s = %s,\n", key, v and "true" or "false"))
    end
  end
  f:write("}\n")
  f:close()
end

do
  local ok, cached = pcall(dofile, SETTINGS_CACHE)
  if ok and type(cached) == "table" then
    applySettings(cached)
    settingsSource = "cache"
  end
end

modem.setStrength(settings.wirelessStrength)
gpu.setResolution(80, 25)
modem.open(PORT_COMMAND)   -- inbound: broker -> this node

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
--
-- There is no third option any more. A node that has never heard from the
-- broker scans nothing and says so on its status line, which is the honest
-- answer -- the old local fallback could only ever be a stale guess at what
-- the broker wanted, and a wrong watchlist reads as "we have none of this,
-- mine it urgently".
-- ---------------------------------------------------------------------------
local WATCHLIST_CACHE = "/home/dust_watchlist.lua"

local thresholds  = {}
local listSource  = "none"
local listCount   = 0
local listDirty   = true   -- the sorted view below is rebuilt when this is set

local function applyWatchlist(list, source)
  thresholds = list
  listSource = source
  listCount  = 0
  for _ in pairs(list) do listCount = listCount + 1 end
  listDirty = true
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
  end
end

-- ---------------------------------------------------------------------------
-- INBOUND
-- Accept pushes from the broker: the watchlist, and the node settings that say
-- how often to scan and how far to talk. Both are cached so the next restart
-- does not have to wait for the broker to come back.
--
-- Same guard ladder as fluid_telem.lua -- unserialize, protocol, then dispatch
-- on payloadType.
-- ---------------------------------------------------------------------------
local function handleMessage(_, _, _, _, _, rawMsg)
  -- Cheap reject before the expensive part. A modem payload can be any type, so
  -- the string check is a correctness guard as much as a fast path.
  if type(rawMsg) ~= "string" then return end

  -- Scanning the raw string allocates nothing; unserializing costs a whole
  -- table. Worth little on this node -- the big message on this port is the
  -- watchlist and we want that -- but it keeps JOB_ASSIGN broadcasts out in a
  -- multi-node fleet, and it matches fluid_telem.lua, where the same guard is
  -- what stops that node rebuilding our watchlist every 30s just to drop it.
  --
  -- An allow-list, not a deny-list: a payload type added later should fall out
  -- here rather than quietly reach the branches below. A false positive is
  -- harmless -- it only buys a message the payloadType checks then route
  -- correctly anyway.
  if not (rawMsg:find("DUST_WATCHLIST", 1, true)
       or rawMsg:find("NODE_SETTINGS", 1, true)) then return end

  local ok, msg = pcall(serialization.unserialize, rawMsg)
  if not ok or type(msg) ~= "table" then return end
  if msg.protocol ~= "MEDINA_COMMAND" then return end

  if msg.payloadType == "NODE_SETTINGS" then
    -- An empty or malformed push is ignored outright rather than resetting a
    -- working node to its defaults.
    if type(msg.data) ~= "table" or not next(msg.data) then return end
    settingsSource = "broker"
    if applySettings(msg.data) > 0 then
      saveSettingsCache()
      -- Strength is the only setting with a side effect to re-apply. The scan
      -- interval is read live by the wait loop, so a change to it lands
      -- immediately even mid-wait.
      modem.setStrength(settings.wirelessStrength)
    end
    return
  end

  if msg.payloadType ~= "DUST_WATCHLIST" or type(msg.data) ~= "table" then return end
  if not next(msg.data) then return end   -- never let an empty list blind us
  applyWatchlist(msg.data, "broker")
  saveWatchlist(msg.data)
end

-- ---------------------------------------------------------------------------
-- SCANNING
-- ---------------------------------------------------------------------------

-- Last scan's outcome, for the status line. A failed query and a genuinely
-- empty network both used to render as an all-red board of zeroes, which is
-- indistinguishable at a glance -- so record which one it was.
local scanState = { ok = true, err = nil, seen = 0, matched = 0 }

-- Reused across scans. Rebuilding these two tables every 10 seconds meant a
-- fresh entry table per watched item, ~90 of them, discarded immediately -- on
-- the machine in this fleet with the least memory to spare and the largest
-- single allocation (the network scan) to make right afterwards.
local stocks = {}
local sorted = {}

local function byRatio(a, b) return a.ratio < b.ratio end

local function scanDustStock()
  for k in pairs(stocks) do stocks[k] = nil end

  -- `why` is the third value on purpose: a nil return is not a throw, so the
  -- reason arrives alongside the nil rather than in pcall's error slot.
  local success, items, why = pcall(me.getItemsInNetwork)
  if not success then
    scanState = { ok = false, err = "threw: " .. tostring(items), seen = 0, matched = 0 }
    return
  elseif items == nil then
    scanState = { ok = false, err = "returned nil: " .. (why or "no reason given"),
                  seen = 0, matched = 0 }
    return
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
end

-- The row objects are allocated once per watchlist change and then mutated in
-- place. Only the sort order and the numbers move between scans; the set of
-- items does not.
local function buildSortedList()
  if listDirty then
    for i = #sorted, 1, -1 do sorted[i] = nil end
    for name, threshold in pairs(thresholds) do
      sorted[#sorted + 1] = { name = name, stock = 0, threshold = threshold, ratio = 0 }
    end
    listDirty = false
  end
  for i = 1, #sorted do
    local row = sorted[i]
    row.threshold = thresholds[row.name] or row.threshold
    row.stock     = stocks[row.name] or 0
    row.ratio     = row.threshold > 0 and (row.stock / row.threshold) or 0
  end
  table.sort(sorted, byRatio)
  return sorted
end

-- ---------------------------------------------------------------------------
-- DASHBOARD
-- ---------------------------------------------------------------------------

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

local function updateDashboard(list)
  -- Display top 10 most critical items (rows 7-16)
  for i = 1, 10 do
    local row = 6 + i
    term.setCursor(2, row)
    gpu.fill(2, row, 76, 1, " ")
    local item = list[i]
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
      io.write(string.format("  %-29s  %20s  %3d%%", item.name, stockTarget, pct))
    end
  end
  -- Where the watchlist and settings came from and what they currently say, so
  -- a node that is not hearing the broker is visible at a glance rather than by
  -- inference.
  gpu.setForeground(0x555555)
  term.setCursor(2, 4)
  io.write(string.format("watchlist: %-8s (%d items)   settings: %-8s   scan: %ds   ",
    listSource, listCount, settingsSource, settings.dustScanInterval))
  term.setCursor(55, 2)
  io.write("LAST_SYNC: " .. os.date("%X"))

  -- Why the board is empty, when it is. "0 seen" means the query died; "N seen
  -- / 0 matched" means it worked and no label on this network is on the list;
  -- an empty watchlist means the broker has not reached us yet.
  local row = 17
  gpu.fill(2, row, 76, 1, " ")
  term.setCursor(2, row)
  if listCount == 0 then
    gpu.setForeground(0xFFAA00)
    io.write("no watchlist yet - waiting for the broker to push one (it re-sends every 30s)")
  elseif not scanState.ok then
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

-- ---------------------------------------------------------------------------
-- MAIN LOOP
-- ---------------------------------------------------------------------------

if settings.nodeDashboard then drawStaticFrame() end

-- Reused for the same reason as `stocks`: one table per broadcast, every scan.
local payload = {}

while true do
  -- Skip the ME query entirely while there is nothing to look for. It is by far
  -- the most expensive thing this node does, and with an empty watchlist every
  -- result of it is discarded.
  if listCount > 0 then
    scanDustStock()
  end

  if settings.nodeDashboard then
    updateDashboard(buildSortedList())
  end

  -- Stock only: the broker holds the thresholds it sent us, and echoing them
  -- back just gave a stale node a way to overwrite live policy.
  for k in pairs(payload) do payload[k] = nil end
  for name in pairs(thresholds) do
    payload[name] = { stock = stocks[name] or 0 }
  end

  modem.broadcast(PORT_TELEMETRY, serialization.serialize({
    protocol    = "MEDINA_TELEMETRY",
    sender      = nodeName,
    payloadType = "DUST_UPDATE",
    data        = payload
  }))

  -- Wait out the scan interval in short hops so a push is picked up promptly
  -- instead of a whole interval late. The interval is read on every hop rather
  -- than turned into a deadline up front, so a push that shortens it takes
  -- effect during the very wait it arrived in.
  local waitFrom = computer.uptime()
  while computer.uptime() - waitFrom < settings.dustScanInterval do
    local ev = { event.pull(0.5, "modem_message") }
    if ev[1] == "modem_message" then handleMessage(table.unpack(ev)) end
  end
end
