-- =============================================================================
-- settings.lua — the tunable registry
--
-- Every runtime knob you are meant to TURN is declared here, once, and nowhere
-- else. A declaration carries what the value is, what it may legally be, and one
-- line of what it does. Three things read this file and they all read the same
-- declarations:
--
--   config.lua   seeds config.<key> with the default, then applies the user
--                overlay through the same validation the editor uses.
--   broker-mk3   builds the in-game settings page straight from S.list, so a
--                new knob appears in the editor the moment it is declared.
--   the nodes    receive the scope="node" subset over the wire, which is why
--                a dust or fluid node no longer carries a config file of its
--                own.
--
-- `help` is one short line, sized for the editor's help column. The long-form
-- reasoning -- why maxConcurrentLoads is 0, what the run-poll measurements
-- were -- lives in SETTINGS.md, which does not have to be loaded into the
-- memory of a machine that only wanted to know a number.
--
-- WHAT IS DELIBERATELY NOT HERE. broker-mk3.lua keeps a handful of constants of
-- its own (ERROR_TIMEOUT, DONE_SETTLE, JOB_STALE, RUN_STARTUP_GRACE,
-- RUN_POLL_INTERVAL, RUN_INACTIVE_CONFIRM, RUN_HEARTBEAT_INTERVAL,
-- RUN_WARN_COOLDOWN, PIN_RESTOCK_INTERVAL), and loader.lua keeps its own
-- timeouts and MAX_CFG_SLOTS. Those are not preferences -- they are load-bearing
-- against the hardware's behaviour, and a wrong value produces a subtly broken
-- module rather than a slower one. They stay next to the code that depends on
-- them, where the reasoning for each is written out. If you find yourself
-- wanting to turn one, read that comment first; it usually explains why the
-- number is what it is.
-- =============================================================================

local S = {}

-- Display order for the editor. Anything declared with an unknown group is
-- still shown, under "OTHER", rather than silently dropped.
S.groups = {
  { id = "dispatch", label = "DISPATCH        (what goes out, and how often)" },
  { id = "load",     label = "LOAD BUFFER     (what a module is given to work with)" },
  { id = "restock",  label = "RESTOCK         (keeping consumables on the shelf)" },
  { id = "run",      label = "RUN POLLING     (how often a running module is asked)" },
  { id = "nodes",    label = "TELEMETRY NODES (pushed to dust/fluid/hw over the air)" },
  { id = "ui",       label = "INTERFACE       (this screen)" },
  { id = "logging",  label = "LOGGING         (see logger.lua)" },
  { id = "hardware", label = "HARDWARE        (how many drones you own)" },
  { id = "compat",   label = "COMPATIBILITY   (which GTNH this fleet runs)" },
  { id = "other",    label = "OTHER" },
}

