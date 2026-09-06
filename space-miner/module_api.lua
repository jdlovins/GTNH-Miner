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
-- Nothing else on the miner path moved. setWorkAllowed() and isMachineActive()
-- are the same call in both, and the whole consumable path -- iface.store{label},
-- setInterfaceConfiguration, the transposer -- never changed at all. So this file
-- owns four calls and no more; if you find yourself version-gating anything else,
-- check first, because it is probably not actually version-dependent.
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
-- WHICH DIALECT DOES THIS ADAPTER SPEAK?
--
-- Probed, not configured, because the two method names cannot both be present:
-- 2.9 removed setParameters outright, which is precisely how the broker found
-- out about the break -- "attempt to call a nil value (field 'setParameters')".
-- Presence of the method IS the answer.
--
-- Returns nil for an adapter with neither, which is not a mining module (or is
-- an address pointing at the wrong block). Callers must treat that as a hardware
-- error rather than picking a default: guessing here means every start silently
-- does nothing.
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

-- Resolve the dialect for one adapter given the `gtVersion` setting.
-- Returns (dialect, how) where `how` is "probed" | "forced" | nil.
--
-- A forced setting is honoured even when it contradicts the probe. That is the
-- point of having it: if GTNH ships a version where both methods exist, or one
-- exists but throws, the probe is the thing that is wrong and the operator needs
-- a way to say so without editing code.
function api.resolve(adapter, setting)
  if setting == api.V29 or setting == api.V28 then return setting, "forced" end
  local probed = api.detect(adapter)
  if probed then return probed, "probed" end
  return nil, nil
end

-- "GTNH 2.9 (probed)" — for the boot log and the module panel.
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
