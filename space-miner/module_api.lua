-- =============================================================================
-- module_api.lua — the one place that knows which GTNH the modules speak
--
-- GTNH renamed the Space Elevator Mining Module's parameter API between 2.8 and
-- 2.9, and the two forms are disjoint:
--
--                 GTNH 2.8                          GTNH 2.9
--   distance      setParameters(distanceParam,0,d)  setParameter("distance", d)
--   parallel      -- module GUI only --             setParameter("parallel", n)
--   cycle mode    -- module GUI only --             setParameter("cycle", false)
--   introspect    getParametersInfo()               getParameters()
--
-- 2.9 also renamed the mining drone's tier marker -- "Mining Drone MK-IX (UHV)"
-- became "Mining Drone Mk-IX (UHV)". That is not a call, it is an item LABEL,
-- and it matters because labels are how the whole consumable path resolves a
-- drone: iface.store{label} on the loader, getItemsInNetwork{label} on the hw
-- node. An earlier version of this header claimed that path "never changed at
-- all". It had, and the fleet sat idle with every drone counted as zero.
--
-- The marker cannot be probed. There is no method whose presence answers "what
-- does this pack call the item", so unlike the four calls above it has to be
-- CONFIGURED -- which is why gtVersion is a stored setting rather than a probe,
-- and why detect() below no longer decides anything. See api.mark().
--
-- Everything else on the miner path really is unchanged: setWorkAllowed() and
-- isMachineActive() are the same call in both, as is setInterfaceConfiguration
-- and the transposer. So this file owns four calls and one string, and no more;
-- if you find yourself version-gating anything else, check first, because it is
-- probably not actually version-dependent.
--
-- No `component` require. Every hardware handle arrives on the `mod` table the
-- way loader.lua takes them, which is what makes this file drivable from plain
-- Lua with a fake adapter and no game running.
--
-- If GTNH renames this a third time, this file is the only thing that changes --
-- the same bargain space-pumping/config.lua's paramKeys table makes.
-- =============================================================================

local api = {}

api.V29 = "2.9"
api.V28 = "2.8"

-- ---------------------------------------------------------------------------
-- THE DRONE TIER MARKER
--
-- "Mining Drone MK-IX (UHV)" on 2.8, "Mining Drone Mk-IX (UHV)" on 2.9. One
-- string, and the reason gtVersion is a setting instead of a probe: config.lua
-- rewrites config.drones through this, and the broker ships it to the hw node
-- with DRILL_PAR, because that node holds no config and cannot work it out.
--
-- Falls back to the 2.9 spelling for an unknown version rather than returning
-- nil. A nil here would concatenate into "Mining Drone nil-IX (UHV)" three
-- layers away from the mistake; a wrong-but-plausible label fails as a clean
-- "no drones in stock", which is the symptom this whole change exists to fix
-- and is therefore the one an operator has a chance of recognising.
-- ---------------------------------------------------------------------------
api.MARK = { [api.V28] = "MK", [api.V29] = "Mk" }

function api.mark(version)
  return api.MARK[version] or api.MARK[api.V29]
end

-- Rewrite one drone label for `version`. Case-insensitive on the way in so it
-- is idempotent -- relabelling an already-relabelled table is a no-op, not a
-- miss -- and anchored on "Mining Drone " so it cannot chew on anything else.
function api.relabel(label, version)
  if type(label) ~= "string" then return label end
  return (label:gsub("^(Mining Drone )[Mm][Kk]%-", "%1" .. api.mark(version) .. "-"))
end

-- ---------------------------------------------------------------------------
-- WHICH DIALECT DOES THIS ADAPTER SPEAK?
--
-- The two method names cannot both be present: 2.9 removed setParameters
-- outright, which is precisely how the broker found out about the break --
-- "attempt to call a nil value (field 'setParameters')". Presence of the method
-- IS the answer, for the API.
--
-- This no longer DECIDES anything (see check() below for why). It is kept
-- because it is still the truth about the hardware, and comparing it against
-- the configured version is what turns a wrong gtVersion into a boot warning
-- instead of a module that loads a full set of consumables and only then
-- discovers it cannot be told where to mine.
--
-- Returns nil for an adapter with neither, which is not a mining module (or is
-- an address pointing at the wrong block).
-- ---------------------------------------------------------------------------
function api.detect(adapter)
  if type(adapter) ~= "table" and type(adapter) ~= "userdata" then return nil end
  -- pcall'd: a proxy for a component that vanished (chunk unload) throws on
  -- field access rather than answering nil.
  local ok, has29 = pcall(function() return adapter.setParameter  ~= nil end)
  if ok and has29 then return api.V29 end
  local ok28, has28 = pcall(function() return adapter.setParameters ~= nil end)
  if ok28 and has28 then return api.V28 end
  return nil
