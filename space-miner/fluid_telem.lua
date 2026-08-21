-- =============================================================================
-- Node ID: MEDINA-FluidRelay
-- File:    fluid_telem.lua
-- Purpose: Monitors plasma overdrive fuels via an ME fluid network adapter;
--          renders a status dashboard and broadcasts all plasma volumes to
--          the broker on port 2026 so it can make plasma selection decisions.
--
-- OpenComputers Sides Reference Matrix:
--   0 = Bottom / Down (-Y) | 1 = Top / Up (+Y) | 2 = North (-Z)
--   3 = South (+Z)         | 4 = West (-X)     | 5 = East (+X)
-- =============================================================================

local component     = require("component")
local serialization = require("serialization")
local term          = require("term")

local config = dofile("/home/config.lua")

if not component.isAvailable("modem")   then error("Missing network card.")         end
if not component.isAvailable("me_controller") then error("Missing ME Controller.") end
if not component.isAvailable("gpu")            then error("Requires GPU.")           end

local modem = component.modem
if not modem.isWireless or not modem.isWireless() then
  error("Node requires a T2 Wireless Network Card.")
end

local me_ctrl  = component.me_controller
local gpu      = component.gpu
local nodeName = "MEDINA-FluidRelay"

modem.setStrength(400)
gpu.setResolution(80, 25)

-- Row positions for each plasma in the display (keyed by full plasma name)
local rowMap = {
  ["Helium Plasma"]        = 6,
  ["Bismuth Plasma"]       = 7,
  ["Radon Plasma"]         = 8,
  ["Technetium Plasma"]    = 9,
  ["Plutonium 241 Plasma"] = 10
}

local function drawStaticFrame()
  term.clear()
  gpu.setForeground(0x00FF00)
  print("================================================================================")
  print(" MEDINA RELAY NETWORK  |  NODE: " .. nodeName)
  print("================================================================================")
  gpu.setForeground(0xFFFFFF)
  term.setCursor(1, 5)  print("  [ PLASMA OVERDRIVE STOCK ]")
  term.setCursor(1, 6)  print("  Helium Plasma:        ")
  term.setCursor(1, 7)  print("  Bismuth Plasma:       ")
  term.setCursor(1, 8)  print("  Radon Plasma:         ")
  term.setCursor(1, 9)  print("  Technetium Plasma:    ")
  term.setCursor(1, 10) print("  Plutonium 241 Plasma: ")
  print("\n--------------------------------------------------------------------------------")
  print("  [ HIGHEST AVAILABLE PLASMA ]")
  print("  Active Plasma:  ")
  print("  Current Volume: ")
  print("  Wireless Range: " .. tostring(modem.getStrength()) .. " blocks")
  print("================================================================================")
end

local function updateDashboard(plasmaVolumes, dominant, dominantVolume)
  -- Clear value fields and rewrite amounts
  for _, row in pairs(rowMap) do gpu.fill(24, row, 20, 1, " ") end
  gpu.setForeground(0xFFFFFF)
  for name, amount in pairs(plasmaVolumes) do
    local row = rowMap[name]
    if row then
      term.setCursor(24, row)
      -- Dim entries that are empty
      gpu.setForeground(amount > 0 and 0xFFFFFF or 0x555555)
      io.write(string.format("%s mB", tostring(amount)))
    end
  end

  gpu.fill(18, 14, 40, 2, " ")
  if dominant ~= "" then
    gpu.setForeground(0x00FFFF)
    term.setCursor(18, 14) io.write(dominant)
    term.setCursor(18, 15) io.write(string.format("%s mB", tostring(dominantVolume)))
  else
    gpu.setForeground(0xFF4444)
    term.setCursor(18, 14) io.write("NO PLASMA IN STOCK")
    term.setCursor(18, 15) io.write("0 mB")
  end

  gpu.setForeground(0x555555)
  term.setCursor(55, 2)
  io.write("LAST_SYNC: " .. os.date("%X"))
end

local function scanPlasmaStock()
  local volumes = {}
  for name in pairs(rowMap) do volumes[name] = 0 end

  local highestVolume   = 0
  local dominantPlasma  = ""

  local success, networkFluids = pcall(me_ctrl.getFluidsInNetwork)
  if success and networkFluids then
    for _, fluid in ipairs(networkFluids) do
      if fluid and fluid.label and volumes[fluid.label] ~= nil then
        volumes[fluid.label] = fluid.amount
      end
    end
    -- Find the highest-tier plasma that has stock (plasmaKeyOrder is descending tier)
    for _, plasmaName in ipairs(config.plasmaKeyOrder) do
      if (volumes[plasmaName] or 0) > 0 then
        dominantPlasma = plasmaName
        highestVolume  = volumes[plasmaName]
        break
      end
    end
  end

  return volumes, dominantPlasma, highestVolume
end

drawStaticFrame()

while true do
  local plasmaVolumes, dominant, dominantVolume = scanPlasmaStock()
  updateDashboard(plasmaVolumes, dominant, dominantVolume)

  modem.broadcast(config.ports.telemetry, serialization.serialize({
    protocol    = "MEDINA_TELEMETRY",
    sender      = nodeName,
    payloadType = "FLUID_UPDATE",
    data        = { plasmas=plasmaVolumes }
  }))

  os.sleep(10)
end