-- ---------------------------------------------------------------------------
-- THE REGISTRY
--
--   key      config path. A dotted key writes into a nested table.
--   type     "bool" | "int" | "number" | "choice" | "text"
--   default  what ships. Also what "reset" restores.
--   min/max  inclusive bounds for int/number. Out-of-range input is refused,
--            not clamped -- a clamp hides a typo, a refusal shows it.
--   choices  for type="choice": the values, in cycle order.
--   apply    optional. Maps the stored value to what consumers read, for the
--            handful of settings whose wire form is not their runtime form.
--   scope    "node" marks a setting broadcast to the telemetry nodes.
-- ---------------------------------------------------------------------------
S.list = {
  -- --- DISPATCH ------------------------------------------------------------
  { key = "asteroidCap", group = "dispatch", type = "choice", default = "auto",
    choices = { "auto", "all", "1", "2", "3", "4", "5", "6", "8" },
    label = "Asteroid cap",
    help  = "modules allowed on one asteroid; auto = half+1, and no cap for a lone target",
    -- Consumers expect nil / "all" / a number, which is what they expected
    -- before this file existed. The choice list is the editable form.
    apply = function(v)
      if v == "auto" then return nil end
      if v == "all"  then return "all" end
      return tonumber(v)
    end },

  { key = "dispatchInterval", group = "dispatch", type = "number", default = 0.2,
    min = 0.05, max = 5,
    label = "Dispatch interval", help = "seconds between sweeps looking for an idle module" },

  { key = "maxConcurrentLoads", group = "dispatch", type = "int", default = 0,
    min = 0, max = 12,
    label = "Max concurrent loads", help = "0 = no limit; raise the limit only if load times climb" },

  { group = "dispatch", type = "note",
    text = "fastReload and holdTimeout below change what a FINISHED module does with its drone" },

  { key = "fastReload", group = "dispatch", type = "bool", default = true,
    label = "Fast reload",
    help  = "a finished module holds its drone when the next job wants the same one" },

  { key = "holdTimeout", group = "dispatch", type = "int", default = 10,
    min = 1, max = 120,
    label = "Hold timeout", help = "seconds a held drone waits to be claimed before being returned" },

  -- --- LOAD BUFFER ---------------------------------------------------------
  { key = "tipsPerLoad", group = "load", type = "int", default = 128, min = 1, max = 1024,
    label = "Drill tips per load", help = "tips put in the bus per module load (also sets the dispatch floor)" },

  { key = "rodsPerLoad", group = "load", type = "int", default = 128, min = 1, max = 1024,
    label = "Drill rods per load", help = "rods put in the bus per module load (also sets the dispatch floor)" },

  { key = "tipsToStart", group = "load", type = "int", default = 64, min = 1, max = 1024,
    label = "Tips needed to start", help = "module starts once this many have arrived; the rest fills while mining" },

  { key = "rodsToStart", group = "load", type = "int", default = 64, min = 1, max = 1024,
    label = "Rods needed to start", help = "module starts once this many have arrived; the rest fills while mining" },

  { key = "topUpWindow", group = "load", type = "int", default = 30, min = 0, max = 600,
    label = "Top-up window", help = "seconds after start the buffer may still be finished (unpinned modules)" },

  { key = "preDrainWait", group = "load", type = "number", default = 2.0, min = 0, max = 60,
    label = "Pre-drain wait", help = "seconds given to the ME to absorb returned items before loading again" },

  -- --- RESTOCK -------------------------------------------------------------
  { key = "drillRestock", group = "restock", type = "bool", default = true,
    label = "Auto-craft drill consumables",
    help  = "off = never ask the hw node to craft tips or rods; stock them yourself" },

  -- NOT scope = "node". The hw node is the only machine that cares about these
  -- two, and it does not listen on the command port that carries NODE_SETTINGS
  -- -- it is deliberately kept off it so the dust watchlist never reaches its
  -- memory. Both ride along inside DRILL_PAR on the hardware port instead. This
  -- one was tagged scope = "node" and so went out to the dust and fluid nodes
  -- every broadcast, which hold no such key and dropped it.
  { key = "drillCraftSlots", group = "restock", type = "int", default = 2, min = 1, max = 16,
    label = "Concurrent drill crafts", help = "match your AE2 crafting CPUs; too high gets requests rejected" },

  -- --- RUN POLLING ---------------------------------------------------------
  { key = "runPollIdle", group = "run", type = "number", default = 1.5, min = 0, max = 10,
    label = "Idle poll interval", help = "seconds between checks inside the safe window; 0 = always poll fast" },

  { key = "runSafeFraction", group = "run", type = "number", default = 0.8, min = 0.1, max = 1.0,
    label = "Safe window fraction", help = "how much of the shortest observed run counts as safe to poll lazily" },

  -- --- TELEMETRY NODES -----------------------------------------------------
  -- These reach the nodes over the air. Each node script carries a matching
  -- cold-start default at the top of its own file -- it loads no config -- and
  -- takes these the moment the broker's first broadcast arrives.
  { key = "dustScanInterval", group = "nodes", type = "int", default = 10, min = 2, max = 600,
    scope = "node",
    label = "Dust scan interval", help = "seconds between ME dust scans on the dust node" },

  { key = "fluidScanInterval", group = "nodes", type = "int", default = 10, min = 2, max = 600,
    scope = "node",
    label = "Plasma scan interval", help = "seconds between fluid scans on the plasma node" },

  -- Not the hw node: it stays off the command port to keep the dust watchlist
  -- out of its memory, so nothing pushes it settings. It holds 400 itself.
  { key = "wirelessStrength", group = "nodes", type = "int", default = 400, min = 16, max = 400,
    scope = "node",
    label = "Wireless strength", help = "modem range in blocks, on the broker and the dust/fluid nodes" },

  { key = "nodeDashboard", group = "nodes", type = "bool", default = true, scope = "node",
    label = "Node dashboards", help = "let the dust/fluid nodes draw their screens; off saves them GPU calls" },

  -- --- INTERFACE -----------------------------------------------------------
  { key = "uiInterval", group = "ui", type = "number", default = 0.1, min = 0.05, max = 2,
    label = "Dashboard repaint", help = "seconds between dashboard repaints (unchanged rows cost nothing)" },

  { key = "watchlistInterval", group = "ui", type = "int", default = 30, min = 5, max = 600,
    label = "Broadcast interval", help = "seconds between watchlist / par / node-settings re-broadcasts" },

  { key = "quiesceSeconds", group = "ui", type = "int", default = 10, min = 0, max = 120,
    label = "Editor quiesce", help = "countdown before the editor opens, while dispatch drains to idle" },

  { key = "quiesceGrace", group = "ui", type = "int", default = 60, min = 0, max = 300,
    label = "Editor quiesce grace", help = "extra wait for in-flight loads, then the editor opens regardless" },

  -- --- LOGGING -------------------------------------------------------------
  { key = "logging.enabled", group = "logging", type = "bool", default = false,
    label = "Logging enabled", help = "off still writes ERROR/WARN to the file; on adds INFO/DEBUG" },

  { key = "logging.backend", group = "logging", type = "choice", default = "file",
    choices = { "file", "console", "loki" },
    label = "Log backend", help = "where lines go: a file, this screen, or a Loki server" },

  { key = "logging.file", group = "logging", type = "text", default = "/tmp/spacemining.log",
    label = "Log file", help = "path written when the backend is 'file'" },

  { key = "logging.maxFileBytes", group = "logging", type = "int", default = 65536,
    min = 1024, max = 1048576,
    label = "Log file cap", help = "bytes; the log is truncated when it grows past this" },

  { key = "logging.lokiHost", group = "logging", type = "text", default = "127.0.0.1",
    label = "Loki host", help = "only used when the backend is 'loki'" },

  { key = "logging.lokiPort", group = "logging", type = "int", default = 3100, min = 1, max = 65535,
    label = "Loki port", help = "only used when the backend is 'loki'" },

  { key = "logging.bootUnixTime", group = "logging", type = "int", default = 0, min = 0,
    label = "Boot epoch", help = "real unix seconds at boot, to anchor timestamps; 0 = uptime-relative" },

  -- --- HARDWARE ------------------------------------------------------------
  -- HOW MANY DRONES YOU OWN. Declared, not measured, and that is the point.
  --
  -- hw_telem reports what the ME NETWORK holds, which is only ever half the
  -- picture: a drone sitting in a module's input bus, in an interface buffer, or
  -- mid-transfer is not in the network, so the sensor calls it missing. The
  -- broker used to reconstruct the difference from dispatch timestamps, and
  -- every way of getting that wrong has now been found the hard way -- a tier
  -- frozen at a stale count, a returned drone invisible for a sweep, a drone
  -- left in a bus invisible at boot, and a sweep timestamp that records when the
  -- message ARRIVED rather than when the scan ran.
  --
  -- Tips and rods are consumed, so their counts genuinely have to be measured.
  -- A drone is a durable asset: you own ten, they move between the network and a
  -- bus, and nothing destroys them. So say how many there are and let the broker
  -- keep the ledger -- free = declared - committed - held, with no window and no
  -- timestamp anywhere in it.
  --
  -- Telemetry still reports drones; the dashboard shows it as an AUDIT against
  -- these numbers, so a fleet that has drifted says so instead of quietly
  -- mis-dispatching. Update these when you craft or lose a drone.
  { key = "droneStock.lv", group = "hardware", type = "int", default = 0, min = 0, max = 999,
    label = "LV drones", help = "how many Mining Drone Mk-I (LV) you own" },
  { key = "droneStock.mv", group = "hardware", type = "int", default = 0, min = 0, max = 999,
    label = "MV drones", help = "how many Mining Drone Mk-II (MV) you own" },
  { key = "droneStock.hv", group = "hardware", type = "int", default = 0, min = 0, max = 999,
    label = "HV drones", help = "how many Mining Drone Mk-III (HV) you own" },
  { key = "droneStock.ev", group = "hardware", type = "int", default = 0, min = 0, max = 999,
    label = "EV drones", help = "how many Mining Drone Mk-IV (EV) you own" },
  { key = "droneStock.iv", group = "hardware", type = "int", default = 0, min = 0, max = 999,
    label = "IV drones", help = "how many Mining Drone Mk-V (IV) you own" },
  { key = "droneStock.luv", group = "hardware", type = "int", default = 0, min = 0, max = 999,
    label = "LuV drones", help = "how many Mining Drone Mk-VI (LuV) you own" },
  { key = "droneStock.zpm", group = "hardware", type = "int", default = 0, min = 0, max = 999,
    label = "ZPM drones", help = "how many Mining Drone Mk-VII (ZPM) you own" },
  { key = "droneStock.uv", group = "hardware", type = "int", default = 0, min = 0, max = 999,
    label = "UV drones", help = "how many Mining Drone Mk-VIII (UV) you own" },
  { key = "droneStock.uhv", group = "hardware", type = "int", default = 0, min = 0, max = 999,
    label = "UHV drones", help = "how many Mining Drone Mk-IX (UHV) you own" },
  { key = "droneStock.uev", group = "hardware", type = "int", default = 0, min = 0, max = 999,
    label = "UEV drones", help = "how many Mining Drone Mk-X (UEV) you own" },
  { key = "droneStock.uiv", group = "hardware", type = "int", default = 0, min = 0, max = 999,
    label = "UIV drones", help = "how many Mining Drone Mk-XI (UIV) you own" },
  { key = "droneStock.umv", group = "hardware", type = "int", default = 0, min = 0, max = 999,
    label = "UMV drones", help = "how many Mining Drone Mk-XII (UMV) you own" },
  { key = "droneStock.uxv", group = "hardware", type = "int", default = 0, min = 0, max = 999,
    label = "UXV drones", help = "how many Mining Drone Mk-XIII (UXV) you own" },
  { key = "droneStock.max", group = "hardware", type = "int", default = 0, min = 0, max = 999,
    label = "MAX drones", help = "how many Mining Drone Mk-XIV (MAX) you own" },

  -- --- COMPATIBILITY -------------------------------------------------------
  -- Which GTNH this fleet is running. Two things hang off it, module_api.lua
  -- holds both, and THEY DO NOT SHARE A BOUNDARY -- which is why there are
  -- three choices for two parameter APIs:
  --
  --     2.9          setParameter    drones "Mk-"   (beta 3 onward)
  --     2.9-pre-b3   setParameter    drones "MK-"
  --     2.8          setParameters   drones "MK-"
  --
  -- The drone label is an item name, so it has nothing to probe for -- and the
  -- middle row makes that permanent rather than merely awkward: a probe answers
  -- "setParameter" for both 2.9 rows and cannot tell their labels apart. So it
  -- is configured. module_api's detect() still runs at startup, but only to
  -- warn when a module's actual API disagrees with what it was told.
  --
  -- Not scope = "node": the dust and fluid nodes have no use for it, and the hw
  -- node -- which does, for the drone labels -- stays off the command port and
  -- receives the marker with DRILL_PAR instead, the same way drillCraftSlots
  -- does. See broadcastDrillPar() in broker-mk3.lua.
  { key = "gtVersion", group = "compat", type = "choice", default = "2.9",
    choices = { "2.9", "2.9-pre-b3", "2.8" },
    label = "GTNH version",
    help  = "parameter API + drone names; 2.9-pre-b3 is 2.9 before beta 3" },
}