end

-- ---------------------------------------------------------------------------
-- THE CONFIGURED VERSION IS THE ANSWER. THE PROBE ONLY GETS TO OBJECT.
--
-- This used to probe per adapter and fall back to the setting. It does not any
-- more, and the drone label is why: an item name has no method to probe for, so
-- it has to be configured -- and a system that probes the API while configuring
-- the label holds two sources of truth for one fact, free to disagree. There is
-- now one, chosen at the boot prompt and pushed to the nodes that need it.
--
-- Returns (dialect, how). `how` is "configured" for a version we recognise, and
-- the pair is (nil, nil) for one we do not, which callers must treat as a
-- hardware error rather than defaulting -- guessing means every start silently
-- does nothing.
-- ---------------------------------------------------------------------------
function api.resolve(_adapter, setting)
  if setting == api.V29 or setting == api.V28 then return setting, "configured" end
  return nil, nil
end

-- Does the hardware agree with what it was told? Returns nil when it does (or
-- when there is nothing to compare against), and a one-line description of the
-- disagreement when it does not.
--
-- An adapter that answers neither dialect is NOT a mismatch: it is not a mining
-- module at all, which is a different failure with its own error at the call
-- site. Saying both would bury the real one.
function api.check(adapter, setting)
  local probed = api.detect(adapter)
  if not probed or not setting then return nil end
  if probed == setting then return nil end
  return "configured for GTNH " .. tostring(setting) ..
         " but this module speaks " .. probed ..
         " -- check the gtVersion setting"
end

-- "GTNH 2.9 (configured)" — for the boot log and the module panel.
function api.describe(mod)
  if not mod.dialect then return "GTNH ?" end
  return "GTNH " .. mod.dialect .. (mod.dialectHow and (" (" .. mod.dialectHow .. ")") or "")
end

-- ---------------------------------------------------------------------------
-- SET EVERY PARAMETER A RUN NEEDS.
--
-- Does NOT open the work gate; the caller does that, and separately, so a
-- parameter failure and a gate failure report as different errors.
--
-- pcall is deliberate and not upstream's: a nil setParameter is exactly what
-- took the broker down before, and this runs inside pollLoad, where a throw
-- kills the main loop and with it every other module. On failure one module
-- goes ERROR and the rest keep mining.
--
-- On 2.8 only distance is settable. parallel and cycle live in the module's own
-- GUI there, so the broker leaves them alone -- writing a 2.9 key on a 2.8
-- module would throw, and there is no 2.8 equivalent to write instead.
--
-- Returns ok, err.
-- ---------------------------------------------------------------------------
function api.configure(mod, job)
  local dialect = mod.dialect
  local distance = job and job.distance
  if distance == nil then return false, "no distance in job" end

  if dialect == api.V29 then
    local ok, err = pcall(function()
      mod.adapter.setParameter("distance", distance)
      mod.adapter.setParameter("parallel", (job and job.parallels) or 1)
      -- "cycle=false" pins a static distance; with cycle on, the module sweeps
      -- between distance-range and distance+range and getOptimalDistance's
      -- choice stops meaning anything.
      mod.adapter.setParameter("cycle", false)
    end)
    if not ok then return false, "setParameter: " .. tostring(err) end
    return true

  elseif dialect == api.V28 then
    local idx = mod.conf and mod.conf.distanceParam
    if idx == nil then
      return false, "distanceParam not set in job_node_config.lua (required on GTNH 2.8)"
    end
    local ok, err = pcall(function()
      mod.adapter.setParameters(idx, 0, distance)
    end)
    if not ok then return false, "setParameters: " .. tostring(err) end
    return true
  end

  return false, "unknown module API dialect: " .. tostring(dialect)
end

-- Put the module back to a neutral distance after a run, so a restart cannot
-- inherit the last job's target. Same pcall reasoning as configure().
function api.resetDistance(mod)
  local dialect = mod.dialect

  if dialect == api.V29 then
    local ok, err = pcall(function() mod.adapter.setParameter("distance", 1) end)
    if not ok then return false, "setParameter: " .. tostring(err) end
    return true

  elseif dialect == api.V28 then
    local idx = mod.conf and mod.conf.distanceParam
    if idx == nil then return false, "distanceParam not set in job_node_config.lua" end
    local ok, err = pcall(function() mod.adapter.setParameters(idx, 0, 1) end)
    if not ok then return false, "setParameters: " .. tostring(err) end
    return true
  end

  return false, "unknown module API dialect: " .. tostring(dialect)
end

return api
