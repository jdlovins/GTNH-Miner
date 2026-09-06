-- =============================================================================
-- Node ID: MEDINA-FluidRelay
-- File:    fluid_telem.lua
-- Purpose: Monitors plasma overdrive fuels via an ME fluid network adapter;
--          renders a status dashboard and broadcasts all plasma volumes to
--          the broker so it can make plasma selection decisions.
--
-- This node holds NO policy and needs NO config file. How often it scans and how
-- far it talks arrive from the broker; the only things written down here are the
-- pair of port numbers it cannot be told over the air and the five plasma tier
-- names. It deliberately does not load config.lua.
--
-- Laid out to the same skeleton as dust_telem.lua -- wiring, hardware, settings,
-- inbound, scanning, dashboard, main loop -- so that knowing one node means
-- knowing the other.
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
-- irreducible, and they are almost the entire local configuration of this
-- machine.
--
-- They must match config.ports on the broker. dust_telem.lua and hw_telem.lua
-- carry the same pair for the same reason; SETTINGS.md lists all four places.
-- Change them together, or this node simply never hears anything -- which the
-- status line shows as a settings source stuck on "defaults".
-- ---------------------------------------------------------------------------
local PORT_TELEMETRY = 2026   -- outbound: this node -> broker
local PORT_COMMAND   = 2027   -- inbound:  broker -> this node

-- Highest tier first. Kept local rather than pushed by the broker: these five
-- names are a fact about the game, not a preference, and holding them here
-- means the dashboard is populated the instant this node boots. That matters
-- more than it looks -- the broker's hasPlasma() gate reads what this node
-- reports, so a node that came up knowing nothing would stall dispatch until
-- the next broadcast reached it.
local PLASMA_ORDER = {
  "Plutonium 241 Plasma", "Technetium Plasma", "Radon Plasma",
  "Bismuth Plasma", "Helium Plasma",
}

-- Cold-start values, and the schema for what a push may contain: applySettings
-- accepts a key only if it already appears here, with the same type. Replaced
-- by the cache on boot and by the broker's NODE_SETTINGS whenever it arrives.
-- The broker's defaults for these live in settings.lua; see SETTINGS.md.
local settings = {
  fluidScanInterval = 10,
  wirelessStrength  = 400,
  nodeDashboard     = true,
}

local SETTINGS_CACHE = "/home/node_settings.lua"

-- Where the values above came from, for the status line. A node still showing
-- "defaults" long after boot is not hearing the broker.
local settingsSource = "defaults"

-- ---------------------------------------------------------------------------
-- HARDWARE
-- ---------------------------------------------------------------------------

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

-- ---------------------------------------------------------------------------
-- SETTINGS FROM THE BROKER
--
-- Accept only keys this node already holds, and only with the same type. A
-- broadcast does not get to invent keys or hand a string to something used as
-- a number -- `settings` above is the schema as well as the defaults. The
-- broker sends one payload to every node, so the keys meant for the dust node
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
-- INBOUND
-- Accept pushes from the broker: the node settings that say how often to scan
-- and how far to talk. Cached so the next restart does not have to wait for the
-- broker to come back.
--
-- Same guard ladder as dust_telem.lua -- unserialize, protocol, then dispatch
-- on payloadType -- even though only one payload type matters here. The dust
-- watchlist lands on this port too, and dispatching rather than combining the
-- checks is what makes the two files read alike.
-- ---------------------------------------------------------------------------
local function handleMessage(_, _, _, _, _, rawMsg)
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
end

-- ---------------------------------------------------------------------------
-- SCANNING
-- ---------------------------------------------------------------------------

-- Reused rather than rebuilt: this runs every few seconds forever, and the set
-- of keys never changes.
local volumes = {}

local function scanPlasmaStock()
  -- Keyed off PLASMA_ORDER, not the dashboard's row map: what to look for is a
  -- scanning concern, and this way the scan still works with the dashboard off.
  for _, name in ipairs(PLASMA_ORDER) do volumes[name] = 0 end

  local highestVolume  = 0
  local dominantPlasma = ""

  local success, networkFluids = pcall(me_ctrl.getFluidsInNetwork)
  if success and networkFluids then
    for _, fluid in ipairs(networkFluids) do
      if fluid and fluid.label and volumes[fluid.label] ~= nil then
        volumes[fluid.label] = fluid.amount
      end
    end
    -- Find the highest-tier plasma that has stock (PLASMA_ORDER is descending tier)
    for _, plasmaName in ipairs(PLASMA_ORDER) do
      if (volumes[plasmaName] or 0) > 0 then
        dominantPlasma = plasmaName
        highestVolume  = volumes[plasmaName]
        break
      end
    end
  end

  return volumes, dominantPlasma, highestVolume
end

-- ---------------------------------------------------------------------------
-- DASHBOARD
-- ---------------------------------------------------------------------------

-- Row positions in the display, built from PLASMA_ORDER so the five names exist
-- in exactly one place on this machine -- they used to be written out here as
-- well, which is two lists to keep in step for no gain.
local rowMap   = {}
local rowFirst = 6
for i, name in ipairs(PLASMA_ORDER) do
  -- PLASMA_ORDER is highest tier first; the dashboard has always read lowest
  -- tier at the top, so the rows count backwards.
  rowMap[name] = rowFirst + (#PLASMA_ORDER - i)
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
  term.setCursor(1, rowFirst + #PLASMA_ORDER)
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

  -- Where the settings came from and what they currently say, so a node that is
  -- not hearing the broker is visible at a glance rather than by inference.
  gpu.setForeground(0x555555)
  term.setCursor(2, 4)
  io.write(string.format("settings: %-8s   scan: %ds   ", settingsSource,
    settings.fluidScanInterval))
  term.setCursor(55, 2)
  io.write("LAST_SYNC: " .. os.date("%X"))
end

-- ---------------------------------------------------------------------------
-- MAIN LOOP
-- ---------------------------------------------------------------------------

if settings.nodeDashboard then drawStaticFrame() end

while true do
  local plasmaVolumes, dominant, dominantVolume = scanPlasmaStock()

  if settings.nodeDashboard then
    updateDashboard(plasmaVolumes, dominant, dominantVolume)
  end

  modem.broadcast(PORT_TELEMETRY, serialization.serialize({
    protocol    = "MEDINA_TELEMETRY",
    sender      = nodeName,
    payloadType = "FLUID_UPDATE",
    data        = { plasmas = plasmaVolumes }
  }))

  -- Wait out the scan interval in short hops so a push is picked up promptly
  -- instead of a whole interval late. The interval is read on every hop rather
  -- than turned into a deadline up front, so a push that shortens it takes
  -- effect during the very wait it arrived in.
  --
  -- This was os.sleep(10), which meant a settings push sat in the queue for up
  -- to a full interval and, worse, that this node could not be reconfigured at
  -- all while it slept.
  local waitFrom = computer.uptime()
  while computer.uptime() - waitFrom < settings.fluidScanInterval do
    local ev = { event.pull(0.5, "modem_message") }
    if ev[1] == "modem_message" then handleMessage(table.unpack(ev)) end
  end
end
