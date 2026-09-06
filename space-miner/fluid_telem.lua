-- =============================================================================
-- Node ID: MEDINA-FluidRelay
-- File:    fluid_telem.lua
-- Purpose: Monitors plasma overdrive fuels via an ME fluid network adapter;
--          renders a status dashboard and broadcasts all plasma volumes to
--          the broker so it can make plasma selection decisions.
--
-- Like the dust node, this one carries no policy and no config.lua. Ports and
-- fallbacks come from node_config.lua; the scan interval and modem strength are
-- pushed by the broker. See SETTINGS.md.
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

local node
for _, path in ipairs({ "/home/node_config.lua", "node_config.lua" }) do
  local ok, mod = pcall(dofile, path)
  if ok and type(mod) == "table" and mod.ports then node = mod break end
end
if not node then error("Missing node_config.lua - re-run install-medina.") end

if not component.isAvailable("modem")         then error("Missing network card.") end
if not component.isAvailable("me_controller") then error("Missing ME Controller.") end
if not component.isAvailable("gpu")           then error("Requires GPU.")          end

local modem = component.modem
if not modem.isWireless or not modem.isWireless() then
  error("Node requires a T2 Wireless Network Card.")
end

local me_ctrl  = component.me_controller
local gpu      = component.gpu
local nodeName = "MEDINA-FluidRelay"

node.loadCache()
modem.setStrength(node.settings.wirelessStrength)
gpu.setResolution(80, 25)
modem.open(node.ports.command)   -- inbound: broker -> this node (settings)

-- Row positions in the display. Built from node.plasmaOrder so the five names
-- exist in exactly one place -- they used to be written out here as well as in
-- config.lua, which is two lists to keep in step for no gain.
local rowMap  = {}
local rowFirst = 6
for i, name in ipairs(node.plasmaOrder) do
  -- plasmaOrder is highest tier first; the dashboard has always read lowest
  -- tier at the top, so the rows count backwards.
  rowMap[name] = rowFirst + (#node.plasmaOrder - i)
end

local function drawStaticFrame()
  term.clear()
  gpu.setForeground(0x00FF00)
  print("================================================================================")
  print(" MEDINA RELAY NETWORK  |  NODE: " .. nodeName)
  print("================================================================================")
  gpu.setForeground(0xFFFFFF)
  term.setCursor(1, 5) print("  [ PLASMA OVERDRIVE STOCK ]")
  for name, row in pairs(rowMap) do
    term.setCursor(3, row)
    io.write(name .. ":")
  end
  term.setCursor(1, rowFirst + #node.plasmaOrder)
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
  term.setCursor(2, 4)
  io.write(string.format("settings: %-8s   scan: %ds   ", node.source,
    node.settings.fluidScanInterval))
  term.setCursor(55, 2)
  io.write("LAST_SYNC: " .. os.date("%X"))
end

-- Reused rather than rebuilt: this runs every few seconds forever, and the set
-- of keys never changes.
local volumes = {}

local function scanPlasmaStock()
  for name in pairs(rowMap) do volumes[name] = 0 end

  local highestVolume  = 0
  local dominantPlasma = ""

  local success, networkFluids = pcall(me_ctrl.getFluidsInNetwork)
  if success and networkFluids then
    for _, fluid in ipairs(networkFluids) do
      if fluid and fluid.label and volumes[fluid.label] ~= nil then
        volumes[fluid.label] = fluid.amount
      end
    end
    -- Find the highest-tier plasma that has stock (plasmaOrder is descending tier)
    for _, plasmaName in ipairs(node.plasmaOrder) do
      if (volumes[plasmaName] or 0) > 0 then
        dominantPlasma = plasmaName
        highestVolume  = volumes[plasmaName]
        break
      end
    end
  end

  return volumes, dominantPlasma, highestVolume
end

local function handleMessage(_, _, _, _, _, rawMsg)
  local ok, msg = pcall(serialization.unserialize, rawMsg)
  if not ok or type(msg) ~= "table" then return end
  if node.handlePush(msg) then
    modem.setStrength(node.settings.wirelessStrength)
  end
end

if node.settings.nodeDashboard then drawStaticFrame() end

while true do
  local plasmaVolumes, dominant, dominantVolume = scanPlasmaStock()
  if node.settings.nodeDashboard then
    updateDashboard(plasmaVolumes, dominant, dominantVolume)
  end

  modem.broadcast(node.ports.telemetry, serialization.serialize({
    protocol    = "MEDINA_TELEMETRY",
    sender      = nodeName,
    payloadType = "FLUID_UPDATE",
    data        = { plasmas = plasmaVolumes }
  }))

  -- Was os.sleep(10), which meant a settings push sat in the queue for up to a
  -- full interval and, worse, that this node could not be reconfigured at all
  -- while it slept. Short hops instead, with the interval read on each one so a
  -- change lands during the very wait it arrived in.
  local waitFrom = computer.uptime()
  while computer.uptime() - waitFrom < node.settings.fluidScanInterval do
    local ev = { event.pull(0.5, "modem_message") }
    if ev[1] == "modem_message" then handleMessage(table.unpack(ev)) end
  end
end
