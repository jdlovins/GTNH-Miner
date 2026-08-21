-- =============================================================================
-- Node ID: MEDINA-HWRelay
-- File:    hw_telem.lua
-- Purpose: Scans Space Elevator staging ME network for drone and drill
--          consumable availability; broadcasts stock data to the broker.
--
-- OpenComputers Sides Reference Matrix:
--   0 = Bottom / Down (-Y) | 1 = Top / Up (+Y) | 2 = North (-Z)
--   3 = South (+Z)         | 4 = West (-X)     | 5 = East (+X)
-- =============================================================================

local component     = require("component")
local serialization = require("serialization")
local term          = require("term")
local event         = require("event")

if not component.isAvailable("modem")   then error("Missing network card.")    end
if not component.isAvailable("gpu")     then error("Requires GPU.")             end

local modem = component.modem
if not modem.isWireless or not modem.isWireless() then
  error("Node requires a T2 Wireless Network Card.")
end

-- Find and connect to ME Controller for direct inventory scanning
local me = nil
for addr, name in component.list("me_controller") do
  me = component.proxy(addr)
  break
end
if not me then error("Missing ME Controller (needed to read network inventory).") end

local gpu      = component.gpu
local nodeName = "MEDINA-HWRelay"

-- Hardcoded drone and drill lists (don't load config to save memory)
local droneKeys = {"max","uxv","umv","uiv","uev","uhv","uv","zpm","luv","iv","ev","hv","mv","lv"}
-- Full ME network labels, including the voltage suffix (mirrors config.drones).
local droneNames = {
  max="Mining Drone MK-XIV (MAX)", uxv="Mining Drone MK-XIII (UXV)", umv="Mining Drone MK-XII (UMV)",
  uiv="Mining Drone MK-XI (UIV)", uev="Mining Drone MK-X (UEV)", uhv="Mining Drone MK-IX (UHV)",
  uv="Mining Drone MK-VIII (UV)", zpm="Mining Drone MK-VII (ZPM)", luv="Mining Drone MK-VI (LuV)",
  iv="Mining Drone MK-V (IV)", ev="Mining Drone MK-IV (EV)", hv="Mining Drone MK-III (HV)",
  mv="Mining Drone MK-II (MV)", lv="Mining Drone MK-I (LV)"
}

-- Map drone keys to their voltage tiers
local droneVoltages = {
  max="MAX", uxv="UXV", umv="UMV", uiv="UIV", uev="UEV", uhv="UHV",
  uv="UV", zpm="ZPM", luv="LuV", iv="IV", ev="EV", hv="HV",
  mv="MV", lv="LV"
}

modem.setStrength(400)
modem.open(2026)
gpu.setResolution(80, 25)

-- Build exact-match lookup tables for drill names (item label → drill key).
-- Avoids substring matching that would catch non-consumable items like "Gold Rod".
local drillLookup = {
  ["Steel Drill Tip"]              = "steel",
  ["Steel Rod"]                    = "steel",
  ["Titanium Drill Tip"]           = "titanium",
  ["Titanium Rod"]                 = "titanium",
  ["Tungstensteel Drill Tip"]      = "tungstensteel",
  ["Tungstensteel Rod"]            = "tungstensteel",
  ["Naquadah Drill Tip"]           = "naquadah",
  ["Naquadah Rod"]                 = "naquadah",
  ["Naquadah Alloy Drill Tip"]     = "naquadahAlloy",
  ["Naquadah Alloy Rod"]           = "naquadahAlloy",
  ["Neutronium Drill Tip"]         = "neutronium",
  ["Neutronium Rod"]               = "neutronium",
  ["Cosmic Neutronium Drill Tip"]  = "cosmicNeutronium",
  ["Cosmic Neutronium Rod"]        = "cosmicNeutronium",
  ["Infinity Drill Tip"]           = "infinity",
  ["Infinity Rod"]                 = "infinity",
  ["Transcendent Metal Drill Tip"] = "transcendentMetal",
  ["Transcendent Metal Rod"]       = "transcendentMetal"
}

-- Display order for drills (lowest → highest tier)
local drillKeyOrder = {
  "steel","titanium","tungstensteel","naquadah",
  "naquadahAlloy","neutronium","cosmicNeutronium","infinity","transcendentMetal"
}

-- Drill display names (key → short name for display)
local drillDisplayNames = {
  steel="Steel", titanium="Titanium", tungstensteel="Tungstensteel",
  naquadah="Naquadah", naquadahAlloy="Naquadah Alloy", neutronium="Neutronium",
  cosmicNeutronium="Cosmic Neutronium", infinity="Infinity", transcendentMetal="Transcendent Metal"
}

local function drawStaticFrame()
  term.clear()
  gpu.setForeground(0x00FF00)
  print("================================================================================")
  print(" MEDINA RELAY NETWORK  |  NODE: " .. nodeName)
  print("================================================================================")
  gpu.setForeground(0xFFFFFF)
  term.setCursor(2, 5)  io.write("DRONE FLEET STATUS")
  term.setCursor(40, 5) io.write("DRILL KIT AVAILABILITY")
  term.setCursor(2, 6)  io.write(string.rep("-", 76))

  gpu.setForeground(0x555555)
  term.setCursor(2, 22) io.write(string.rep("=", 76))
  term.setCursor(2, 23) io.write("  Wireless Signal Range: " .. tostring(modem.getStrength()) .. " blocks")
  term.setCursor(2, 24) io.write("  Network Port: 2026")
end

-- Reads items directly from ME network via controller
local function scanAssets()
  local assets = { drones={}, drillTips={}, drillRods={} }

  -- Query all items in the ME network
  local success, itemList = pcall(me.getItemsInNetwork)
  if not success or not itemList then return assets end

  for _, item in ipairs(itemList) do
    if item.label then
      if string.find(item.label, "Mining Drone", 1, true) then
        assets.drones[item.label] = (assets.drones[item.label] or 0) + item.size
      elseif drillLookup[item.label] then
        local key = drillLookup[item.label]
        if string.find(item.label, "Drill Tip", 1, true) then
          assets.drillTips[key] = (assets.drillTips[key] or 0) + item.size
        elseif string.find(item.label, "Rod", 1, true) then
          assets.drillRods[key] = (assets.drillRods[key] or 0) + item.size
        end
      end
    end
  end

  return assets
end

local function updateDashboard(assets)
  -- Drone column (left, rows 7-20)
  local totalDrones = 0
  for i, key in ipairs(droneKeys) do
    local label = droneNames[key]
    local count = assets.drones[label] or 0
    totalDrones = totalDrones + count
    local row = 6 + i
    term.setCursor(2, row)
    gpu.fill(2, row, 36, 1, " ")
    gpu.setForeground(count > 0 and 0x00FFFF or 0x555555)
    -- Display drone model with voltage tier
    -- Labels carry a voltage suffix; show just the MK-N model, tier is its own column.
    local voltage = droneVoltages[key]
    local model   = string.match(label, "MK%-[XVI]+") or label
    io.write(string.format("  %-14s [%s]: %d", model, voltage, count))
  end

  -- Drill column (right, rows 7-15)
  for i, key in ipairs(drillKeyOrder) do
    local tips = assets.drillTips[key] or 0
    local rods = assets.drillRods[key] or 0
    local kits = math.min(tips, rods)
    local displayName = drillDisplayNames[key]
    local row = 6 + i
    term.setCursor(40, row)
    gpu.fill(40, row, 38, 1, " ")
    if totalDrones > 0 then
      gpu.setForeground(kits > 0 and 0xFF00FF or 0x555555)
      -- Display kits with individual tip and rod counts
      io.write(string.format("  %-15s: %d (%d|%d)", displayName, kits, tips, rods))
    else
      gpu.setForeground(0x333333)
      io.write("  [ NO FLEET — MASKED ]")
    end
  end

  gpu.setForeground(0x555555)
  term.setCursor(55, 2)
  io.write("LAST_SYNC: " .. os.date("%X"))
end

drawStaticFrame()

local lastAssets = { drones={}, drillTips={}, drillRods={} }

-- Helper to build payload from assets
local function buildPayload(assets)
  local payload = { drones={}, drills={} }
  for _, key in ipairs(droneKeys) do
    local count = assets.drones[droneNames[key]] or 0
    if count > 0 then payload.drones[key] = count end
  end
  for _, key in ipairs(drillKeyOrder) do
    local tips = assets.drillTips[key] or 0
    local rods = assets.drillRods[key] or 0
    local kits = math.min(tips, rods)
    if kits > 0 then payload.drills[key] = { kits=kits, tips=tips, rods=rods } end
  end
  return payload
end

modem.open(2025)  -- Query port for on-demand inventory requests

while true do
  -- Scan the chest for current inventory
  lastAssets = scanAssets()
  updateDashboard(lastAssets)

  -- Build and broadcast periodic HW_UPDATE
  local payload = buildPayload(lastAssets)
  modem.broadcast(2026, serialization.serialize({
    protocol    = "MEDINA_TELEMETRY",
    sender      = nodeName,
    payloadType = "HW_UPDATE",
    data        = payload
  }))

  -- Listen for Ctrl+C or HW_QUERY requests (non-blocking, 10s timeout)
  local ev = { event.pull(10, "key_down", "modem_message") }
  if ev[1] == "key_down" and ev[3] == 3 then -- Ctrl+C
    term.clear()
    os.exit()
  elseif ev[1] == "modem_message" then
    -- Query received on port 2025
    local _, _, senderAddr, port, _, rawMsg = table.unpack(ev)
    if port == 2025 then
      local ok, msg = pcall(serialization.unserialize, rawMsg)
      if ok and msg and msg.protocol == "MEDINA_COMMAND" and msg.payloadType == "HW_QUERY" then
        -- Respond immediately with current inventory
        local payload = buildPayload(lastAssets)
        modem.send(senderAddr, 2025, serialization.serialize({
          protocol    = "MEDINA_TELEMETRY",
          sender      = nodeName,
          payloadType = "HW_QUERY_RESPONSE",
          data        = payload
        }))
      end
    end
  end
end
