-- =============================================================================
-- node_config.lua — everything a telemetry node needs to know on its own
--
-- The dust and fluid nodes used to `dofile("/home/config.lua")` for two numbers
-- and a five-name list. That file is three thousand lines: the whole asteroid
-- database, the output tables, the optimisation matrix -- all of it parsed into
-- the memory of a machine that then tries to hold a full ME network scan in
-- what is left. It is the direct cause of the out-of-memory failures on the
-- dust node, and none of it was ever read there.
--
-- So the nodes read this instead. Ports, and defaults for the handful of
-- settings that reach them. Everything else arrives from the broker.
--
-- RESOLUTION ORDER, most authoritative first:
--   1. what the broker last sent (NODE_SETTINGS, on the command port)
--   2. /home/node_settings.lua, the cached copy of that -- so a node restarting
--      during a broker outage comes back correctly configured rather than
--      reverting to defaults
--   3. the defaults below
--
-- The defaults MIRROR the ones declared in settings.lua on the broker. They are
-- written out here rather than derived, because deriving them means loading
-- settings.lua, and a node that can load a file from the broker's world does
-- not need a fallback in the first place. If you change one there, change it
-- here -- or just let the broker push it, which is the normal path.
-- =============================================================================

local N = {}

-- Must match config.ports on the broker. Not pushable, and deliberately so:
-- the packet that would carry a new port number goes out on the old one. See
-- SETTINGS.md.
N.ports = {
  telemetry = 2026, -- outbound: this node -> broker
  command   = 2027, -- inbound:  broker -> this node
  hardware  = 2025, -- broker -> hw telem node only
}

-- Highest tier first. Used by the fluid node to pick the dominant plasma.
N.plasmaOrder = {
  "Plutonium 241 Plasma", "Technetium Plasma", "Radon Plasma",
  "Bismuth Plasma", "Helium Plasma",
}

-- Live values. Read these, not the defaults -- they are replaced in place as
-- pushes arrive, so a node picks up an edit without restarting.
N.settings = {
  dustScanInterval  = 10,
  fluidScanInterval = 10,
  wirelessStrength  = 400,
  nodeDashboard     = true,
  drillCraftSlots   = 2,
}

-- Where the last push is remembered.
N.cachePath = "/home/node_settings.lua"

-- Where the current values came from, for the node's status line. A node
-- showing "defaults" long after boot means the broker is not reaching it.
N.source = "defaults"

-- Only these are accepted off the wire, and only with the right type. A node
-- applies what a broadcast tells it to, so the broadcast does not get to
-- invent keys or hand a string to something that indexes with it.
local TYPES = {
  dustScanInterval  = "number",
  fluidScanInterval = "number",
  wirelessStrength  = "number",
  nodeDashboard     = "boolean",
  drillCraftSlots   = "number",
}

-- Returns the number of values that actually changed, so a caller can skip
-- re-applying side effects (modem strength, screen redraw) when nothing moved.
function N.apply(values, source)
  if type(values) ~= "table" then return 0 end
  local changed = 0
  for key, want in pairs(TYPES) do
    local v = values[key]
    if type(v) == want and N.settings[key] ~= v then
      N.settings[key] = v
      changed = changed + 1
    end
  end
  if source then N.source = source end
  return changed
end

local function saveCache()
  local f = io.open(N.cachePath, "w")
  if not f then return end
  f:write("return {\n")
  for key in pairs(TYPES) do
    local v = N.settings[key]
    if type(v) == "number" then
      f:write(string.format("  %s = %s,\n", key, tostring(v)))
    elseif type(v) == "boolean" then
      f:write(string.format("  %s = %s,\n", key, v and "true" or "false"))
    end
  end
  f:write("}\n")
  f:close()
end

-- Call once at boot, before opening the modem.
function N.loadCache()
  local ok, cached = pcall(dofile, N.cachePath)
  if ok and type(cached) == "table" then
    if N.apply(cached, "cache") > 0 then return true end
    N.source = "cache"
    return true
  end
  return false
end

-- Feed every NODE_SETTINGS message here. Returns true when something changed,
-- which is the node's cue to re-apply modem strength and repaint.
--
-- The message is already-unserialized data from a broadcast, so it is checked
-- rather than trusted: an empty or malformed push is ignored outright instead
-- of resetting a working node to defaults.
function N.handlePush(msg)
  if type(msg) ~= "table" then return false end
  if msg.protocol ~= "MEDINA_COMMAND" or msg.payloadType ~= "NODE_SETTINGS" then
    return false
  end
  if type(msg.data) ~= "table" or not next(msg.data) then return false end
  local changed = N.apply(msg.data, "broker")
  N.source = "broker"
  if changed > 0 then saveCache() end
  return changed > 0
end

return N
