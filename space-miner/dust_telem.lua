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
if me.getItemsInNetwork == nil or not pcall(me.getItemsInNetwork) then
  error("ME device cannot query the network - check it is joined to the dust subnet.")
end

local gpu      = component.gpu
local nodeName = "MEDINA-DustRelay"

modem.setStrength(400)
gpu.setResolution(80, 25)

-- Build threshold lookup from config.conditions (itemName → amountToMaintain)
local thresholds = {}
for _, cond in ipairs(config.conditions) do
  thresholds[cond.itemName] = cond.amountToMaintain
end

local function scanDustStock()
  local stocks = {}
  local success, items = pcall(me.getItemsInNetwork)
  if success and items then
    for _, item in ipairs(items) do
      if item and item.label and thresholds[item.label] then
        stocks[item.label] = (stocks[item.label] or 0) + item.size
      end
    end
  end
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
  term.setCursor(55, 2)
  io.write("LAST_SYNC: " .. os.date("%X"))
end

drawStaticFrame()

while true do
  local stocks = scanDustStock()
  local sorted = buildSortedList(stocks)
  updateDashboard(sorted)

  local payload = {}
  for name, threshold in pairs(thresholds) do
    payload[name] = { stock=stocks[name] or 0, threshold=threshold }
  end

  modem.broadcast(config.ports.telemetry, serialization.serialize({
    protocol    = "MEDINA_TELEMETRY",
    sender      = nodeName,
    payloadType = "DUST_UPDATE",
    data        = payload
  }))

  os.sleep(10)  -- Update every 10 seconds, not pipeline delay
end