-- ---------------------------------------------------------------------------
-- INDEX AND PATH ACCESS
-- ---------------------------------------------------------------------------

S.byKey = {}
for _, spec in ipairs(S.list) do
  if spec.type ~= "note" then S.byKey[spec.key] = spec end
end

-- Split "logging.file" once, at load, rather than on every get and set.
for key, spec in pairs(S.byKey) do
  local path = {}
  for part in key:gmatch("[^.]+") do path[#path + 1] = part end
  spec.path = path
end

local function getPath(tbl, path)
  local t = tbl
  for i = 1, #path - 1 do
    t = t[path[i]]
    if type(t) ~= "table" then return nil end
  end
  return t[path[#path]]
end

local function setPath(tbl, path, value)
  local t = tbl
  for i = 1, #path - 1 do
    if type(t[path[i]]) ~= "table" then t[path[i]] = {} end
    t = t[path[i]]
  end
  t[path[#path]] = value
end

function S.get(tbl, key)
  local spec = S.byKey[key]
  -- Explicit `if`, not `and/or`: a boolean setting that is legitimately false
  -- would come back as nil from the idiom, which reads as "not configured".
  if not spec then return nil end
  return getPath(tbl, spec.path)
end

function S.set(tbl, key, value)
  local spec = S.byKey[key]
  if spec then setPath(tbl, spec.path, value) end
end

-- ---------------------------------------------------------------------------
-- VALIDATION
--
-- Returns the accepted value, or nil plus a reason. The reason is shown to
-- whoever typed it, so it says what was wrong rather than just "invalid".
-- ---------------------------------------------------------------------------
function S.coerce(spec, value)
  if spec.type == "bool" then
    if type(value) == "boolean" then return value end
    if value == "true"  or value == 1 then return true  end
    if value == "false" or value == 0 then return false end
    return nil, "expected true or false"

  elseif spec.type == "int" or spec.type == "number" then
    local n = tonumber(value)
    if not n then return nil, "not a number" end
    if spec.type == "int" then n = math.floor(n) end
    if spec.min and n < spec.min then
      return nil, string.format("below the minimum of %s", tostring(spec.min))
    end
    if spec.max and n > spec.max then
      return nil, string.format("above the maximum of %s", tostring(spec.max))
    end
    return n

  elseif spec.type == "choice" then
    local s = tostring(value)
    for _, c in ipairs(spec.choices) do
      if tostring(c) == s then return c end
    end
    return nil, "must be one of: " .. table.concat(spec.choices, ", ")

  elseif spec.type == "text" then
    if type(value) ~= "string" then return nil, "expected text" end
    return value
  end

  return nil, "unknown setting type"
end

-- The next value when the editor cycles a choice or flips a bool.
function S.cycle(spec, value)
  if spec.type == "bool" then return not value end
  if spec.type == "choice" then
    for i, c in ipairs(spec.choices) do
      if tostring(c) == tostring(value) then
        return spec.choices[(i % #spec.choices) + 1]
      end
    end
    return spec.choices[1]
  end
  return value
end

-- What the value looks like on the settings page.
function S.display(spec, value)
  if spec.type == "bool" then return value and "ON" or "OFF" end
  if value == nil then return "-" end
  return tostring(value)
end

-- ---------------------------------------------------------------------------
-- APPLYING A SET OF VALUES
--
-- `raw` holds the stored form (what user_config.lua carries and the editor
-- edits); `config` receives the runtime form. They differ only where a spec
-- declares an `apply`, but keeping the two separate is what lets the editor
-- round-trip "auto" instead of having to infer it back from a nil.
-- ---------------------------------------------------------------------------

-- Seed a config table with every default. Called once by config.lua.
-- `apply` may legitimately return nil -- that is how asteroidCap spells "no
-- cap" -- so it is called through an if, never through `and/or`, which would
-- quietly hand the stored form back instead.
local function runtimeValue(spec, stored)
  if spec.apply then return spec.apply(stored) end
  return stored
end

function S.defaults(config)
  local raw = {}
  for key, spec in pairs(S.byKey) do
    raw[key] = spec.default
    setPath(config, spec.path, runtimeValue(spec, spec.default))
  end
  return raw
end

-- Merge validated overrides into an existing raw table and a config table.
-- Unknown keys and invalid values are collected in `rejected` rather than
-- thrown: a config file from a newer version should not stop the broker.
function S.merge(config, raw, overrides)
  local rejected = {}
  if type(overrides) ~= "table" then return rejected end
  for key, value in pairs(overrides) do
    local spec = S.byKey[key]
    if not spec then
      rejected[key] = "unknown setting"
    else
      local ok, why = S.coerce(spec, value)
      if ok == nil then
        rejected[key] = why
      else
        raw[key] = ok
        setPath(config, spec.path, runtimeValue(spec, ok))
      end
    end
  end
  return rejected
end

-- Apply one already-validated value to a live config, the way the editor does
-- after a save. Same mapping as the overlay, so a setting cannot behave one way
-- at boot and another after an edit.
function S.applyOne(config, key, value)
  local spec = S.byKey[key]
  if not spec then return false end
  setPath(config, spec.path, runtimeValue(spec, value))
  return true
end

-- The scope="node" subset, in stored form, ready to serialize. Small on
-- purpose: this crosses the wire every broadcast interval and lands on the
-- most memory-constrained machines in the fleet.
function S.nodePayload(raw)
  local out = {}
  for key, spec in pairs(S.byKey) do
    if spec.scope == "node" then out[key] = raw[key] end
  end
  return out
end

return S
