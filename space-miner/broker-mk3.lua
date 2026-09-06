-- =============================================================================
-- MEDINA BROKER MK3  (v1.5)
-- Consolidated broker: telemetry aggregation + dispatch + cooperative consumable
-- loading, all on one computer.
--
-- WHAT'S NEW vs MK2:
--   - Loads run as cooperative TASKS (see scheduler.lua + loader.lua), so all six
--     modules load concurrently and the UI / telemetry NEVER freeze.
--   - The 10-second per-module stagger is GONE. Loads are self-pacing: each one
--     confirms its database fingerprints by read-back (db.get) instead of sleeping
--     a fixed guess. Fast when the server is fast, patient when it lags.
--   - One clock for everything (computer.uptime, via the scheduler).
--
-- Hardware (unchanged from MK2):
--   - T2 Wireless Network Card (telemetry on config.ports.telemetry)
--   - GPU + screen for UI
--   - ONE OC Database (slots partitioned per module: M1->1-3, M2->4-6, ...)
--   - Per-module: Adapter (module controller), Adapter (ME interface), Transposer
--
-- Requires: /home/scheduler.lua, /home/loader.lua, /home/module_api.lua,
--           /home/job_node_config.lua, /home/config.lua, /home/logger.lua
-- =============================================================================

local component     = require("component")
local serial        = require("serialization")
local event         = require("event")
local term          = require("term")
local fs            = require("filesystem")
local computer      = require("computer")

local config        = dofile("/home/config.lua")
local sched         = dofile("/home/scheduler.lua")
local loader        = dofile("/home/loader.lua")
local moduleApi     = dofile("/home/module_api.lua")

local loggingModule = dofile("/home/logger.lua")
assert(loggingModule and loggingModule.createLogger, "logger.lua not loaded")
local logger = loggingModule.createLogger("broker-mk3")
local getUnixTime = loggingModule.getCurrentTimestamp

logger:info("========== BROKER-MK3 (v1.5) STARTUP ==========")

-- Anything user_config.lua asked for that could not be honoured -- an unknown
-- key, or a value outside the bounds its declaration allows. config.lua carries
-- on with the default rather than refusing to boot, but silence here would mean
-- an edit that quietly did nothing, so say so on the console as well as the log.
for key, why in pairs(config.settingsRejected or {}) do
  local line = "user_config.lua: ignoring " .. key .. " (" .. why .. ")"
  logger:warn(line)
  print(line)
end

-- =============================================================================
-- HARDWARE VALIDATION
-- =============================================================================

if not component.isAvailable("modem") then error("Missing network card.") end
local modem = component.modem
if not modem.isWireless or not modem.isWireless() then
  error("Requires a T2 Wireless Network Card.")
end
modem.setStrength(config.wirelessStrength)
modem.open(config.ports.telemetry)
logger:info("Modem listening on port " .. config.ports.telemetry)

local gpu = component.isAvailable("gpu") and component.gpu or nil

-- =============================================================================
-- LOAD MODULE CONFIG
-- =============================================================================

local CONFIG_PATH = "/home/job_node_config.lua"
assert(fs.exists(CONFIG_PATH), "Missing " .. CONFIG_PATH)
local nodeConf = dofile(CONFIG_PATH)
local nodeId = assert(nodeConf.nodeId, "nodeId missing from job_node_config.lua")

local function getProxy(addr, label)
  if not addr or addr == "" then error(label .. ": address not configured") end
  local full = component.get(addr)
  if not full then error(label .. ": component '" .. addr .. "' not found") end
  return component.proxy(full)
end

assert(nodeConf.dbAddr and nodeConf.dbAddr ~= "", "dbAddr not set in job_node_config.lua")
local dbAddr = component.get(nodeConf.dbAddr)
assert(dbAddr, "database component '" .. nodeConf.dbAddr .. "' not found")
local db = component.proxy(dbAddr)

local modules = {}
for i, mc in ipairs(nodeConf.modules) do
  local lbl = "Module " .. i
  modules[i] = {
    index           = i,
    tier            = mc.tier,
    pinnedAsteroid  = mc.pinnedAsteroid, -- if set, this module ONLY mines this asteroid
    conf            = mc,
    adapter         = getProxy(mc.moduleAddr, lbl .. " moduleAddr"),
    iface           = getProxy(mc.ifaceAddr, lbl .. " ifaceAddr"),
    transposer      = getProxy(mc.transposerAddr, lbl .. " transposerAddr"),
    status          = "IDLE", -- IDLE | LOADING | RUNNING | DONE | ERROR
    job             = nil,
    doneTime        = nil,
    loadHandle      = nil, -- scheduler task handle while LOADING
    loadResult      = nil, -- set by the load task: { ok=bool, err=?, stats=? }
    runStartedAt    = nil,
    lastRunPollAt   = 0,
    inactiveStreak  = 0,
    inactiveSinceAt = nil,
    nextHeartbeatAt = 0,
    lastRunWarnAt   = 0,
    -- Which GTNH parameter API this module's controller speaks. Filled in by
    -- initModules(), because resolving it needs config.gtVersion and a live
    -- adapter, and a module that answers neither dialect must be reported on
    -- the dashboard rather than erroring the whole boot.
    dialect         = nil,
    dialectHow      = nil,
  }
end

-- (Modules are disabled/cleared after the dashboard frame is drawn, so boot
--  shows progress instead of a blank console. See initModules() below.)

-- Surface task crashes in the log instead of swallowing them, and mark the
-- module failed so it does not sit in LOADING forever.
--
-- DEFINED HERE, BELOW `modules`, AND THAT POSITION IS THE WHOLE POINT. This
-- handler used to be assigned up beside the logger, forty lines before
-- `local modules` existed -- so the closure captured the GLOBAL `modules`, which
-- is nil. Every task crash then threw `ipairs(nil)` inside the scheduler's
-- `pcall(scheduler.onError, ...)`, where it was swallowed: the log line above
-- was written, loadResult was never set, pollLoad returned early forever, and
-- the module stayed in LOADING until the broker was restarted. The comment
-- claiming to prevent exactly that was the only part of it that worked.
--
-- space-pumping/autoPump.lua has the same handler ordered correctly; this now
-- matches it.
sched.onError = function(name, err)
  logger:error("[TASK] " .. tostring(name) .. " crashed: " .. tostring(err))
  -- Find the module whose load task just crashed and mark it failed.
  for _, mod in ipairs(modules) do
    if mod.status == "LOADING" and not mod.loadResult then
      mod.loadResult = { ok = false, err = "task crashed: " .. tostring(err) }
    end
  end
end

-- =============================================================================
-- BROKER STATE
-- =============================================================================

local brokerState = {
  dust = {},
  plasma = {},
  drones = {},
  drills = {},
  -- What the hw node currently has on order, keyed by ME label. Populated
  -- wholesale from HW_UPDATE -- see processMessage() -- so an entry that
  -- resolves itself (a craft lands, a pattern gets added) disappears on its own.
  crafting = {},
  -- payloadType -> reason, for a node that has given up publishing figures.
  -- Non-empty means dispatch is held; the panels name the node and the reason.
  nodeError = {},
  -- payloadType -> how many scans ago the figures we hold were fresh. Set while
  -- a node is coping with a transient fault; dispatch continues.
  nodeRecast = {},
  jobs = {},
  -- itemName -> asteroid, for needs no drone in stock can reach. Rebuilt every
  -- dispatch so it clears itself the moment a suitable drone appears.
  blocked = {},
  cooldowns = {},
  lastDustSyncTime = 0,
  lastFluidSyncTime = 0,
  lastHWSyncTime = 0,
  lastDustSync = "--:--:--",
  lastFluidSync = "--:--:--",
  lastHWSync = "--:--:--",
  -- Outbound, unlike the three above. Without this there is no way to tell a
  -- broker that is publishing par from one running code that cannot.
  lastParSend = "--:--:--",
  lastParCount = 0,
  nextTarget = nil,
  telemetryReady = false,
  priorityMode = "threshold", -- "threshold" (lowest fill first) | "rarity" (dust priority first)
}

-- CYCLE ACCOUNTING
--
-- "Did last night produce less ore?" is unanswerable by watching the dashboard,
-- and one night's yield is a noisy sample anyway. What IS measurable is where a
-- module's time goes: mining is the productive part and everything else --
-- loading, returning, waiting for a job -- is overhead. Duty cycle makes that a
-- number you can compare between runs instead of a feeling.
local cycleStats = {
  cycles    = 0,     -- completed load->mine->return cycles
  loadTime  = 0,     -- seconds spent LOADING
  runTime   = 0,     -- seconds spent RUNNING (the only productive state)
  doneTime  = 0,     -- seconds spent returning items
  idleTime  = 0,     -- seconds spent IDLE waiting for a job
  loadMax   = 0,
  loads     = 0,     -- completed loads; a cycle can contain more than one
  refills   = 0,     -- top-ups that actually moved consumables
  spins     = 0,     -- gate-open -> machine-running samples
  spinTime  = 0,
  spinMax   = 0,
  startedAt = 0,     -- set once telemetry is ready and work can actually begin
}

-- RECENT WINDOW
--
-- The figures above are lifetime totals, and a lifetime average is the wrong
-- answer to "is it fast right now". Twice in this project a cumulative number
-- was read as current and produced a wrong conclusion: a load average still
-- carrying the cold start read as a regression, and a high-water max that can
-- never come down read as an ongoing problem.
--
-- So keep the last few cycles as well, and show both.
local RECENT_N = 10
local recent, recentAt = {}, 0

local function recentPush(rec)
  recentAt = (recentAt % RECENT_N) + 1
  recent[recentAt] = rec
end

local function recentStats()
  local n, run, load, done, idle, refills = 0, 0, 0, 0, 0, 0
  for _, r in pairs(recent) do
    n       = n + 1
    run     = run + r.run
    load    = load + r.load
    done    = done + r.done
    idle    = idle + r.idle
    refills = refills + r.refills
  end
  if n == 0 then return nil end
  local total = run + load + done + idle
  return {
    n       = n,
    duty    = (total > 0) and (run / total * 100) or 0,
    load    = load / n,
    refills = refills / n,
  }
end

local function statsDuty()
  local total = cycleStats.loadTime + cycleStats.runTime
             + cycleStats.doneTime + cycleStats.idleTime
  if total <= 0 then return 0 end
  return cycleStats.runTime / total * 100
end

--------------------------------------------------------------------------------
-- COMPUTATION DEMAND
--
-- Every mining recipe draws computation per parallel per second
-- (config.asteroids[x].computation -- see the legend in config.lua). Nothing
-- read that field before, so "how much computation does this array need?" could
-- only be answered by hand, against whatever happened to be running.
--
-- One instantaneous reading is too jumpy to size a research network from --
-- modules start and finish constantly -- so keep a time-weighted average over a
-- 5 minute window plus the high-water mark. The peak is what the supply has to
-- cover or a recipe stalls; the average is what it sustains.
--
-- The window measures demand WHILE MINING: an interval with nothing running is
-- skipped rather than averaged in as zero. Counting idle time would make the
-- figure a function of how busy dispatch happened to be, when the question being
-- asked is what the array needs when work is happening.
--------------------------------------------------------------------------------
local COMP_BUCKET  = 5      -- seconds per bucket
local COMP_BUCKETS = 60     -- 60 * 5s = a 5 minute window
local compRing     = {}     -- [i] = { stamp, sum, dt }
local compPeak     = 0
local compLastAt   = nil

-- What the array draws right now. RUNNING only: a module draws no computation
-- while it is loading, returning or idle.
local function computationDemand()
  local total = 0
  for _, mod in ipairs(modules) do
    if mod.status == "RUNNING" and mod.job then
      local a = config.asteroids[mod.job.asteroid]
      -- A job naming an asteroid this config no longer has must not take the
      -- dashboard down with it.
      total = total + ((a and a.computation or 0) * (mod.job.parallels or 0))
    end
  end
  return total
end

-- Fold the interval since the last call into the ring. Called from the main
-- loop, NOT from the draw path: the editor suppresses redraws while modules keep
-- mining, and sampling only on frames that paint would drop that time.
local function computationSample()
  local now  = computer.uptime()
  local last = compLastAt
  if not last then compLastAt = now return end

  -- The main loop spins about a hundred times a second and there is nothing to
  -- learn from sampling that often. Returning WITHOUT advancing compLastAt is
  -- the point: the interval is not dropped, it is folded into the next sample.
  local dt = now - last
  if dt < 0.1 then return end
  compLastAt = now

  -- Clamp, so one stalled iteration cannot inject a single huge weight.
  if dt > COMP_BUCKET then dt = COMP_BUCKET end

  local demand = computationDemand()
  if demand <= 0 then return end                  -- not mining: interval excluded
  if demand > compPeak then compPeak = demand end

  local stamp = math.floor(now / COMP_BUCKET)
  local i = (stamp % COMP_BUCKETS) + 1
  local b = compRing[i]
  -- Age out by stamp rather than by walking the buckets we skipped: after a long
  -- stall the ring may have wrapped several times over, and each bucket already
  -- carries what is needed to tell stale from current.
  if not b or b.stamp ~= stamp then
    b = { stamp = stamp, sum = 0, dt = 0 }
    compRing[i] = b
  end
  b.sum = b.sum + demand * dt
  b.dt  = b.dt + dt
end

-- now, the windowed average (nil until the window holds some mining time), peak.
local function computationStats()
  local oldest = math.floor(computer.uptime() / COMP_BUCKET) - COMP_BUCKETS
  local sum, dt = 0, 0
  for _, b in pairs(compRing) do
    if b.stamp > oldest then
      sum = sum + b.sum
      dt  = dt + b.dt
    end
  end
  return computationDemand(), (dt > 0) and (sum / dt) or nil, compPeak
end

local drillKeyOrder = {
  "steel", "titanium", "tungstensteel", "naquadah",
  "naquadahAlloy", "neutronium", "cosmicNeutronium", "infinity", "transcendentMetal"
}

-- Which drill materials can this base actually consume right now?
--
-- Par for a material we have no drone for is pure noise: it cannot be
-- dispatched, so the kits are never spent, and on a network without the pattern
-- it produces a permanent row of red on both dashboards. Worse, for the top
-- tiers it would queue genuinely expensive crafts for hardware not owned.
--
-- Lives up here rather than beside broadcastDrillPar, its only caller until
-- now, because the editor's drill page has to say the same thing: a par you
-- just switched on for a tier you own no drone for is not going out, and
-- silently not going out is how it would otherwise look like a broken save.
local function usableDrillKeys()
  local keys = {}

  -- Drones sitting in the staging network.
  for droneKey, count in pairs(brokerState.drones) do
    if (count or 0) > 0 then
      local tier = config.droneTierKeys[droneKey]
      local dk   = tier and config.droneDrillMap[tier]
      if dk then keys[dk] = true end
    end
  end

  -- Plus anything a busy module is holding. A drone loaded into a running
  -- module is NOT in the ME network, so it reports zero above -- and dropping
  -- its material from par mid-run is exactly backwards, since that is the
  -- material actively being consumed.
  for _, mod in ipairs(modules) do
    if mod.status ~= "IDLE" and mod.job and mod.job.drillKey then
      keys[mod.job.drillKey] = true
    end
  end

  return keys
end

for _, cond in ipairs(config.conditions) do
  brokerState.dust[cond.itemName] = { stock = 0, threshold = cond.amountToMaintain }
end
for _, name in ipairs(config.plasmaKeyOrder) do brokerState.plasma[name] = 0 end
for _, key in ipairs(config.droneKeyOrder) do brokerState.drones[key] = 0 end
for _, key in ipairs(drillKeyOrder) do brokerState.drills[key] = { kits = 0, tips = 0, rods = 0 } end

-- UI layout (three panels).
-- Precedence trap: `local W, H = gpu and gpu.maxResolution() or 120, 50` binds
-- as `W = (gpu and gpu.maxResolution() or 120), H = 50`, so the screen's real
-- height was never read -- H was pinned at 50 whatever the hardware said. On
-- anything shorter the list drew off the bottom of the screen.
local W, H = 120, 50
if gpu then
  local mw, mh = gpu.maxResolution()
  W, H = mw or W, mh or H
  gpu.setResolution(W, H)
end
local P1 = 1
local P2 = math.floor(W / 3) + 1
local P3 = math.floor(W * 2 / 3) + 1
local PW = P2 - 2

-- Dust panel scroll offset (index into the sorted list, 0 = top). Each entry
-- occupies two rows, so a full condition list runs off the bottom long before
-- it is fully shown; without this the overflow was simply invisible.
local dustScroll = 0

-- Every interval from here down is REAL SECONDS against computer.uptime().
-- They used to be compared against os.time(), which in OpenOS is world time, not
-- real time -- so "0.2" and "10" were in a unit nobody had established and the
-- waits they produced were whatever they happened to be. The scheduler's own
-- header says not to mix the two; the lifecycle was doing it anyway.
-- Cadences live in settings.lua and are edited in game; they are read live from
-- `config` at every use rather than copied into a local here, so an edit takes
-- effect on the next pass instead of the next reboot.
local lastDispatchCheck = 0
local ERROR_TIMEOUT = 5      -- before a faulted module is recovered and reused
local lastErrorTime = {}
local DONE_SETTLE = 0.25     -- let the return transfers land before reloading
local JOB_STALE   = 300      -- housekeeping only

-- RUNNING watchdog tuning (real seconds via computer.uptime).
-- Require brief startup grace plus repeated inactive polls before DONE.
local RUN_STARTUP_GRACE = 3.0
-- How quickly we notice a module has finished, and therefore how long it sits
-- idle before it can be reloaded. Confirmations x interval is pure dead time at
-- the end of EVERY cycle: at 0.5s x 3 that was about 1.5s per module per cycle.
--
-- 0.25s costs six modules about 12 extra isMachineActive calls a second, which
-- was not affordable when the dashboard was spending ~890 calls/s and is now
-- trivially so. The confirmation count stays at 3, because the point of it is to
-- survive an unlucky poll, and that is unchanged by polling more often.
local RUN_POLL_INTERVAL = 0.25
local RUN_INACTIVE_CONFIRM = 3

-- ADAPTIVE COMPLETION POLLING
--
-- Asking a module whether it has finished costs a component call, and at 0.25s
-- apart that is four a second EACH. Nine running modules spend 36 calls a
-- second on a question whose answer is "no" for about 56 seconds out of every
-- 62 -- while a whole load is 39 calls. The watchdog was outspending the work
-- it competes with, and halving the interval to cut detection latency doubled
-- it.
--
-- A module's run length is very predictable: it stops when its consumables run
-- out, and the buffer is fixed. So the previous run is a good estimate of the
-- next, and no extra hardware call is needed to learn it -- runStartedAt and
-- the DONE transition already bracket it.
--
-- Poll lazily until the estimate says the end is near, then at the normal rate.
-- Detection latency at the end of a run is unchanged; the standing cost drops
-- by roughly six times.
--
-- Deliberately an interval and not a single scheduled wake-up: if a module
-- stops early, or the estimate is wrong, something must still be watching. This
-- degrades to "late by RUN_POLL_IDLE"; a hard schedule degrades to "nobody
-- notices".
-- Run length is NOT constant: one recipe cycle varies from about 3s to 15s and a
-- run is several cycles, so predicting when a run will END is unreliable. An
-- estimate that says 70s when the run actually stops at 40s would leave us
-- polling lazily through the finish.
--
-- So do not predict the end. Track the SHORTEST run this module has ever done
-- and be lazy only within a fraction of that -- a window it has demonstrably
-- never finished inside. Outside that window, poll normally. Wrong estimates
-- then cost nothing, because the window only ever shrinks toward the truth.
local RUN_POLL_IDLE   = 3.0   -- interval inside the safe window (0 disables)
local RUN_SAFE_FRAC   = 0.8   -- of the shortest run seen, to allow for variance
local RUN_HEARTBEAT_INTERVAL = 120
local RUN_WARN_COOLDOWN = 60

-- Pinned modules keep their input bus topped up on this interval (real seconds)
-- so they never run dry and bounce through DONE/reload.
local PIN_RESTOCK_INTERVAL = 3.0

-- =============================================================================
-- MODULE LIFECYCLE
-- =============================================================================

-- Read the bus in one call rather than one per slot. This runs in DONE, once
-- per cycle per module, and was measuring about two seconds of every cycle --
-- the last per-slot scan left in the broker after the loader and restock paths
-- were converted.
--
-- Defined before snapshotSide's owner is in scope, so it resolves loader lazily.
local function returnItemsToME(mod)
  local busSize = mod.transposer.getInventorySize(mod.conf.inputBusSide) or 16
  local inv
  if loader and loader.snapshotSide then
    inv = loader.snapshotSide(mod, mod.conf.inputBusSide, 1, busSize)
  end
  for slot = 1, busSize do
    local size
    if inv then
      local st = inv[slot]
      size = st and (st.size or 0) or 0
    else
      size = mod.transposer.getSlotStackSize(mod.conf.inputBusSide, slot) or 0
    end
    if size > 0 then
      mod.transposer.transferItem(mod.conf.inputBusSide, mod.conf.interfaceSide, size, slot)
    end
  end
end

-- One implementation, in loader.lua, because the loader is what allocates these
-- slots and so is the only thing that knows how many are in use. This used to be
-- a second copy that always cleared exactly three while the loader could
-- allocate up to eight -- so a load with a start threshold above one stack could
-- leave slots 4-8 configured, with the ME quietly stocking consumables into a
-- bus that was finished with them.
--
-- Costs the same as the old three-slot version in the shipped configuration:
-- see the note on loader.clearInterfaceSlots.
local function clearInterfaceSlots(mod)
  loader.clearInterfaceSlots(mod)
end

local function getOptimalDistance(moduleTier, asteroid, droneKey)
  local m = config.optimizationMatrix
  if m and m[moduleTier] and m[moduleTier][asteroid] and m[moduleTier][asteroid][droneKey] then
    return math.min(200, m[moduleTier][asteroid][droneKey])
  end
  return 50
end

-- Spawn a cooperative load task for a module. The task runs concurrently with
-- every other module's load AND with the UI/telemetry loop.
local function beginLoad(mod)
  -- Time spent IDLE is the cost of not having a job ready: no drone, no kits,
  -- nothing below threshold, or dispatch simply not getting round to it. It is
  -- the overhead that does not show up as a slow load.
  if mod.idleSince then
    local waited = computer.uptime() - mod.idleSince
    cycleStats.idleTime = cycleStats.idleTime + waited
    mod.cycIdle   = waited
    mod.idleSince = nil
  end
  mod.loadResult = nil
  mod.loadStart = computer.uptime() -- real seconds, for elapsed readout
  -- Hard-stop the module before loading. If work is still enabled (e.g. after an
  -- ERROR auto-recovery), the multiblock will grab the freshly loaded tips/rod/
  -- drone and start a cycle mid-load, eating a cycle's worth of tips before the
  -- loader verifies the bus. That produced the false "tip shortfall" errors.
  pcall(function() mod.adapter.setWorkAllowed(false) end)
  mod.loadHandle = sched.spawn(function()
    local success, ok, errOrStats = xpcall(function()
      return loader.run(mod, mod.job, {
        config = config, logger = logger, db = db, dbAddr = dbAddr,
      })
    end, debug.traceback)
    if not success then
      -- loader.run threw an error (ok contains the error message here)
      mod.loadResult = { ok = false, err = "CRASH: " .. tostring(ok) }
    else
      mod.loadResult = ok and { ok = true, stats = errOrStats }
          or { ok = false, err = errOrStats }
    end
  end, "load-M" .. mod.index)
end

-- Called each frame for a LOADING module: check whether its task finished.
local function pollLoad(mod)
  if not mod.loadResult then return end -- still loading

  local r = mod.loadResult
  mod.loadHandle = nil
  mod.loadResult = nil

  if r.ok then
    -- Diagnostics: how many polls did the read-backs take? Tells us whether
    -- store() is reliable on this setup (low) or returns early (higher).
    local s = r.stats or {}
    local cp = s.confirmPolls or {}
    local elapsed = mod.loadStart and (computer.uptime() - mod.loadStart) or 0
    cycleStats.loadTime = cycleStats.loadTime + elapsed
    cycleStats.loads    = cycleStats.loads + 1
    mod.cycLoad         = elapsed
    if elapsed > cycleStats.loadMax then cycleStats.loadMax = elapsed end
    -- Compact on-screen diagnostic: time to load + read-back poll counts.
    -- "db" = max polls any fingerprint needed (low => store() reliable here),
    -- "buf" = polls waiting for items to arrive in the interface buffer.
    local maxConfirm = math.max(cp.drone or 0, cp.tip or 0, cp.rod or 0)
    -- Phase breakdown, because "loaded 43s" says nothing about which part was
    -- slow. pre = waiting for the interface buffer to clear, fill = getting
    -- consumables into the bus, and `waits` is how many fill passes moved
    -- nothing at all -- i.e. time spent purely waiting on the ME to deliver.
    -- @n/m is the start threshold actually in force, so the line identifies
    -- which version of the loader produced it.
    local sw = s.startedWith or {}
    mod.lastLoad = string.format("%.0fs pre%.0f fill%.0f w%d @%d/%d db%d buf%d",
      elapsed, s.preDrainSecs or 0, s.fillSecs or 0, s.fillWaits or 0,
      sw.tips or 0, sw.rods or 0, maxConfirm, s.arrivePolls or 0)
    logger:info(string.format(
      "[LOAD] M%d %.1fs = pre %.1fs + fill %.1fs (%d passes, %d waiting) start %d/%d",
      mod.index, elapsed, s.preDrainSecs or 0, s.fillSecs or 0,
      s.fillPasses or 0, s.fillWaits or 0, sw.tips or 0, sw.rods or 0))
    logger:info(string.format(
      "[LOAD] M%d ready (confirm polls d=%s t=%s r=%s, arrive=%s)",
      mod.index, tostring(cp.drone), tostring(cp.tip), tostring(cp.rod),
      tostring(s.arrivePolls)))
    mod.status = "RUNNING"
    mod.runStartedAt = computer.uptime()
    mod.lastRunPollAt = 0
    mod.inactiveStreak = 0
    mod.inactiveSinceAt = nil
    mod.nextHeartbeatAt = computer.uptime() + RUN_HEARTBEAT_INTERVAL
    mod.lastRunWarnAt = 0
    mod.job.startTime = computer.uptime()
    logger:info(string.format(
      "[HEALTH] M%d started asteroid=%s dist=%s x%s",
      mod.index,
      tostring(mod.job and mod.job.asteroid or "?"),
      tostring(mod.job and mod.job.distance or "?"),
      tostring(mod.job and mod.job.parallels or "?")))
    -- Set every parameter the run needs, in whichever dialect this module
    -- speaks. module_api.lua holds the 2.8/2.9 difference and does the pcall'ing
    -- -- the reasoning for that guard is written out there, and it is the same
    -- reasoning as the gate below.
    local okParams, paramErr = moduleApi.configure(mod, mod.job)
    if not okParams then
      mod.status = "ERROR"
      mod.lastError = tostring(paramErr)
      logger:error("[LOAD] M" .. mod.index .. " parameters failed: " .. tostring(paramErr))
      return
    end

    -- pcall'd for the same reason module_api.configure is: this runs inside
    -- pollLoad, and a throw in pollLoad takes down the main loop and with it
    -- every other module. The guard used to stop one line short of the call that
    -- actually opens the gate.
    local okGate, gateErr = pcall(function() mod.adapter.setWorkAllowed(true) end)
    if not okGate then
      mod.status = "ERROR"
      mod.lastError = "setWorkAllowed: " .. tostring(gateErr)
      logger:error("[LOAD] M" .. mod.index .. " setWorkAllowed failed: " .. tostring(gateErr))
      return
    end
    mod.enabledAt     = computer.uptime()
    mod.refills       = 0
    mod.bufferFilled  = false
    mod.spinupDone    = false
    mod.lastSpinPollAt = 0
  else
    mod.status = "ERROR"
    mod.lastError = tostring(r.err)
    logger:error("[LOAD] M" .. mod.index .. " failed: " .. tostring(r.err))
  end
end

-- Top a running module's input bus back up to full. Reuses the db fingerprints
-- written by the initial load (still valid — we never cleared those slots), so
-- the interface can restock tips/rods by identity. Runs as a task, so it yields
-- while waiting for items to arrive and never blocks the main loop.
--
-- Two callers with different intent, and the difference matters:
--
--   PINNED modules top up forever. That is the point of pinning -- the module
--   stays on one asteroid and should never cycle through DONE/reload.
--
--   Every other module tops up ONCE, to finish the buffer the loader
--   deliberately did not wait for, and then stops. It has to stop: a module
--   with consumables never goes idle, never reaches DONE, and is therefore
--   never re-dispatched -- so topping up forever silently pins every module to
--   whatever asteroid it first picked up and the broker stops responding to
--   what is actually low. Returns true once the buffer is full.
local function restockRunning(mod)
  if mod.status ~= "RUNNING" or not mod.job then return end
  local drill = config.drills[mod.job.drillKey]
  if not drill then return end

  local TIPS_PER = config.tipsPerLoad or 64
  local RODS_PER = config.rodsPerLoad or 64
  local _, slotTip, slotRod = loader.dbSlotsFor(mod.index)
  local ibufSize = mod.transposer.getInventorySize(mod.conf.interfaceSide) or 9
  local busSize = mod.transposer.getInventorySize(mod.conf.inputBusSide) or 16

  -- Count ALL of `label` across the whole bus, not one fixed slot. If we only
  -- checked a fixed slot and the item had shifted, we'd read 0 and re-pull a full
  -- stack every cycle — silently draining the ME and starving other modules.
  -- One call per inventory, not one per slot. These three loops ran every few
  -- seconds for every running module, and the findBuf one ran inside a five
  -- second await polled five times a second -- so a single refill could spend
  -- a couple of hundred component calls doing nothing but waiting, while the
  -- loaders were queueing for the same budget.
  -- Falls back to per-slot reads if loader.lua predates snapshotSide, so a
  -- half-updated /home (new broker, old loader) is slow rather than broken.
  local snap = loader.snapshotSide or function(m, side, from, to)
    local out = {}
    for sl = from, to do out[sl] = m.transposer.getStackInSlot(side, sl) end
    return out
  end

  local function busTotal(label)
    local total, firstSlot = 0, nil
    local inv = snap(mod, mod.conf.inputBusSide, 1, busSize)
    for s = 1, busSize do
      local st = inv[s]
      if st and st.label == label then
        total = total + (st.size or 0)
        firstSlot = firstSlot or s
      end
    end
    return total, firstSlot
  end

  local function findBuf(label)
    local inv = snap(mod, mod.conf.interfaceSide, 1, ibufSize)
    for s = 1, ibufSize do
      local stack = inv[s]
      if stack and stack.label == label then return s, stack.size or 0 end
    end
    return nil, 0
  end

  -- Where should a refill land? Prefer a partly filled stack of the same item,
  -- otherwise the first empty slot. busTotal already counts the whole bus, but
  -- the transfer used to target the FIRST slot holding the item -- which, once a
  -- load spans more than one stack, is usually the full one, so the move landed
  -- nothing and the module ran dry anyway. Slot 1 is the drone; start at 2.
  local function destFor(label)
    local firstEmpty
    local inv = snap(mod, mod.conf.inputBusSide, 1, busSize)
    for s = 2, busSize do
      local st = inv[s]
      if not st or (st.size or 0) == 0 then
        firstEmpty = firstEmpty or s
      elseif st.label == label then
        local room = (st.maxSize or 64) - (st.size or 0)
        if room > 0 then return s, room end
      end
    end
    if firstEmpty then return firstEmpty, 64 end
    return nil, 0
  end

  -- Did this pass actually move anything? A top-up that moves nothing is the ME
  -- not delivering, not a refill, and counting it would make the stat lie.
  local movedAny = false

  -- Refill one consumable in the bus back up to `target` from the ME interface.
  --
  -- Returns "done" when at target, "nofit" when the bus has no room for more,
  -- and "partial" otherwise. The caller needs the difference: "nofit" is not a
  -- failure to retry, it is the bus being physically full, and retrying it every
  -- three seconds for the whole top-up window achieves nothing.
  local function refill(label, target, cfgSlot, dbSlot)
    if mod.status ~= "RUNNING" then return "partial" end
    local have = busTotal(label)
    local deficit = target - have
    if deficit <= 0 then return "done" end
    local dst = destFor(label)
    if not dst then
      -- Nowhere to put it. 128 of each needs two slots per consumable plus one
      -- for the drone, so a bus with fewer than five usable slots simply cannot
      -- hold a full buffer of both.
      return "nofit"
    end
    -- One stack at a time: that is all an interface buffer slot holds.
    mod.iface.setInterfaceConfiguration(cfgSlot, dbAddr, dbSlot, math.min(deficit, 64))
    -- Half a second between checks, not a fifth. Each check is one call now
    -- rather than nine, but the ME is not going to answer faster for being
    -- asked more often, and this runs concurrently with every other module.
    sched.await(function() return (select(1, findBuf(label))) ~= nil end, 5, 0.5)
    if mod.status ~= "RUNNING" then
      mod.iface.setInterfaceConfiguration(cfgSlot)
      return "partial"
    end
    local src = select(1, findBuf(label))
    if src then
      -- Re-pick the destination: the module has been consuming while we waited.
      local d, r = destFor(label)
      if d then
        local got = mod.transposer.transferItem(mod.conf.interfaceSide,
                      mod.conf.inputBusSide, math.min(deficit, r), src, d)
        if (got or 0) > 0 then movedAny = true end
      end
    end
    if busTotal(label) >= target then
      -- Done with this consumable: release the slot so the interface stops
      -- holding stock we no longer need.
      mod.iface.setInterfaceConfiguration(cfgSlot)
      return "done"
    end

    -- LEAVE THE ORDER STANDING.
    --
    -- Clearing here cancelled it, and the next pass three seconds later placed
    -- the same order again -- so a network that hands over a few items at a time
    -- had its progress thrown away on every pass and started over. Measured in
    -- world at 3.6 refills per cycle to move a single stack.
    --
    -- Standing, the interface keeps accumulating between passes and the next one
    -- collects whatever arrived. stepDone clears every configuration slot when
    -- the run ends, so nothing is left hoarding.
    return "partial"
  end

  local tipState = refill(drill.tip, TIPS_PER, 2, slotTip)
  local rodState = refill(drill.rod, RODS_PER, 3, slotRod)

  -- Stop asking once each consumable is either at target or cannot fit. Waiting
  -- for both to reach target meant a bus too small for two full stacks retried
  -- for the entire window and never finished -- which looked like "sometimes it
  -- does not top up at all".
  if movedAny then
    mod.refills      = (mod.refills or 0) + 1
    cycleStats.refills = (cycleStats.refills or 0) + 1
  end

  local settled = (tipState ~= "partial") and (rodState ~= "partial")
  if settled then
    local tips, rods = busTotal(drill.tip), busTotal(drill.rod)
    logger:info(string.format(
      "[RESTOCK] M%d settled at tips %d/%d (%s), rods %d/%d (%s)",
      mod.index, tips, TIPS_PER, tipState, rods, RODS_PER, rodState))
    if tipState == "nofit" or rodState == "nofit" then
      logger:warn(string.format(
        "[RESTOCK] M%d input bus has no room for a full buffer -- it needs %d free slots " ..
        "(drone + %d stacks of tips + %d stacks of rods)",
        mod.index, 1 + math.ceil(TIPS_PER / 64) + math.ceil(RODS_PER / 64),
        math.ceil(TIPS_PER / 64), math.ceil(RODS_PER / 64)))
    end
  end
  return settled
end

local function stepRunning(mod)
  local now = computer.uptime()

  -- Pinned modules: keep the input bus continuously topped up so they never run
  -- dry (and never cycle through DONE -> return -> IDLE -> reload). We fire a
  -- short cooperative task on an interval that refills tips/rods from the ME via
  -- the interface + transposer. The drone (bus slot 1) isn't consumed, so only
  -- tips (slot 2) and rods (slot 3) are refreshed.
  -- Pinned modules top up for as long as they run. Everyone else only until the
  -- initial buffer is complete, or until the window closes -- after that the
  -- module is allowed to run dry, finish, and be given a different job.
  local topUpWanted = mod.pinnedAsteroid
      or (not mod.bufferFilled
          and (now - (mod.runStartedAt or now)) < (config.topUpWindow or 30))
  if mod.job and topUpWanted then
    if (not mod.restockHandle or mod.restockHandle.done()) and now >= (mod.nextRestockAt or 0) then
      mod.nextRestockAt = now + PIN_RESTOCK_INTERVAL
      mod.restockHandle = sched.spawn(function()
        local ok, full = pcall(restockRunning, mod)
        if not ok then
          logger:warn("[RESTOCK] M" .. mod.index .. " error: " .. tostring(full))
        elseif full and not mod.pinnedAsteroid then
          mod.bufferFilled = true
          logger:info("[RESTOCK] M" .. mod.index .. " buffer complete, letting it run down")
        end
      end, "restock-M" .. mod.index)
    end
  end

  -- SPIN-UP: how long between enabling the work gate and the machine actually
  -- running. Measured separately from load time because they have different
  -- causes and only one of them is ours -- if loads are fast and spin-up is
  -- seconds, the remaining delay is GregTech's, not this broker's.
  if mod.enabledAt and not mod.spinupDone then
    if now - (mod.lastSpinPollAt or 0) >= 0.25 then
      mod.lastSpinPollAt = now
      local okS, active = pcall(mod.adapter.isMachineActive)
      if okS and active then
        local spin = now - mod.enabledAt
        mod.spinupDone = true
        cycleStats.spinTime = (cycleStats.spinTime or 0) + spin
        cycleStats.spins    = (cycleStats.spins or 0) + 1
        if spin > (cycleStats.spinMax or 0) then cycleStats.spinMax = spin end
        logger:info(string.format("[SPINUP] M%d running %.2fs after enable", mod.index, spin))
      end
    end
  end

  -- Grace exists because a machine reads inactive for a moment after the gate
  -- opens. Once the spin-up check above has actually SEEN it active, that
  -- moment has passed and there is nothing left to wait for -- which matters
  -- when a run can be short enough to finish inside a flat 3s grace.
  if not mod.spinupDone
     and mod.runStartedAt and (now - mod.runStartedAt) < RUN_STARTUP_GRACE then
    return
  end

  -- How soon to ask again. Fast near the expected finish and while we have no
  -- estimate; lazy otherwise.
  local interval = RUN_POLL_INTERVAL
  local idle = config.runPollIdle or RUN_POLL_IDLE
  -- A streak already underway is confirmed at the FAST rate. Confirmation is
  -- three polls, so leaving it lazy made an early finish cost 3 x 3s to notice
  -- rather than 3s -- 7.1s worst case, measured, against 0.7s in steady state.
  if idle > 0 and mod.runMin and mod.runStartedAt
     and (mod.inactiveStreak or 0) == 0 then
    local elapsed = now - mod.runStartedAt
    if elapsed < mod.runMin * (config.runSafeFraction or RUN_SAFE_FRAC) then
      interval = idle
    end
  end
  if (now - (mod.lastRunPollAt or 0)) < interval then
    return
  end
  mod.lastRunPollAt = now

  local ok, isActive = pcall(mod.adapter.isMachineActive)
  if not ok then
    mod.inactiveStreak = 0
    if now - (mod.lastRunWarnAt or 0) >= RUN_WARN_COOLDOWN then
      logger:warn("[HEALTH] M" .. mod.index .. " status poll failed: " .. tostring(isActive))
      mod.lastRunWarnAt = now
    end
    return
  end

  if isActive then
    if mod.inactiveStreak and mod.inactiveStreak > 0 and mod.inactiveSinceAt then
      local downFor = now - mod.inactiveSinceAt
      logger:warn(string.format(
        "[HEALTH] M%d recovered after %.1fs inactive blip (streak=%d)",
        mod.index, downFor, mod.inactiveStreak))
    end
    mod.inactiveStreak = 0
    mod.inactiveSinceAt = nil
    if now >= (mod.nextHeartbeatAt or 0) then
      logger:info(string.format(
        "[HEALTH] M%d running asteroid=%s for %.0fs",
        mod.index,
        tostring(mod.job and mod.job.asteroid or "?"),
        now - (mod.runStartedAt or now)))
      mod.nextHeartbeatAt = now + RUN_HEARTBEAT_INTERVAL
    end
    return
  end

  if not mod.inactiveSinceAt then
    mod.inactiveSinceAt = now
  end
  mod.inactiveStreak = (mod.inactiveStreak or 0) + 1
  if mod.inactiveStreak == 1 or (now - (mod.lastRunWarnAt or 0) >= RUN_WARN_COOLDOWN) then
    logger:warn(string.format(
      "[HEALTH] M%d inactive while RUNNING (streak=%d/%d, asteroid=%s)",
      mod.index,
      mod.inactiveStreak,
      RUN_INACTIVE_CONFIRM,
      tostring(mod.job and mod.job.asteroid or "?")))
    mod.lastRunWarnAt = now
  end
  if mod.inactiveStreak < RUN_INACTIVE_CONFIRM then
    return
  end

  logger:warn(string.format(
    "[HEALTH] M%d marking DONE after %.1fs inactive confirmation",
    mod.index,
    now - (mod.inactiveSinceAt or now)))
  local observed = now - (mod.runStartedAt or now)
  cycleStats.runTime = cycleStats.runTime + observed
  mod.cycRun = observed

  -- Remember the SHORTEST run for this configuration. Keyed on asteroid, drill
  -- and parallels because all three change how long a run lasts, and a minimum
  -- learned under one of them is not safe under another.
  --
  -- A minimum rather than an average precisely because run length varies: the
  -- average would sit in the middle of the spread and be wrong, low, half the
  -- time. The minimum can only be too conservative, which costs a few polls.
  local key = table.concat({
    tostring(mod.job and mod.job.asteroid),
    tostring(mod.job and mod.job.drillKey),
    tostring(mod.job and mod.job.parallels or 1),
  }, "/")
  if mod.runMinKey ~= key then
    mod.runMin, mod.runMinKey = observed, key
  elseif observed < (mod.runMin or math.huge) then
    mod.runMin = observed
  end

  mod.status = "DONE"
  -- Failing to close the gate is worth an ERROR, not a shrug: the module would
  -- otherwise keep cycling on whatever is left in its bus while the broker
  -- believes it has stopped.
  local okGate, gateErr = pcall(function() mod.adapter.setWorkAllowed(false) end)
  if not okGate then
    mod.status = "ERROR"
    mod.lastError = "setWorkAllowed(false): " .. tostring(gateErr)
    logger:error("[HEALTH] M" .. mod.index .. " could not stop: " .. tostring(gateErr))
  end
end

local function stepDone(mod)
  if not mod.doneTime then
    mod.doneTime = computer.uptime()
    -- HOLD the drone, do not unload yet.
    --
    -- A finished module has consumed its tips and rods -- that is why it
    -- stopped -- so what this returns is essentially just the drone. And most
    -- re-dispatches send the module straight back to the same asteroid, which
    -- wants that same drone. Handing it to the network, waiting for the network
    -- to absorb it, then asking for it back is a round trip that ends exactly
    -- where it started, once per cycle.
    --
    -- Decide at dispatch, when the next job is actually known. Dispatch is
    -- forced immediately after this, so the hold is normally momentary; the
    -- idle backstop in stepModules covers the case where it is not.
    if config.fastReload then
      mod.holding = mod.job and {
        droneKey = mod.job.droneKey,
        drillKey = mod.job.drillKey,
      } or nil
      mod.heldSince = computer.uptime()
    else
      -- Each guarded separately so one failure does not skip the rest. A module
      -- left with its gate open is the worst of the three outcomes, so it must
      -- not be reachable by a transposer throwing on the line above it.
      local okRet, retErr = pcall(returnItemsToME, mod)
      if not okRet then
        logger:warn("[DONE] M" .. mod.index .. " item return failed: " .. tostring(retErr))
      end
    end
    pcall(clearInterfaceSlots, mod)
    pcall(function() mod.adapter.setWorkAllowed(false) end)
  elseif computer.uptime() - mod.doneTime >= DONE_SETTLE then
    if mod.job and brokerState.jobs[mod.job.jobId] then
      brokerState.jobs[mod.job.jobId] = nil
    end
    local settle = computer.uptime() - mod.doneTime
    cycleStats.doneTime = cycleStats.doneTime + settle
    cycleStats.cycles   = cycleStats.cycles + 1
    recentPush({
      run     = mod.cycRun  or 0,
      load    = mod.cycLoad or 0,
      done    = settle,
      idle    = mod.cycIdle or 0,
      refills = mod.refills or 0,
    })
    mod.idleSince = computer.uptime()
    logger:info(string.format("[CYCLE] M%d done (%d total, duty %.0f%%)",
      mod.index, cycleStats.cycles, statsDuty()))
    mod.job = nil
    mod.status = "IDLE"
    mod.doneTime = nil
    mod.runStartedAt = nil
    mod.lastRunPollAt = 0
    mod.inactiveStreak = 0
    mod.inactiveSinceAt = nil
    mod.nextHeartbeatAt = 0
    mod.lastRunWarnAt = 0
    lastDispatchCheck = computer.uptime() - config.dispatchInterval
  end
end

-- Give back consumables a module is sitting on but not using.
--
-- A held drone is invisible to availableDrones and held kits to availableKits,
-- so a module that holds indefinitely starves the others. Dispatch normally
-- claims them within a fraction of a second; this covers the case where there
-- is no work, no plasma, or no matching need.
local function releaseStaleHold(mod)
  if not mod.holding or mod.status ~= "IDLE" then return end
  if computer.uptime() - (mod.heldSince or 0) < (config.holdTimeout or 10) then return end
  logger:info(string.format("[HOLD] M%d released after %.0fs unclaimed",
    mod.index, computer.uptime() - (mod.heldSince or 0)))
  pcall(returnItemsToME, mod)
  mod.holding, mod.heldSince = nil, nil
end

local function stepModules()
  for _, mod in ipairs(modules) do
    if mod.status == "IDLE" then
      releaseStaleHold(mod)
    elseif mod.status == "LOADING" then
      pollLoad(mod)
    elseif mod.status == "RUNNING" then
      stepRunning(mod)
    elseif mod.status == "DONE" then
      stepDone(mod)
    end
  end
end

-- =============================================================================
-- DISPATCH
-- =============================================================================

-- Prune stale job records (defensive; a job stuck >300s is cleaned up so its
-- bookkeeping entry doesn't linger). The per-asteroid cap reads live module
-- status, not this table, so this is just housekeeping.
local function pruneStaleJobs()
  local now = computer.uptime()
  for jobId, job in pairs(brokerState.jobs) do
    if now - job.startTime > JOB_STALE then brokerState.jobs[jobId] = nil end
  end
end

local function findNeedsList()
  local needs = {}
  for _, cond in ipairs(config.conditions) do
    local stock = (brokerState.dust[cond.itemName] and brokerState.dust[cond.itemName].stock) or 0
    local ratio = stock / cond.amountToMaintain
    if ratio < 1.0 then
      local entry = config.dustTargets[cond.itemName]
      local ast = entry and entry.asteroid
      if ast and config.asteroids[ast] then
        needs[#needs + 1] = { itemName = cond.itemName, asteroid = ast, ratio = ratio, priority = entry.priority or 99 }
      end
    end
  end
  if brokerState.priorityMode == "rarity" then
    -- Rarity first: lowest dustTargets.priority number wins; ties broken by fill.
    table.sort(needs, function(a, b)
      if a.priority ~= b.priority then return a.priority < b.priority end
      return a.ratio < b.ratio
    end)
  else
    -- Threshold: most-depleted (lowest stock/target ratio) first.
    table.sort(needs, function(a, b) return a.ratio < b.ratio end)
  end
  return needs
end

-- How many modules are mid-load right now.
local function loadingCount()
  local n = 0
  for _, m in ipairs(modules) do if m.status == "LOADING" then n = n + 1 end end
  return n
end

local function getIdleModules()
  local idle = {}
  local now = computer.uptime()
  for i, mod in ipairs(modules) do
    -- A module whose parameter API we could not identify is never dispatchable:
    -- the load would run in full and only then discover there is no way to tell
    -- the module where to mine. Re-probe first, because the usual reason for a
    -- nil dialect is an adapter that was mid chunk-reload at boot, and that
    -- fixes itself.
    if not mod.dialect then
      mod.dialect, mod.dialectHow = moduleApi.resolve(mod.adapter, config.gtVersion)
      if mod.dialect then
        logger:info(string.format("[RECOVERY] M%d now speaks %s", i, moduleApi.describe(mod)))
      end
    end

    -- Still unidentified after the re-probe: leave it out of dispatch entirely,
    -- including out of the ERROR recovery below, which would otherwise hand it a
    -- job every ERROR_TIMEOUT seconds forever.
    if mod.dialect then
      if mod.status == "IDLE" then
        idle[#idle + 1] = mod
      elseif mod.status == "ERROR" then
        if not lastErrorTime[i] then
          lastErrorTime[i] = now
        elseif now - lastErrorTime[i] >= ERROR_TIMEOUT then
          pcall(function() mod.adapter.setWorkAllowed(false) end)
          pcall(function() returnItemsToME(mod) end)
          mod.status = "IDLE"; mod.job = nil; mod.doneTime = nil
          lastErrorTime[i] = nil
          logger:info("[RECOVERY] M" .. i .. " auto-recovered from ERROR state")
          idle[#idle + 1] = mod
        end
      end
    end
  end
  return idle
end

-- True when the module is still holding the drone this job wants.
--
-- The DRONE is the only thing that survives a run: tips and rods are consumed,
-- and running out of them is what makes the module stop in the first place. So
-- there is nothing to "keep topped up" across a reload -- consumables are always
-- fetched fresh. What is saved is the drone: returning it to the network,
-- waiting for the network to absorb it, and asking for the same one back.
--
-- drillKey is compared too, though it is implied: config.droneDrillMap derives
-- the drill from the drone's tier, so a matching drone always means a matching
-- drill. Kept explicit so this stays correct if that mapping ever stops being
-- one-to-one.
local function moduleHolds(mod, droneKey, drillKey)
  local h = mod.holding
  return config.fastReload and h ~= nil
     and h.droneKey == droneKey and h.drillKey == drillKey
end

-- Which idle module should take this drone?
--
-- The pool is ordered by module tier then least-recently-used, which decides
-- WHO deserves work. It says nothing about who can start fastest -- and a module
-- already holding this exact drone can skip the whole fetch, while one holding a
-- different drone has to hand its own back and wait for this one.
--
-- Ignoring that produced pointless swaps: the UHV job handed to a module holding
-- a ZPM while the module holding a UHV took the ZPM job. Both then paid a full
-- reload to end up doing what the other was already equipped for.
--
-- So: among the modules that can take this job, prefer one already holding the
-- drone. Falls straight back to pool order when none is, so the fairness
-- ordering is untouched whenever there is nothing to gain.
local function preferHolder(pool, droneKey)
  for idx = #pool, 1, -1 do
    local h = pool[idx].holding
    if h and h.droneKey == droneKey then return idx end
  end
  return nil
end

-- `avail` / `availKit` are the batch's working pools. They are REQUIRED, not
-- optional: this used to gate on brokerState.drones -- the raw ME figure -- which
-- meant the commitment point ignored reservations entirely and only worked
-- because both callers happened to check the pool first. Passing them in makes
-- the gate and the accounting the same numbers.
local function tryDispatch(mod, asteroid, droneKey, avail, availKit)
  local asteroidData = config.asteroids[asteroid]
  if not asteroidData then return false end
  if not droneKey then return false end

  local droneTier = config.droneTierKeys[droneKey]
  if droneTier < asteroidData.minDrone or droneTier > asteroidData.maxDrone then return false end

  local drillKey = config.droneDrillMap[droneTier]
  if not drillKey then return false end

  -- Skip tiers we can't actually load. Upstream checked config.*Registry here,
  -- because its loader writes fingerprints with db.set(registryName, damage). We
  -- kept the iface.store() loader, which resolves items by LABEL, so the tables
  -- that must have an entry are config.drones / config.drills. Same intent --
  -- reject here so dispatch falls back to a lower, fully-known tier instead of
  -- bouncing the module through ERROR/idle -- without indexing a table that does
  -- not exist in this config.
  if not config.drones[droneKey] then return false end
  if not config.drills[drillKey] then return false end

  -- A module still holding this exact hardware does not need the ME to have
  -- another set: the drone never left, and the loader only fetches whatever
  -- consumables it is actually short of.
  local holds = moduleHolds(mod, droneKey, drillKey)
  local minKits = math.max(config.tipsPerLoad or 64, config.rodsPerLoad or 64)

  -- TWO GATES, AND THEY ASK DIFFERENT QUESTIONS.
  --
  -- The pool says whether this drone is still unpromised: it is the ME figure
  -- minus commitments the last sweep has not seen, plus what idle modules are
  -- holding. That is the reservation, and it is what reserveWhileMining moves.
  --
  -- The raw ME figure says whether the drone can actually be FETCHED. Those come
  -- apart for a held drone: the pool counts it as owned (correctly -- it exists),
  -- but it is sitting in one module's input bus, so a DIFFERENT module cannot
  -- load it. Without the second gate that phantom gets handed to whoever is next
  -- in pool order, the loader waits out ARRIVE_TIMEOUT for a drone the network
  -- does not have, and the module lands in ERROR.
  --
  -- A module that holds the hardware needs neither: the drone never left it, and
  -- the loader only fetches what it is short of.
  if not holds then
    if (avail[droneKey] or 0) <= 0 then return false end
    if (brokerState.drones[droneKey] or 0) <= 0 then return false end

    -- Same pair for kits: enough unpromised, and enough actually in the network.
    if (availKit[drillKey] or 0) < minKits then return false end
    local drill = brokerState.drills[drillKey]
    if not drill or (drill.kits or 0) < minKits then return false end
  end

  local jobId = nodeId .. "-" .. math.floor(computer.uptime() * 1000) .. "-M" .. mod.index
  mod.lastDispatchAt = computer.uptime()   -- fairness ordering, see dispatchBatch
  mod.status = "LOADING"
  mod.job = {
    jobId = jobId,
    asteroid = asteroid,
    droneKey = droneKey,
    drillKey = drillKey,
    -- When this commitment was made, so availableDrones/availableKits can tell
    -- whether the last telemetry sweep has seen it leave the ME network yet.
    dispatchedAt = computer.uptime(),
    distance = getOptimalDistance(mod.tier, asteroid, droneKey),
    parallels = config.moduleTiers[mod.tier].maxParallels,
    startTime = computer.uptime(),
  }
  mod.job.fastReload = holds
  if config.fastReload and mod.holding and not holds then
    -- Different hardware this time, so the hold was not useful after all.
    -- Unload now, which is exactly what stepDone used to do unconditionally.
    pcall(returnItemsToME, mod)
  end
  if holds then
    logger:info(string.format("[FASTLOAD] M%d keeping %s for %s (consumables fetched fresh)",
      mod.index, tostring(config.drones[droneKey]), asteroid))
  end
  mod.holding, mod.heldSince = nil, nil

  brokerState.jobs[jobId] = { moduleIndex = mod.index, asteroid = asteroid, startTime = computer.uptime() }
  brokerState.nextTarget = { asteroid = asteroid, reason = "dispatched" }

  beginLoad(mod) -- non-blocking: spawns the cooperative load task
  return true
end

-- Has telemetry already accounted for this commitment?
--
-- HW_UPDATE reports what is in the ME network. A drone pulled two seconds ago
-- may still be counted there, so a commitment newer than the last sweep has to
-- be subtracted by hand or two modules get handed the same physical drone --
-- the bug behind "Infinity Catalyst everywhere" when only one high-tier drone
-- existed.
--
-- But once a sweep has run AFTER the pull, the stock figure already excludes
-- it, and subtracting again counts it twice. That is what idled modules while
-- drones sat in stock: three MK-IX committed against a reported two left read
-- as MINUS one available, so nothing more could dispatch even though two were
-- genuinely free. It also imposed a standing tax of one spare drone per busy
-- module just to keep dispatching.
--
-- If the hw node goes quiet, lastHWSyncTime stops advancing and every
-- commitment counts again -- which is the conservative direction to fail in.
--
-- config.reserveWhileMining skips this question entirely: with it set, a busy
-- module is charged for its drone and kits however long ago telemetry saw them.
-- That reintroduces the standing tax described above on purpose, for setups
-- where the hw node's figures cannot be trusted to be current.
-- hw_telem scans and broadcasts once per loop around a 10s event.pull, so a
-- figure older than this means the node has genuinely stopped reporting rather
-- than merely being between sweeps.
local HW_STALE = 30

local function telemetryHasSeen(mod, strict)
  local at = mod.job and mod.job.dispatchedAt
  if not at then return true end   -- pre-existing job from before this field
  local sync = brokerState.lastHWSyncTime or 0
  -- What reserveWhileMining still buys, now that it no longer double-charges.
  -- If the hw node has gone quiet the FIGURE is old, so no commitment counts as
  -- seen however long ago it was made, and every one is charged again. That is
  -- the conservative direction and it is the case the setting exists for.
  if strict and (computer.uptime() - sync) > HW_STALE then return false end
  return at <= sync
end

-- How many of each drone are actually free to assign right now?
--
-- strict charges every busy module, not just the ones telemetry has yet to see.
-- Callers pass config.reserveWhileMining for the dispatch pool, and false where
-- the question is which tiers this array OWNS rather than which are free.
local function availableDrones(strict)
  local avail = {}
  for key, count in pairs(brokerState.drones) do avail[key] = count end
  for _, mod in ipairs(modules) do
    -- CHARGE ONLY WHAT THE SWEEP HAS NOT SEEN.
    --
    -- This used to read `strict or not telemetryHasSeen(mod)`, which charged
    -- every busy module under reserveWhileMining -- including the ones the ME
    -- figure had ALREADY stopped counting, because their drone is sitting in a
    -- bus. That is a double subtraction, and it is what "forgot a drone" was:
    -- two LuV busy and a third finishing a craft read as 1 - 2 = -1, so a
    -- genuinely free drone would not dispatch. Flooring the result at zero does
    -- not help, since -1 and 0 both mean "cannot dispatch" -- the count itself
    -- had to stop being wrong.
    --
    -- Promising the same drone to two modules in one sweep is prevented by the
    -- batch-local decrements in assignOne and tryDispatchPinned, not by this.
    if mod.status ~= "IDLE" and mod.job and mod.job.droneKey
       and not telemetryHasSeen(mod, strict) then
      local k = mod.job.droneKey
      avail[k] = (avail[k] or 0) - 1
    end
    -- A HELD DRONE IS OWNED. With fastReload a finished module keeps its drone
    -- and goes IDLE with job = nil, so it is charged by nothing above -- and the
    -- ME cannot see it either, because it is physically in the bus. Without this
    -- it exists nowhere in the model until releaseStaleHold fires.
    --
    -- dispatchBatch used to add this back to its own local copy. That is gone;
    -- doing it here is what lets the hardware panel see holds too, and keeping
    -- both would credit every hold twice.
    if config.fastReload and mod.holding and mod.holding.droneKey then
      local k = mod.holding.droneKey
      avail[k] = (avail[k] or 0) + 1
    end
  end
  -- Nothing downstream should have to reason about a negative pool.
  for k, v in pairs(avail) do if v < 0 then avail[k] = 0 end end
  return avail
end

-- Same idea for drill kits, with one extra correction: a load costs a full
-- config.tipsPerLoad / rodsPerLoad, not one kit. Subtracting 1 under-counted an
-- unseen commitment by that whole factor, which every other site in this file
-- already charges in full.
-- Same three changes as availableDrones, for the same reasons: charge only what
-- the sweep has not seen, credit what a module is holding, and never return a
-- negative.
local function availableKits(strict)
  local perLoad = math.max(config.tipsPerLoad or 64, config.rodsPerLoad or 64)
  local avail = {}
  for key, d in pairs(brokerState.drills) do avail[key] = (d and d.kits) or 0 end
  for _, mod in ipairs(modules) do
    if mod.status ~= "IDLE" and mod.job and mod.job.drillKey
       and not telemetryHasSeen(mod, strict) then
      local k = mod.job.drillKey
      avail[k] = (avail[k] or 0) - perLoad
    end
    if config.fastReload and mod.holding and mod.holding.drillKey then
      local k = mod.holding.drillKey
      avail[k] = (avail[k] or 0) + perLoad
    end
  end
  for k, v in pairs(avail) do if v < 0 then avail[k] = 0 end end
  return avail
end

-- ---------------------------------------------------------------------------
-- THE POOLS, FOR ANYONE WHO IS NOT DISPATCHING
--
-- The hardware panel wants the same numbers dispatch uses, but it repaints on
-- uiInterval (0.1s by default) and rebuilding both tables per frame would walk
-- every module and every telemetry key ten times a second for a readout that
-- only changes when something is dispatched or a sweep lands.
--
-- Cached against a stamp that moves on exactly those events, the way dustList
-- caches against edGen. Dispatch itself never calls this: it needs tables it can
-- decrement as it assigns, so it keeps building its own.
--
-- ONE TABLE RATHER THAN SIX LOCALS, because the main chunk is at Lua's 200-local
-- ceiling and this file is the reason. See the K table near the editor.
-- ---------------------------------------------------------------------------
local POOL = { stamp = nil, drones = nil, kits = nil }

function POOL.refresh()
  local parts = { tostring(brokerState.lastHWSyncTime or 0) }
  for _, mod in ipairs(modules) do
    parts[#parts + 1] = mod.status ..
      (mod.job and mod.job.droneKey or "-") ..
      (mod.holding and mod.holding.droneKey or "-")
  end
  local stamp = table.concat(parts, "|")
  if stamp ~= POOL.stamp then
    POOL.stamp  = stamp
    POOL.drones = availableDrones(config.reserveWhileMining or false)
    POOL.kits   = availableKits(config.reserveWhileMining or false)
  end
end

function POOL.freeDrones() POOL.refresh() return POOL.drones end
function POOL.freeKits()   POOL.refresh() return POOL.kits   end

-- Per-asteroid module cap: an asteroid may hold at most "half the modules plus
-- one" at once, so a single high-tier target (e.g. Infinity Catalyst) can take a
-- majority but never starve every other need. Scales with total module count, so
-- it stays correct if this broker grows back into a multi-job-node fleet (up to
-- 24 modules across multiple space elevators, like v1.0).
--
-- Except when there is nothing to starve. The cap exists to divide the fleet
-- between COMPETING needs; with a single asteroid wanted it has no other need to
-- protect and only idles modules for nothing. Five modules and one target meant
-- three mined and two sat there permanently.
--
-- config.asteroidCap overrides: a number pins it, "all" removes it entirely.
local function asteroidCap(needCount)
  local c = config.asteroidCap
  if c == "all" then return #modules end
  if type(c) == "number" and c > 0 then return math.min(c, #modules) end
  if (needCount or 0) <= 1 then return #modules end
  return math.floor(#modules / 2) + 1 -- 6 modules -> 4, 24 -> 13
end

-- Count modules currently committed (loading/running) to each asteroid.
local function activeAsteroidCounts()
  local counts = {}
  for _, mod in ipairs(modules) do
    if mod.status ~= "IDLE" and mod.job and mod.job.asteroid then
      counts[mod.job.asteroid] = (counts[mod.job.asteroid] or 0) + 1
    end
  end
  return counts
end

-- Is any telemetry node reporting that it has given up on its ME query?
--
-- Returns the node's label and the reason, or nil. Dispatch is held while this
-- is set: every input to the decision -- what is low, what hardware is free,
-- whether there is plasma -- comes from these three nodes, and acting on figures
-- a node has disowned is how the fleet ends up mining a shortage that does not
-- exist.
local NODE_LABEL = {
  DUST_UPDATE  = "DUST NODE",
  FLUID_UPDATE = "FLUID NODE",
  HW_UPDATE    = "HW NODE",
}

local function nodeFault()
  -- Fixed order rather than pairs(), so the message does not change between
  -- frames while two nodes are down.
  for _, kind in ipairs({ "DUST_UPDATE", "FLUID_UPDATE", "HW_UPDATE" }) do
    local why = brokerState.nodeError[kind]
    if why then return NODE_LABEL[kind], why end
  end
  return nil
end

-- Mining modules physically require a plasma fluid to operate (any of the five
-- supported plasmas works; higher tiers just improve results). If we have none,
-- a dispatched module would load fine but never actually mine — so don't dispatch.
local function hasPlasma()
  for _, name in ipairs(config.plasmaKeyOrder) do
    if (brokerState.plasma[name] or 0) > 0 then return true end
  end
  return false
end

-- Dispatch a pinned/reserved module to its fixed asteroid, ignoring dust
-- thresholds and the per-asteroid cap. Picks the highest-tier available drone
-- eligible for the asteroid that also has enough drill kits. Returns true if a
-- job was assigned; false if no suitable drone/kits are free this pass (the
-- module just stays idle until they are).
local function tryDispatchPinned(mod, avail, availKit, minKitsForLoad)
  local asteroid = mod.pinnedAsteroid
  local asteroidData = config.asteroids[asteroid]
  if not asteroidData then
    if not mod.pinWarned then
      logger:warn("[PIN] M" .. mod.index .. " pinned to unknown asteroid '" .. tostring(asteroid) .. "'")
      mod.pinWarned = true
    end
    return false
  end
  for _, droneKey in ipairs(config.droneKeyOrder) do
    if (avail[droneKey] or 0) > 0 then
      local droneTier = config.droneTierKeys[droneKey]
      if droneTier >= asteroidData.minDrone and droneTier <= asteroidData.maxDrone then
        local drillKey = config.droneDrillMap[droneTier]
        if drillKey and (availKit[drillKey] or 0) >= minKitsForLoad then
          if tryDispatch(mod, asteroid, droneKey, avail, availKit) then
            avail[droneKey]    = avail[droneKey] - 1
            availKit[drillKey] = availKit[drillKey] - minKitsForLoad
            return true
          end
        end
      end
    end
  end
  return false
end

-- CONCURRENT LOADS
--
-- MK3's headline change was removing a fixed ten-second stagger and letting all
-- six modules load at once. That was right to do -- the stagger was a magic
-- sleep -- but "all at once" turned out to be the wrong replacement, because
-- the loads do not actually run in parallel. They share one computer's
-- component-call budget, which OpenComputers meters at roughly one indirect
-- call per tick.
--
-- Measured in world: one module loading alone took 3 seconds. The same load
-- with five siblings took 22-30. The work did not get slower, it got queued --
-- and running them together means every module finishes late instead of one
-- finishing early.
--
-- For six loads of ~90 calls against ~20 calls a second, the budget is ~27
-- seconds either way. Run them together and all six start mining at 27s, for
-- 162 module-seconds of idling. Run two at a time and they start staggered,
-- for roughly 95 -- the last module is no worse off and every earlier one is
-- mining sooner.
--
-- 0 disables the limit and restores load-everything-at-once.
local function loadSlotsFree()
  -- Default matches config.lua: no limit. A config predating this key should
  -- not quietly reintroduce a cap the shipped settings no longer ask for.
  local cap = config.maxConcurrentLoads or 0
  if cap <= 0 then return math.huge end
  return cap - loadingCount()
end

local function dispatchBatch()
  pruneStaleJobs()

  -- No plasma = modules can't run. Hold dispatch until some is in stock.
  if not hasPlasma() then return end

  local idleModules = getIdleModules()
  if #idleModules == 0 then return end

  -- Only hand out as many jobs as there are free load slots. Trimming here
  -- bounds every path below it -- pinned, needs-based and fallback alike --
  -- rather than each needing its own check. Modules that miss out stay IDLE and
  -- are picked up on the next batch, a fraction of a second later.
  local slots = loadSlotsFree()
  if slots <= 0 then return end
  while #idleModules > slots do table.remove(idleModules) end

  -- Working pools we can still hand out this batch: drones and drill kits.
  local strict         = config.reserveWhileMining or false
  local avail          = availableDrones(strict)
  local availKit       = availableKits(strict)
  local minKitsForLoad = math.max(config.tipsPerLoad or 64, config.rodsPerLoad or 64)

  -- A SECOND view, for reachability only.
  --
  -- Reachability asks whether this array can ever serve a need at all -- a
  -- question about which drone tiers we own, not which are free this instant.
  -- Under reserveWhileMining the dispatch pool deliberately hides every busy
  -- module's drone, and answering from it would report a merely busy fleet as
  -- permanently unable to mine anything, filling the dust panel with "NO DRONE"
  -- for asteroids we have perfectly good drones for.
  --
  -- With the option off these are the same tables, so nothing changes.
  local reachAvail    = strict and availableDrones(false) or avail
  local reachAvailKit = strict and availableKits(false)   or availKit

  -- Held drones and kits used to be credited back here, over this function's
  -- own copies. availableDrones/availableKits do it now, which fixes two things
  -- this version could not: a hold on a module trimmed out of idleModules by the
  -- concurrency cap was never counted, and nothing outside this function -- the
  -- hardware panel especially -- could see a hold at all.

  -- Pinned modules always mine their assigned asteroid, ignoring dust thresholds
  -- and the per-asteroid cap. Handle them first and drop them from the pool so
  -- the needs-based loop below can never reassign them elsewhere (a pinned module
  -- idles rather than mine anything but its target).
  local pool = {}
  for _, mod in ipairs(idleModules) do
    if mod.pinnedAsteroid then
      tryDispatchPinned(mod, avail, availKit, minKitsForLoad)
    else
      pool[#pool + 1] = mod
    end
  end
  if #pool == 0 then return end

  -- Decide which modules get the work when there is not enough to go round.
  --
  -- The assignment loop below walks this pool BACKWARDS (it removes entries as
  -- it goes, which is only safe in that direction), so whatever sits at the END
  -- is served first. Unsorted that was simply the highest-numbered idle module,
  -- which is array position -- meaningless as a policy. Whenever drones, kits
  -- or the per-asteroid cap ran out before the pool did, the same low-numbered
  -- modules lost every time, permanently.
  --
  -- Order by module tier first. A load is 64 tips and rods whatever the tier,
  -- and the total work it buys is the same either way -- an MK-III burns 32 a
  -- cycle for 2 cycles, an MK-I burns 8 for 8, both 16 parallel-runs per load.
  -- What differs is elapsed time: the MK-III is done in a quarter of it. So
  -- when only some modules can run, the higher tier is strictly better --
  -- same consumables, same drone, sooner.
  --
  -- Least-recently-used breaks ties, so equals rotate instead of one of them
  -- starving. Modules that have never run sort oldest and go first, which is
  -- what gets a freshly added module its first job.
  local function parallelsOf(mod)
    local t = config.moduleTiers[mod.tier]
    return (t and t.maxParallels) or 0
  end

  table.sort(pool, function(a, b)
    local pa, pb = parallelsOf(a), parallelsOf(b)
    if pa ~= pb then return pa < pb end          -- weakest first => strongest at the end
    local ta, tb = a.lastDispatchAt or 0, b.lastDispatchAt or 0
    if ta ~= tb then return ta > tb end          -- most recent first => LRU at the end
    return a.index > b.index                     -- deterministic; lowest index served first
  end)

  local needs = findNeedsList()
  if #needs == 0 then return end


  -- Per-asteroid usage: start from what's already committed (including pinned
  -- modules dispatched just above), count up as we go, and never exceed the cap.
  -- This is what frees module slots for lower-tier needs (e.g. Uranium-Plutonium)
  -- instead of one asteroid eating them all.
  -- Can anything we own actually mine this need?
  --
  -- An asteroid accepts a drone tier range, and a need whose range we cannot
  -- reach is not a need this array can serve -- it is a standing wish. Counting
  -- it toward the cap reserves module slots for work that will never be
  -- dispatched: with Ruby Dust needing tier 2-6 and only tier 1, 7 and 9 drones
  -- in stock, four of nine modules sat idle indefinitely while one asteroid was
  -- held at its cap.
  -- Returns true, or false plus WHY. The reason matters: "no drone of the right
  -- tier" and "not enough kits for the drone we do have" need different actions
  -- from you, and a message naming the wrong one is worse than none.
  local function reachability(need)
    local a = config.asteroids[need.asteroid]
    if not a then return false, "noast" end
    local sawDrone, wantKit = false, nil
    for key, n in pairs(reachAvail) do
      if (n or 0) > 0 then
        local tier = config.droneTierKeys[key]
        if tier and tier >= a.minDrone and tier <= a.maxDrone then
          sawDrone = true
          local dk = config.droneDrillMap[tier]
          if dk then
            wantKit = wantKit or dk
            if (reachAvailKit[dk] or 0) >= minKitsForLoad then return true end
          end
        end
      end
    end
    return false, sawDrone and "kits" or "drone", wantKit
  end

  -- "No drone can reach this asteroid" only means something when we HAVE drones.
  -- With an empty stock everything looks unreachable, and saying so per item
  -- would bury the real message -- which the hardware panel already gives as
  -- "[ NO DRONES IN STOCK ]".
  local haveAnyDrone = false
  for key, n in pairs(reachAvail) do
    -- Only drones the config recognises. availableDrones copies whatever keys
    -- telemetry sent, and a key with no tier cannot reach any asteroid -- so
    -- counting it as "we have drones" would make every need look blocked.
    if (n or 0) > 0 and config.droneTierKeys[key] then haveAnyDrone = true break end
  end

  local nReachable = 0
  local blocked = {}
  for _, need in ipairs(needs) do
    local ok, why, kit = reachability(need)
    if ok then
      nReachable = nReachable + 1
    elseif haveAnyDrone then
      blocked[need.itemName] = { asteroid = need.asteroid, why = why, kit = kit }
    end
  end
  -- Surfaced on the dust panel so an unmineable item says so instead of sitting
  -- at a red percentage forever with no explanation.
  brokerState.blocked = blocked

  local cap            = asteroidCap(nReachable)
  local astCount       = activeAsteroidCounts()
  brokerState.cap      = cap   -- surfaced on the hardware panel

  -- Assign in NEED order, one module per need per pass.
  --
  -- findNeedsList() sorts by priority -- lowest stock ratio first under
  -- threshold mode -- and that ordering used to be discarded, kept only as a
  -- membership set. The loop walked drones from the highest tier down and, for
  -- each, scanned config.asteroids in pairs() order taking whatever happened to
  -- be needed. So the best drone in stock claimed every idle module for whatever
  -- it could reach, and a need only reachable by a LOWER tier never got one.
  --
  -- Concretely: six MK-IX and twelve MK-I, Nether Star sitting at 0%. Its
  -- asteroid is Gem Ores, maxDrone 6, so only the MK-I can mine it -- but the
  -- MK-IX emptied the pool first, every pass, forever. The most starved item on
  -- the board was the one guaranteed never to be mined.
  --
  -- One module per need per pass rather than filling a need to its cap before
  -- moving on, so every need gets a module before any gets a second.
  local function assignOne(need)
    local asteroidName = need.asteroid
    local asteroidData = config.asteroids[asteroidName]
    if not asteroidData then return false end
    if (astCount[asteroidName] or 0) >= cap then return false end

    for _, droneKey in ipairs(config.droneKeyOrder) do
      if (avail[droneKey] or 0) > 0 then
        local droneTier = config.droneTierKeys[droneKey]
        if droneTier >= asteroidData.minDrone and droneTier <= asteroidData.maxDrone then
          local drillKey = config.droneDrillMap[droneTier]
          if drillKey and (availKit[drillKey] or 0) >= minKitsForLoad then
            -- Try whoever already holds this drone first, then everyone else
            -- in pool order.
            local first = preferHolder(pool, droneKey)
            local order = {}
            if first then order[#order + 1] = first end
            for idx = #pool, 1, -1 do
              if idx ~= first then order[#order + 1] = idx end
            end
            for _, idx in ipairs(order) do
              local mod = pool[idx]
              if mod and tryDispatch(mod, asteroidName, droneKey, avail, availKit) then
                astCount[asteroidName] = (astCount[asteroidName] or 0) + 1
                avail[droneKey]        = avail[droneKey] - 1
                availKit[drillKey]     = availKit[drillKey] - minKitsForLoad
                table.remove(pool, idx)
                return true
              end
            end
          end
        end
      end
    end
    return false
  end

  while #pool > 0 do
    local assigned = false
    for _, need in ipairs(needs) do
      if #pool == 0 then break end
      if assignOne(need) then assigned = true end
    end
    -- A pass that placed nothing will place nothing next time either: the pool,
    -- the drones and the kits are all unchanged.
    if not assigned then break end
  end

  -- Anything left idle now is idle because of the cap, not for want of drones,
  -- kits or needs -- those all fail inside assignOne regardless of it. A module
  -- mining an already-well-served asteroid still beats a module mining nothing,
  -- so lift the cap for whatever is left rather than reserving slots for needs
  -- that could not take them.
  if #pool > 0 then
    cap = #modules
    while #pool > 0 do
      local assigned = false
      for _, need in ipairs(needs) do
        if #pool == 0 then break end
        if assignOne(need) then assigned = true end
      end
      if not assigned then break end
    end
  end
end

-- =============================================================================
-- TELEMETRY
-- =============================================================================

-- Bumped whenever anything the editor DISPLAYS changes: the row list itself,
-- what is tracked, a target, or the dust stock behind the HAVE column.
--
-- The painter uses it to skip rows it does not need to look at. Without it
-- edDraw rebuilt all ~44 rows' cell tables and signature strings on every
-- repaint just to discover nothing had moved -- cheap in GPU calls after the
-- caching change, but real Lua work, and OpenComputers Lua is slow enough that
-- it showed up as choppy keyboard response.
--
-- Navigation does NOT bump it: moving the selection changes two rows, and those
-- are caught by the selected flag in the row key instead.
local edGen = 0
local function edTouch() edGen = edGen + 1 end

-- Bumped whenever the hardware node's picture changes. The HW panel caches its
-- sorted restock list against this, the same way the dust panel uses edGen:
-- brokerState.crafting is replaced wholesale on every HW_UPDATE, so re-sorting
-- it per frame was re-deriving an answer that only changes every ten seconds.
local hwGen = 0

local function processMessage(evType, _, _, _, _, rawMsg)
  if evType ~= "modem_message" then return end
  local ok, msg = pcall(serial.unserialize, rawMsg)
  if not ok or type(msg) ~= "table" then return end
  if msg.protocol ~= "MEDINA_TELEMETRY" then return end

  -- A NODE REPORTING A FAULT, rather than reporting figures.
  --
  -- A telemetry node whose ME query keeps failing republishes its last good
  -- figures for a few cycles and then stops publishing them at all, sending this
  -- instead. Handled before the payload branches because there is no `data` on
  -- one of these -- the whole point is that the node has nothing it stands
  -- behind.
  --
  -- Keep the figures we already hold: they are stale, but they are the last ones
  -- that were true, and overwriting them with zeroes is the failure this whole
  -- mechanism exists to prevent. Dispatch is held instead (see the main loop),
  -- so nothing acts on them while the fault stands.
  --
  -- The sync CLOCK still advances. The node is alive and talking; it is the ME
  -- behind it that is broken, and letting the sync colour rot to red would say
  -- the opposite.
  if msg.error then
    brokerState.nodeError[msg.payloadType] = tostring(msg.error)
    if     msg.payloadType == "DUST_UPDATE"  then
      brokerState.lastDustSyncTime  = computer.uptime()
      brokerState.lastDustSync      = os.date("%X")
    elseif msg.payloadType == "FLUID_UPDATE" then
      brokerState.lastFluidSyncTime = computer.uptime()
      brokerState.lastFluidSync     = os.date("%X")
    elseif msg.payloadType == "HW_UPDATE"    then
      brokerState.lastHWSyncTime    = computer.uptime()
      brokerState.lastHWSync        = os.date("%X")
    end
    edTouch()
    return
  end

  if not msg.data then return end

  -- Figures arrived, so whatever fault this node was reporting is over.
  -- `recast` means they are held over from an earlier scan rather than fresh;
  -- the node is coping, and the panels say so, but they are real figures and
  -- there is no reason to stop dispatching on them.
  brokerState.nodeError[msg.payloadType]  = nil
  brokerState.nodeRecast[msg.payloadType] = tonumber(msg.recast) or nil

  if msg.payloadType == "DUST_UPDATE" then
    -- Stock only. Thresholds are policy and policy lives here, in
    -- config.conditions -- see broadcastWatchlist(). A node running a stale
    -- config used to be able to overwrite our threshold with its own, and any
    -- item it sent got injected into brokerState.dust whether we track it or
    -- not. Now an untracked name is simply ignored.
    for name, entry in pairs(msg.data) do
      local d = brokerState.dust[name]
      if d then d.stock = entry.stock or 0 end
    end
    edTouch()   -- HAVE column is derived from this
    brokerState.lastDustSyncTime = computer.uptime()
    brokerState.lastDustSync = os.date("%X")
  elseif msg.payloadType == "FLUID_UPDATE" and msg.data.plasmas then
    for name, amount in pairs(msg.data.plasmas) do
      if brokerState.plasma[name] ~= nil then brokerState.plasma[name] = amount end
    end
    brokerState.lastFluidSyncTime = computer.uptime()
    brokerState.lastFluidSync = os.date("%X")
  elseif msg.payloadType == "HW_UPDATE" then
    if msg.data.drones then for k, v in pairs(msg.data.drones) do brokerState.drones[k] = v end end
    if msg.data.drills then for k, v in pairs(msg.data.drills) do brokerState.drills[k] = v end end
    -- Replaced wholesale, not merged like the two above. The node sends its
    -- complete set of outstanding orders every cycle, so assignment is what
    -- lets a resolved entry clear itself -- merging would pin a "nopattern"
    -- warning on screen forever after you added the pattern.
    brokerState.crafting = (type(msg.data.crafting) == "table") and msg.data.crafting or {}
    hwGen = hwGen + 1
    brokerState.lastHWSyncTime = computer.uptime()
    brokerState.lastHWSync = os.date("%X")
  end
end

-- =============================================================================
-- UI
-- =============================================================================

local function getSyncColor(t)
  if not t or t == 0 then return 0x555555 end
  local ago = computer.uptime() - t   -- real seconds now, no tick conversion
  if ago < 60 then return 0x00FF00 elseif ago < 120 then return 0xFFAA00 else return 0xFF4444 end
end

local function formatQty(n)
  if n >= 1000000 then
    return string.format("%.1fm", n / 1000000)
  elseif n >= 1000 then
    return string.format("%.0fk", n / 1000)
  else
    return tostring(n)
  end
end

-- ---------------------------------------------------------------------------
-- DASHBOARD ROW CACHE
--
-- The editor got this treatment (see edPaint/edFresh) and the dashboard never
-- did, so the three panels below repainted every row of every frame, four times
-- a second, whether or not a single number had changed. Measured on six modules
-- with the shipped config: 223 component calls per frame, ~890 a second, for a
-- screen whose contents change every ten seconds when telemetry lands.
--
-- That is not just a slow display. OpenComputers meters direct component calls
-- per tick and serves callers in order, so those 890 calls/second were competing
-- with six loaders doing transposer scans and ME stocking -- which is exactly
-- why the dashboard felt worst when the miner was busiest.
--
-- Three changes, the same ones the editor made:
--   1. gpu.set instead of term.setCursor + io.write -- one call rather than two,
--      and it skips the OpenOS term layer's cursor bookkeeping.
--   2. Colour changes are guarded, so consecutive rows sharing a colour cost one
--      setForeground between them instead of one each.
--   3. Rows are cached by content signature and skipped when unchanged.
--
-- `slot` names a row within a panel ("M12", "D12", "H12") because all three
-- panels share the same y values on different parts of the screen.
-- ---------------------------------------------------------------------------
local dashCache, dashFG = {}, nil

-- Counts rows actually repainted. The quiesce box needs to know whether the
-- panels have drawn over it, and "did anything paint" is cheaper to answer than
-- tracking which rows.
local dashPaints = 0

local function dashInvalidate() dashCache, dashFG = {}, nil end

-- Drop the cache for a band of rows only.
--
-- The quiesce box paints on top of the panels, so the cache is wrong for the
-- rows underneath it -- but ONLY those rows. Dropping the whole cache turned
-- every frame into a full repaint while the box was up, and since the box was
-- redrawn after every repaint, the two fed each other: ~2200 component calls a
-- second for as long as the countdown lasted, which starved the event loop that
-- was supposed to be noticing the next keypress.
local function dashInvalidateRows(y1, y2)
  for y = y1, y2 do
    dashCache["M" .. y] = nil
    dashCache["D" .. y] = nil
    dashCache["H" .. y] = nil
  end
end

local function dashSetFG(c)
  if dashFG ~= c then gpu.setForeground(c); dashFG = c end
end

-- Write one row of a panel, clearing its column strip first. Indentation is
-- baked into `text` so every row of a panel starts at the same x.
local function dashRow(slot, x, width, y, text, color)
  local key = tostring(color) .. "|" .. text
  if dashCache[slot] == key then return end
  dashCache[slot] = key
  dashPaints = dashPaints + 1
  gpu.fill(x, y, width, 1, " ")
  dashSetFG(color)
  gpu.set(x, y, text)
end

-- Blank a row: spacers between sections, and the tail wipe under a panel that
-- shrank. Cached too, so a settled layout stops paying for its blank rows.
local function dashBlank(slot, x, width, y)
  if dashCache[slot] == "" then return end
  dashCache[slot] = ""
  dashPaints = dashPaints + 1
  gpu.fill(x, y, width, 1, " ")
end

local function drawModulePanel()
  local row = 6
  -- No full-column pre-wipe here, and now no unconditional repaint either: each
  -- row is written only when its content differs from what is already there.
  for _, mod in ipairs(modules) do
    if row > H then break end
    -- Pinned/reserved modules get a "*" marker so it's clear at a glance which
    -- ones are locked to a single asteroid. Same width as the normal "  " prefix.
    local pin = mod.pinnedAsteroid and " *" or "  "
    local text, color
    if mod.status == "RUNNING" then
      color = 0xFFAA00
      text = string.format("%sM%d [%-5s]  %s", pin, mod.index, mod.tier, mod.job and mod.job.asteroid or "?")
    elseif mod.status == "LOADING" then
      color = 0xFFFF00
      text = string.format("%sM%d [%-5s]  LOADING %s", pin, mod.index, mod.tier, mod.job and mod.job.asteroid or "")
    elseif mod.status == "ERROR" then
      color = 0xFF4444
      local errMsg = mod.lastError and (" " .. mod.lastError:sub(1, PW - 20)) or ""
      text = string.format("%sM%d [%-5s]  ERROR%s", pin, mod.index, mod.tier, errMsg)
    else
      color = 0x555555
      if mod.pinnedAsteroid then
        text = string.format("%sM%d [%-5s]  IDLE (pin: %s)", pin, mod.index, mod.tier, mod.pinnedAsteroid)
      else
        text = string.format("%sM%d [%-5s]  IDLE", pin, mod.index, mod.tier)
      end
    end
    dashRow("M" .. row, P1 + 1, PW, row, text, color)
    row = row + 1

    if (mod.status == "RUNNING") and mod.job and row <= H then
      local droneName = config.drones[mod.job.droneKey] or "?"
      local lvl = droneName:match("MK%-(.+)") or "?"
      dashRow("M" .. row, P1 + 1, PW, row,
        string.format("  dist=%d  drone=MK-%s  refills=%d",
          mod.job.distance or 0, lvl, mod.refills or 0), 0xCCCCCC)
      row = row + 1

      -- Load diagnostic from the most recent load of this module:
      -- "loaded 0.4s  db:1 buf:3" -- time taken + read-back poll counts.
      if mod.lastLoad and row <= H then
        dashRow("M" .. row, P1 + 1, PW, row, "  " .. mod.lastLoad, 0x668866)
        row = row + 1
      end

      -- Blank spacer line before the next module, per layout.
      if row <= H then
        dashBlank("M" .. row, P1 + 1, PW, row); row = row + 1
      end
    end
  end
  for r = row, H do dashBlank("M" .. r, P1 + 1, PW, r) end
end

-- The sorted dust list, rebuilt only when the underlying stock actually changes.
--
-- This used to be rebuilt AND table.sort'ed on every frame. That was tolerable
-- at four frames a second and became the dominant per-frame cost once the row
-- cache made everything else free -- the panel was sorting the whole condition
-- list to discover that nothing had moved. edGen already ticks whenever dust
-- stock changes (processMessage bumps it), so it is exactly the right key.
local dustList, dustListGen = {}, -1

local function dustSorted()
  if dustListGen == edGen then return dustList end
  local list = {}
  for _, cond in ipairs(config.conditions) do
    local name      = cond.itemName
    local stock     = (brokerState.dust[name] and brokerState.dust[name].stock) or 0
    local ratio     = stock / cond.amountToMaintain
    list[#list + 1] = { name = name, stock = stock, threshold = cond.amountToMaintain, ratio = ratio }
  end
  -- Ends in a name tie-break: pairs order is not involved here, but equal ratios
  -- are common (everything at zero before telemetry lands) and table.sort makes
  -- no promise about their relative order between calls.
  table.sort(list, function(a, b)
    if a.ratio ~= b.ratio then return a.ratio < b.ratio end
    return a.name < b.name
  end)
  dustList, dustListGen = list, edGen
  return dustList
end

local function drawDustPanel()
  local row = 6
  local list = dustSorted()

  -- Two rows per entry, so this is how many entries actually fit.
  local capacity  = math.floor((H - row + 1) / 2)
  local maxScroll = math.max(0, #list - capacity)
  if dustScroll > maxScroll then dustScroll = maxScroll end
  if dustScroll < 0 then dustScroll = 0 end

  -- Range indicator in the panel header, so a truncated list is obvious rather
  -- than looking like the whole list. Painted into a fixed-width region so a
  -- shorter tag cannot leave the tail of a longer one behind it.
  --
  -- A dust-node fault takes the slot instead. Every percentage in this panel is
  -- derived from what that node reports, so when it has stopped reporting, the
  -- state of the list matters far less than the fact that none of it is current.
  local dustFault  = brokerState.nodeError["DUST_UPDATE"]
  local dustRecast = brokerState.nodeRecast["DUST_UPDATE"]
  if #list > 0 then
    local tag, color
    if dustFault then
      tag, color = "STALE - NODE DOWN", 0xFF4444
    elseif dustRecast then
      tag, color = "held " .. dustRecast .. " scan(s)", 0xFFAA00
    else
      tag = string.format("%d-%d/%d",
        math.min(dustScroll + 1, #list), math.min(dustScroll + capacity, #list), #list)
      if maxScroll > 0 then tag = tag .. " ^v" end
      color = maxScroll > 0 and 0xFFAA00 or 0x888888
    end
    local tw = 18
    local tx = math.max(P2 + 1, P3 - tw - 1)
    dashRow("DTAG", tx, tw, 4, string.format("%" .. tw .. "s", tag), color)
  end

  for i = dustScroll + 1, #list do
    local item = list[i]
    if row > H then break end
    local pct = math.floor(item.ratio * 100)
    -- An item nothing in stock can mine is not "low", it is stuck. Saying so is
    -- the difference between a number you act on and a number you stare at:
    -- Ruby Dust sat at 10% indefinitely because its asteroid wants a drone tier
    -- nobody owned, and nothing on screen said which.
    local stuck = brokerState.blocked and brokerState.blocked[item.name]
    local stuckOn = stuck and stuck.asteroid
    local color = stuckOn and 0xFF00FF
        or (item.ratio >= 1.0) and 0x446644 or (item.ratio < 0.25) and 0xFF4444
        or (item.ratio < 0.75) and 0xFFAA00 or 0x00FFFF
    local mark = stuckOn and "x" or (item.ratio < 1.0 and "!" or " ")
    dashRow("D" .. row, P2 + 1, PW, row,
      string.format("  %s %-27s %3d%%", mark, item.name, pct), color)
    row = row + 1
    if row > H then break end
    local detail
    if stuck then
      local a = config.asteroids[stuck.asteroid]
      if stuck.why == "kits" then
        detail = string.format("      NEEDS %d %s KITS for %s",
          math.max(config.tipsPerLoad or 64, config.rodsPerLoad or 64),
          tostring(stuck.kit), stuck.asteroid)
      elseif stuck.why == "noast" then
        detail = "      NO ASTEROID MAPPING -- cannot be mined"
      else
        detail = string.format("      NO DRONE for %s (needs tier %d-%d)",
          stuck.asteroid, a and a.minDrone or 0, a and a.maxDrone or 0)
      end
    else
      detail = string.format("      %s / %s", formatQty(item.stock), formatQty(item.threshold))
    end
    dashRow("D" .. row, P2 + 1, PW, row, detail, stuckOn and 0xFF00FF or 0x666666)
    row = row + 1
  end
  for r = row, H do dashBlank("D" .. r, P2 + 1, PW, r) end
end

-- Restock entries, ranked and cached against hwGen.
--
-- Two reasons to sort. pairs() order is arbitrary and this panel repaints many
-- times a second, so an unsorted list visibly shuffles between frames. And
-- nopattern/failed go first because they are the entries a human has to act on:
-- if the panel runs out of rows, the benign "crafting" lines are the ones that
-- should be cut.
local restockList, restockGen = {}, -1

local function restockSorted()
  if restockGen == hwGen then return restockList end
  local list = {}
  for label in pairs(brokerState.crafting) do list[#list + 1] = label end
  local RANK = { nopattern = 0, failed = 0, crafting = 1, queued = 2 }
  local function rankOf(label)
    local o = brokerState.crafting[label]
    return RANK[type(o) == "table" and o.state or ""] or 3
  end
  table.sort(list, function(a, b)
    local ra, rb = rankOf(a), rankOf(b)
    if ra ~= rb then return ra < rb end
    return a < b
  end)
  restockList, restockGen = list, hwGen
  return restockList
end

-- Panel columns are PW wide and six MK-III modules on a heavy asteroid reach
-- five digits, so abbreviate above 9999 rather than let the row outgrow its
-- panel.
local function fmtComp(v)
  v = v or 0
  if v >= 10000 then return string.format("%.1fk", v / 1000) end
  return string.format("%d", math.floor(v + 0.5))
end

local function drawHWPanel()
  local row = 6
  local function put(text, color)
    if row <= H then dashRow("H" .. row, P3 + 1, PW, row, text, color) end
    row = row + 1
  end

  -- Advance past n blank rows, wiping each one.
  --
  -- Clear-as-you-write covers every row this panel WRITES, but not the spacers
  -- it skips -- and the sections here vary in height, so a row that is a spacer
  -- this frame may have held text last frame. That is how a drone or drill line
  -- appears twice: the list grows by one, every entry shifts down, and the row
  -- the old last entry occupied is now a spacer that nobody wipes. The tail
  -- wipe below only reaches rows underneath the cursor, never these.
  local function skip(n)
    for _ = 1, (n or 1) do
      if row <= H then dashBlank("H" .. row, P3 + 1, PW, row) end
      row = row + 1
    end
  end

  if brokerState.nextTarget then
    put("  NEXT: " .. brokerState.nextTarget.asteroid, 0xFFAA00)
  else
    put("  NEXT: (idle)", 0x666666)
  end

  -- Show the cap dispatch actually used, not a fresh guess: it depends on how
  -- many asteroids are currently wanted, which this panel does not recompute.
  put("  PRIORITY: " .. brokerState.priorityMode:upper() ..
      "   CAP: " .. (brokerState.cap or asteroidCap(0)) .. "/asteroid", 0x666666)

  put("  TELEMETRY SYNC:", 0x666666)
  put("  Dust:   " .. brokerState.lastDustSync,  getSyncColor(brokerState.lastDustSyncTime))
  put("  Fluid:  " .. brokerState.lastFluidSync, getSyncColor(brokerState.lastFluidSyncTime))
  put("  HW:     " .. brokerState.lastHWSync,    getSyncColor(brokerState.lastHWSyncTime))
  -- Outbound par. Grey dashes here mean this broker has never sent DRILL_PAR --
  -- almost always an older broker-mk3.lua, since the send is unconditional.
  -- An explicit "off" rather than a grey zero. Restock disabled and restock
  -- broken look identical on a count alone, and the grey dashes here already
  -- mean a third thing (never sent). Say which one it is.
  if config.drillRestock == false then
    put("  PAR TX: " .. brokerState.lastParSend .. "  (auto-craft OFF)", 0x888888)
  else
    put("  PAR TX: " .. brokerState.lastParSend .. " (" .. brokerState.lastParCount .. ")",
        brokerState.lastParCount > 0 and 0x00FF00 or 0x555555)
  end
  skip(1)

  put("  TASKS RUNNING: " .. sched.count(), 0x888888)
  -- Where module time actually goes. Duty is the share spent mining rather than
  -- loading, returning or waiting for a job -- the number to compare between
  -- runs when output feels off.
  if cycleStats.cycles > 0 then
    local duty = statsDuty()
    -- Lifetime first, then the last few cycles. The pair matters: lifetime says
    -- how the run has gone, recent says how it is going, and reading one as the
    -- other has produced a wrong conclusion here more than once.
    local r = recentStats()
    put(string.format("  CYCLES: %d   DUTY: %.0f%%%s", cycleStats.cycles, duty,
        r and string.format("   last%d %.0f%%", r.n, r.duty) or ""),
        duty >= 80 and 0x00FF00 or duty >= 60 and 0xFFAA00 or 0xFF4444)
    -- Divided by LOADS, not cycles. Dividing load seconds by completed cycles
    -- counted the loads of modules still running against cycles that had
    -- finished, and reported roughly double the real figure -- visibly at odds
    -- with the per-module times on the left of the screen.
    if cycleStats.loads > 0 then
      put(string.format("  LOAD avg %.1fs%s  max %.1fs  (%d)",
          cycleStats.loadTime / cycleStats.loads,
          r and string.format("  last%d %.1fs", r.n, r.load) or "",
          cycleStats.loadMax, cycleStats.loads), 0x668866)
    end
    put(string.format("  REFILLS: %d   %.1f/cycle%s",
        cycleStats.refills or 0, (cycleStats.refills or 0) / cycleStats.cycles,
        r and string.format("   last%d %.1f", r.n, r.refills) or ""),
        0x668866)
    if (cycleStats.spins or 0) > 0 then
      put(string.format("  SPINUP avg %.1fs  max %.1fs",
          cycleStats.spinTime / cycleStats.spins, cycleStats.spinMax), 0x668866)
    end
    put(string.format("  WAIT idle %.1fs/cyc  return %.1fs/cyc",
        cycleStats.idleTime / cycleStats.cycles,
        cycleStats.doneTime / cycleStats.cycles), 0x666666)
  else
    put("  CYCLES: none completed yet", 0x555555)
  end

  -- What the recipes actually draw. Written outside the cycles branch above on
  -- purpose: demand is real from the first running module, long before any cycle
  -- completes. "pk" is what the computation supply has to cover or a module
  -- stalls mid-recipe; "5m" is what it sustains while mining -- idle intervals
  -- are excluded, see computationSample.
  local cNow, cAvg, cPeak = computationStats()
  put(string.format("  COMP/s now %s   5m %s   pk %s",
      fmtComp(cNow), cAvg and fmtComp(cAvg) or "--", fmtComp(cPeak)), 0x668866)
  skip(1)

  -- Plasma stock (required to mine -- a module won't run without a plasma fluid).
  put("  PLASMA STOCK:", 0x888888)
  local anyPlasma = false
  for _, name in ipairs(config.plasmaKeyOrder) do
    local amt = brokerState.plasma[name] or 0
    if row > H then break end
    local short = name:gsub(" Plasma", "")
    put(string.format("  %-16s %8d mB", short, amt), amt > 0 and 0xFF00FF or 0x555555)
    if amt > 0 then anyPlasma = true end
  end
  -- TELEMETRY STATUS, in the two rows under the plasma list.
  --
  -- These rows are the exception to this panel's clear-as-you-write habit: the
  -- rest of it writes every row on every frame, while what goes here depends on
  -- state. When it was written conditionally, the frame where plasma first
  -- appeared simply stopped running the branch and whatever it had written was
  -- never wiped -- which is how "[ waiting for fluid telemetry... ]" survived on
  -- screen long after fluid telemetry had gone green. Every branch below writes
  -- both rows, blanking rather than skipping, which settles that.
  --
  -- ALWAYS EXACTLY TWO ROWS, whichever branch runs. The sections below this one
  -- are laid out by a running cursor, so a block that is sometimes one row and
  -- sometimes two shifts everything under it between frames -- which repaints
  -- the whole panel and makes the drone and drill lists jump.
  --
  -- A node fault is checked FIRST, and that ordering is the point of it. When
  -- the fluid node's ME query fails it stops publishing volumes, so every tier
  -- reads zero here -- and "NO PLASMA - MINING BLOCKED" is then a confident
  -- statement of something the broker does not know. It sent people to look at
  -- an empty tank farm that was full. Name the node and the reason instead.
  local faultNode, faultWhy = nodeFault()
  local held = brokerState.nodeRecast["FLUID_UPDATE"] or brokerState.nodeRecast["DUST_UPDATE"]
  if faultNode then
    put("  [ " .. faultNode .. ": " .. faultWhy:sub(1, PW - 14) .. " ]", 0xFF4444)
    put("  [ DISPATCH HELD until telemetry is trustworthy ]", 0xFF4444)
  elseif not anyPlasma then
    if brokerState.lastFluidSyncTime == 0 then
      put("  [ waiting for fluid telemetry... ]", 0xFFAA00)
    else
      put("  [ NO PLASMA - MINING BLOCKED ]", 0xFF4444)
    end
    put("", 0x555555)
  elseif held then
    -- Not a fault: a node hit a bad scan and is republishing its last good
    -- figures while it recovers. Worth saying, because the numbers above are
    -- older than the sync clock suggests -- but dispatch carries on.
    put("  [ telemetry held over " .. held .. " scan(s) - node coping ]", 0xFFAA00)
    put("", 0x555555)
  else
    put("", 0x555555)
    put("", 0x555555)
  end
  skip(1)

  -- STOCK AND FREE ARE DIFFERENT NUMBERS, AND THIS PANEL USED TO SHOW ONLY ONE.
  --
  -- Stock is what the ME held at the last hw sweep, which is up to a scan
  -- interval old and never subtracts a thing. Free is what dispatch can actually
  -- hand out. Reading the first as the second is what made a busy UHV look like
  -- an idle one -- the drone was already in a module and the figure had simply
  -- not caught up.
  --
  -- Both are shown, and only when they disagree, so the ordinary case stays a
  -- single number. `x0 (1 free)` is a drone held by a finished module under
  -- fastReload: the ME cannot see it, the pool can, and that gap is worth
  -- saying out loud rather than hiding.
  local freeDrones = POOL.freeDrones()
  put("  DRONES IN STOCK:", 0x888888)
  local any = false
  for _, key in ipairs(config.droneKeyOrder) do
    local count = brokerState.drones[key] or 0
    local free  = freeDrones[key] or 0
    if count > 0 or free > 0 then
      if row > H then break end
      local droneName = config.drones[key] or ("Drone-" .. key)
      local lvl = droneName:match("MK%-(.+)") or "?"
      local line = string.format("  %-18s  x%d", "MK-" .. lvl, count)
      if free ~= count then line = line .. string.format("  (%d free)", free) end
      -- Amber when nothing is free: the tier is owned but cannot be dispatched,
      -- which is a different state from not owning one at all.
      put(line, (free > 0) and 0x00FFFF or 0xFFAA00)
      any = true
    end
  end
  if not any then put("  [ NO DRONES IN STOCK ]", 0xFF4444) end

  skip(1)

  -- Drill kits (a "kit" = one drill tip + one rod of the same material).
  local freeKits = POOL.freeKits()
  put("  DRILL KITS IN STOCK:", 0x888888)
  local anyDrill = false
  for _, key in ipairs(drillKeyOrder) do
    local d = brokerState.drills[key]
    local kits = (d and d.kits) or 0
    local free = freeKits[key] or 0
    if kits > 0 or free > 0 then
      if row > H then break end
      -- Display the material name, stripped of " Drill Tip".
      local entry = config.drills[key]
      local name = (entry and entry.tip and entry.tip:gsub(" Drill Tip", "")) or key
      local line = string.format("  %-18s  x%d", name, kits)
      if free ~= kits then line = line .. string.format("  (%d free)", free) end
      put(line, 0x00AAFF)
      anyDrill = true
    end
  end
  if not anyDrill then put("  [ NO DRILL KITS IN STOCK ]", 0xFF4444) end

  -- Restock: what the hw node has on order against config.drillPar.
  --
  -- This is the only place a per-material shortage becomes visible. The block
  -- above lists kits > 0, so a single material sitting under the 64-kit
  -- dispatch floor used to render as an ordinary blue count -- or vanish
  -- entirely at zero -- while its whole drone tier quietly stopped dispatching.
  local restock = restockSorted()
  if #restock > 0 then
    skip(1)
    put("  RESTOCK:", 0x888888)
    for _, label in ipairs(restock) do
      if row > H then break end
      local o     = brokerState.crafting[label]
      local state = (type(o) == "table" and o.state) or "?"
      local want  = (type(o) == "table" and o.want) or 0
      -- "Naquadah Alloy Drill Tip" -> "Naquadah Alloy TIP": the material is what
      -- distinguishes these, and it is the part that gets truncated away.
      local short = label:gsub(" Drill Tip$", " TIP"):gsub(" Rod$", " ROD")
      if state == "crafting" then
        put(string.format("  %-24s x%d", short:sub(1, 24), want), 0xFFAA00)
      elseif state == "queued" then
        -- Not a problem: below par, waiting on a crafting CPU. Dim so it reads
        -- as backlog rather than as another thing demanding attention.
        put(string.format("  %-24s queued x%d", short:sub(1, 24), want), 0x555555)
      else
        put(string.format("  %-24s %s", short:sub(1, 24),
          state == "nopattern" and "NO PATTERN" or "REJECTED"), 0xFF4444)
      end
    end
  end

  for r = row, H do dashBlank("H" .. r, P3 + 1, PW, r) end
end

local function drawStaticFrame()
  if not gpu then return end
  -- The frame is about to overwrite everything, so the row cache is now a lie
  -- about what is physically on screen. This is also the editor's exit path
  -- (edAction("close") calls it), which is what keeps the dashboard from
  -- skipping rows that still hold editor content.
  dashInvalidate()
  term.clear()
  gpu.setForeground(0x00FF00)
  gpu.fill(1, 1, W, 1, "="); gpu.fill(1, 5, W, 1, "=")
  term.setCursor(2, 2); gpu.setForeground(0xFFFFFF); io.write("MEDINA BROKER MK3  (v1.5)")
  term.setCursor(P1 + 1, 4); io.write("MODULES")
  term.setCursor(P2 + 1, 4); io.write("DUST STOCK")
  term.setCursor(P3 + 1, 4); io.write("HARDWARE")
  gpu.setForeground(0x555555)
  for y = 6, H do
    term.setCursor(P1, y); io.write("|")
    term.setCursor(P2, y); io.write("|")
  end
end

local function drawUI()
  if not gpu then return end
  -- Cached like every other row: the clock only changes once a second, and the
  -- dashboard repaints four times a second.
  dashRow("SYNC", W - 17, 17, 2,
    "SYNC: " .. os.date("%H:%M:%S", math.floor(getUnixTime())), 0x555555)
  drawModulePanel(); drawDustPanel(); drawHWPanel()
end

-- Boot-time prompt: how should the broker prioritize what to mine?
-- Runs once at startup, before the dashboard takes over the screen.
local function promptChoice(label, opts, default)
  print(label)
  for i, o in ipairs(opts) do print(string.format("  [%d]  %s", i, o)) end
  io.write("  Choice [1-" .. #opts .. "] (default " .. default .. "): ")
  local n = tonumber(io.read())
  if not n or n < 1 or n > #opts then n = default or 1 end
  return n
end

local function runBootPrompt()
  if gpu then
    term.clear(); term.setCursor(1, 1)
    gpu.setForeground(0x00FF00)
  end
  print("================================================================================")
  print("  MEDINA BROKER MK3 - STARTUP CONFIGURATION")
  print("================================================================================")
  if gpu then gpu.setForeground(0xFFFFFF) end

  local pr = promptChoice("\nSelect priority mode:", {
    "Threshold ratio  - mine the item with the LOWEST stock/target ratio first",
    "Rarity first     - mine highest dust-priority ores first, then by ratio",
  }, 1)
  brokerState.priorityMode = (pr == 2) and "rarity" or "threshold"

  logger:info("[STARTUP] priority mode = " .. brokerState.priorityMode)
  if gpu then gpu.setForeground(0x00FF00) end
  print("\n  Priority: " .. brokerState.priorityMode:upper() .. ".  Starting broker...")
  if gpu then gpu.setForeground(0xFFFFFF) end
  os.sleep(1)
end

-- Disable and clear every module's interface, and settle which GTNH parameter
-- API each one speaks. Shows live progress in the MODULES panel so boot feels
-- responsive instead of staring at a blank console while ~24 component calls
-- run. Cheap work; this is purely about feedback.
--
-- The dialect is resolved HERE, once, rather than at every start: it is a
-- property of the pack the world is running, it cannot change while the broker
-- is up, and probing it per job would put two speculative component calls in
-- front of every dispatch.
local function initModules()
  logger:info("[STARTUP] Initializing " .. #modules .. " modules...")
  local anyLegacy = false
  for i, mod in ipairs(modules) do
    if gpu then
      local row = 5 + i
      gpu.fill(P1 + 1, row, PW, 1, " ")
      term.setCursor(P1 + 1, row)
      gpu.setForeground(0xFFFF00)
      io.write(string.format("  M%d [%-5s]  clearing...", mod.index, mod.tier))
    end

    mod.dialect, mod.dialectHow = moduleApi.resolve(mod.adapter, config.gtVersion)
    if mod.dialect then
      if mod.dialect == moduleApi.V28 then anyLegacy = true end
      logger:info(string.format("[STARTUP] M%d speaks %s", mod.index, moduleApi.describe(mod)))
    else
      -- Neither setParameter nor setParameters. That is not a mining module, or
      -- moduleAddr points at the wrong block. Fail the module, not the boot: the
      -- other five are probably fine and the dashboard is where you find out.
      mod.status = "ERROR"
      mod.lastError = "module API not recognised (no setParameter or setParameters)"
      logger:error("[STARTUP] M" .. mod.index .. " " .. mod.lastError)
    end

    pcall(function()
      mod.adapter.setWorkAllowed(false)
      -- At boot we have no idea what a previous run left configured, so this
      -- deliberately clears the full MAX_CFG_SLOTS -- mod.cfgHigh is unset,
      -- which is exactly the "clear everything" case.
      clearInterfaceSlots(mod)
    end)
  end

  -- Said once for the whole array, not once per module: on a 2.8 world every
  -- module is in the same boat, and six identical warnings is how a real one
  -- gets scrolled past.
  if anyLegacy then
    local line = "GTNH 2.8: parallel and cycle are not settable from code -- set them " ..
                 "in each module's GUI. Dispatch assumes maxParallels for the tier, so " ..
                 "computation and ETA figures are wrong if the GUI holds less."
    logger:warn("[STARTUP] " .. line)
    print(line)
  end
end

-- =============================================================================
-- MAIN LOOP
-- =============================================================================

runBootPrompt()   -- ask priority mode (runs while you're at the console)
logger:info("Waiting for telemetry...")
drawStaticFrame() -- frame appears immediately
initModules()     -- then clear modules with visible progress

if modem.isOpen(config.ports.telemetry) then
  logger:info("Modem open on port " .. config.ports.telemetry)
else
  logger:error("Modem NOT open on port " .. config.ports.telemetry)
end

-- Each part of the loop runs at the cadence it actually needs, so the heavy GPU
-- redraw doesn't throttle the time-sensitive scheduler:
--   - scheduler + module lifecycle: every iteration (loads are time-sensitive)
--   - messages: serviced with a tiny event.pull timeout so we spin fast
--   - UI redraw: ~4x/second (humans don't need more; GPU calls are expensive)
--   - dispatch: every config.dispatchInterval
-- =============================================================================
-- CONDITION EDITOR  (press E on the dashboard)
--
-- Asteroid-first. Pick an asteroid, see what it yields, choose what to stock.
--
-- WHY IT IS SHAPED THIS WAY:
--   config.conditions says WHAT to maintain. config.dustTargets says WHICH
--   asteroid yields it. An entry only ever dispatches if both exist and the
--   item label matches the ME label exactly; otherwise it fails silently as a
--   permanent 0%, which reads as "we have none of this, mine it urgently".
--
--   config.asteroidOutputs holds each asteroid's DIRECT yield, extracted from
--   the installed jar, so those are exact. Everything downstream of ore
--   processing -- Invar, Graphene, Cerium, the rare-earth line -- lives in
--   thousands of runtime recipe registrations and cannot be derived here. So
--   downstream items are TYPED IN by hand. That is not a shortcut; it is the
--   only correct option, and the editor's job is to make it quick and to keep
--   the two config tables consistent with each other.
--
-- SEMANTICS:
--   dustTargets is a MAPPING (where an item comes from). Toggling something off
--   never deletes it -- "Invar comes from the Nickel asteroid" stays true
--   whether or not you currently want Invar. Turning something ON writes the
--   mapping if it is missing, because at that point the asteroid is known.
--   conditions is the PREFERENCE (what to actually stock).
--
-- RUNS AS A UI MODE, NOT A MODAL DIALOG:
--   The main loop keeps calling sched.tick() and stepModules() the whole time
--   this is open, so loads in flight keep progressing. That rules out
--   term.read(): a blocking prompt could stall a load past ARRIVE_TIMEOUT and
--   fail it. All text entry is incremental instead -- every keystroke arrives
--   as an ordinary event through the same loop.
--
-- FOUR PAGES, NOT ONE:
--   asteroids/detail/items   what to mine and how much of it to keep.
--   drills                   the consumables that make mining possible at all --
--                            how many tips and rods go into a module, and what
--                            stock level triggers a craft. Same reason it lives
--                            here: those numbers used to mean closing the broker
--                            and editing Lua, and they are exactly the numbers
--                            you want to move while watching a module stall.
--   settings                 every other tunable in the system, built from the
--                            declarations in settings.lua. Booleans flip in
--                            place, choices cycle, numbers are typed and checked
--                            against their own bounds. Nothing on this page is
--                            named in this file, so declaring a knob over there
--                            is the entire job of adding one here.
--
-- The point of the last two is that there is now no reason to leave the program.
-- Every value that used to mean stopping the broker, editing Lua and restarting
-- is reachable from here, applies live on save, and is written to a file updates
-- never overwrite.
--
-- KEYS: up/down/pgup/pgdn/home/end move   enter drill in / commit
--       space toggle or cycle   t type a value   T step the ladder
--       r reset to shipped      a add downstream item   c changed only
--       i items   d drills   g settings   / filter   s save
--       TAB cancel a prompt, or go back -- and q or backspace in a list
--
-- NOT escape. Minecraft closes the screen GUI on escape, so the keypress never
-- reaches this program; the editor advertised it for a long time regardless.
-- The bindings are declared once in EDKEYS and the on-screen legend is built
-- from that table, so this class of drift cannot recur silently.
--
-- Closing with unsaved edits is refused once and says how many; a second CLOSE
-- discards them. Nothing here is applied or written until you press s.
-- =============================================================================

local USER_CONFIG_PATH   = "/home/user_config.lua"
local QUOTE              = string.char(34)
local TARGET_LADDER      = { 1000000, 2000000, 5000000, 10000000, 25000000, 50000000, 100000000 }
local DEFAULT_TARGET     = 5000000

local edRequestWatchlist = false   -- set on save; main loop re-broadcasts
local edRequestPar       = false   -- ditto, for DRILL_PAR
local edRequestNodes     = false   -- ditto, for NODE_SETTINGS

-- THE DRILL PAGE, IN ONE TABLE.
--
-- Everything else in this file is a plain top-level local, and this would be
-- too if there were room: the main chunk sits within a handful of Lua's
-- 200-local limit, and a dozen more would not fit. Namespacing one feature is
-- the cheap way out, and it happens to read well -- every drill-page constant
-- and helper is reachable from one name.
local DRILL = {}

-- The load-buffer settings shown on the drills page. They are ordinary entries
-- in the settings registry, named here only to say WHICH ones belong beside the
-- par table -- because that is where you are standing when you want to move
-- them. Editing one here and editing it on the settings page are the same edit
-- against the same working copy.
DRILL.fields = {
  "tipsPerLoad", "rodsPerLoad", "tipsToStart", "rodsToStart", "drillCraftSlots",
}

-- THE SETTINGS PAGE, IN ONE TABLE -- same reason DRILL is one table: the main
-- chunk is close enough to Lua's 200-local limit that a dozen more top-level
-- locals would not fit.
--
-- The page is BUILT FROM THE REGISTRY, not written out here. Declaring a knob
-- in settings.lua is the whole job: it appears in its group, with its help
-- line, editable in the way its type implies, validated against its own bounds,
-- and saved to user_config.lua. Nothing in this file names it.
local SET = { spec = config.settingsSpec }

-- Fallback for a material with no shipped par at all (the top three tiers ship
-- with one, but a hand-trimmed config.lua may not). Deliberately small: turning
-- a material on should not commit the base to an expensive unattended craft.
DRILL.fallback = { tips = 256, rods = 256, batch = 256 }

-- ---------------------------------------------------------------------------
-- KEYS THAT ACTUALLY REACH US
--
-- Escape does not, and that is the whole reason this section exists. In
-- Minecraft, pressing Escape closes the screen GUI itself: the client eats the
-- keypress and no key_down event is ever delivered to the program. Every
-- `code == 1` branch in this editor was unreachable, and three legend strings
-- advertised it -- so the only way out of a text prompt was to commit a value.
--
-- TAB is the universal cancel now, because it is the one key that works in a
-- text field too: q is something you might legitimately type, and backspace
-- already means delete-a-character. In list mode q and backspace also go back,
-- since both are free there and closer to the hand.
--
-- Escape stays bound below as an alias. It costs one table entry, and it is
-- what everyone tries first.
-- ---------------------------------------------------------------------------
-- One table, not eleven locals: the main chunk is near Lua's 200-local ceiling
-- and this file is the reason. Scancodes as OpenComputers delivers them in
-- ev[4] of a key_down.
local K = {
  ESC = 1, BACKSPACE = 14, TAB = 15, ENTER = 28, DELETE = 211,
  UP = 200, DOWN = 208, PGUP = 201, PGDN = 209, HOME = 199, END_ = 207,
}

local ed = {
  open = false,
  mode = "asteroids",          -- asteroids | detail | items | drills | settings
  asteroid = nil,              -- selected asteroid while in detail mode
  rows = {},                   -- row model for the current mode
  sel = 1, scroll = 0,
  filter = nil, filtering = false,
  changedOnly = false,         -- settings page: show only knobs that differ from shipped
  input = nil,                 -- { label, buffer, onCommit }
  enabled = {}, threshold = {},-- working copy of config.conditions
  targets = {},                -- working copy of config.dustTargets
  par = {},                    -- working copy of config.drillPar (nil = not ordered)
  settings = {},               -- working copy of config.settings (every knob)
  added = {},                  -- items newly mapped this session
  msg = "", msgColor = 0x888888,
  dirty = true,                -- REPAINT flag. Unsaved edits are edDirtyCount().
  closeArmed = false,          -- a CLOSE was refused for unsaved changes; a second one discards
}

local function edSay(m, c) ed.msg = m; ed.msgColor = c or 0x888888 end

-- ---------------------------------------------------------------------------
-- BINDINGS, DECLARED ONCE
--
-- edHandle dispatches from this table and the legend at the top of the editor
-- is BUILT from it, so a binding cannot exist without being advertised, or be
-- advertised without existing. That is not tidiness for its own sake: the key
-- dispatch used to be an if/elseif ladder of raw scancodes and the legend three
-- hand-written strings, they drifted, and the UI ended up telling everyone to
-- press a key the game never delivers.
--
--   char / code  one or the other. `char` is the printable character (ev[3]),
--                `code` the scancode (ev[4]), matching what edHandle receives.
--   action       must be a case edAction handles. The test asserts this.
--   hint         how it appears in the legend. Omit to bind without listing --
--                that is what the cancel aliases do.
--   modes        space-separated pages, or "*" for every page.
--
-- Navigation (arrows, page up/down, home/end, enter) is deliberately NOT here.
-- Those are not actions, they have nothing to advertise, and they stay in the
-- ladder in edHandle.
-- ---------------------------------------------------------------------------
local EDKEYS = {
  { char = 32,  action = "activate", hint = "space=toggle",       modes = "asteroids detail items" },
  { char = 32,  action = "activate", hint = "space=on/off",       modes = "drills" },
  { char = 32,  action = "activate", hint = "space=toggle/cycle", modes = "settings" },
  { char = 116, action = "type",     hint = "t=type amount",      modes = "asteroids detail items" },
  { char = 116, action = "type",     hint = "t=edit",             modes = "drills" },
  { char = 116, action = "type",     hint = "t=type",             modes = "settings" },
  { char = 84,  action = "step",     hint = "T=step",             modes = "asteroids detail items" },
  { char = 97,  action = "add",      hint = "a=add",              modes = "detail" },
  { char = 114, action = "reset",    hint = "r=reset",            modes = "settings" },
  { char = 82,  action = "reset" },
  { char = 99,  action = "changed",  hint = "c=changed only",     modes = "settings" },
  { char = 105, action = "items",    hint = "i=items",            modes = "asteroids detail" },
  { char = 100, action = "drills",   hint = "d=drills",           modes = "asteroids detail items" },
  { char = 103, action = "settings", hint = "g=settings",         modes = "drills" },
  { char = 47,  action = "find",     hint = "/=find",             modes = "*" },
  { char = 115, action = "save",     hint = "s=save",             modes = "*" },
  -- Cancel. Tab is the one that is listed; the rest are aliases people try.
  { code = K.TAB,       action = "back", hint = "tab=back", modes = "*" },
  { code = K.BACKSPACE, action = "back" },
  { code = K.ESC,       action = "back" },
  { char = 113,         action = "back" },   -- q
  { char = 81,          action = "back" },   -- Q
}

local function edBindingFor(ch, code)
  for _, b in ipairs(EDKEYS) do
    if (b.char and ch == b.char) or (b.code and code == b.code) then
      if b.modes == nil or b.modes == "*" or b.modes:find(ed.mode, 1, true) then
        return b
      end
    end
  end
  return nil
end

-- The legend, assembled from the same table the dispatch reads.
local function edLegend()
  local parts = {}
  for _, b in ipairs(EDKEYS) do
    if b.hint and (b.modes == "*" or (b.modes and b.modes:find(ed.mode, 1, true))) then
      parts[#parts + 1] = b.hint
    end
  end
  return table.concat(parts, "  ")
end

local function edRows()  return H - 6 end   -- rows 5 .. H-2 hold the list
local function edFirst() return 5 end

-- ---------------------------------------------------------------------------
-- MODEL
-- ---------------------------------------------------------------------------

local function edLoad()
  ed.enabled, ed.threshold, ed.targets, ed.added = {}, {}, {}, {}
  for _, cond in ipairs(config.conditions) do
    ed.enabled[cond.itemName]   = true
    ed.threshold[cond.itemName] = cond.amountToMaintain
  end
  for item, t in pairs(config.dustTargets) do
    ed.targets[item] = { asteroid = t.asteroid, priority = t.priority or 99 }
  end

  -- A material ABSENT from config.drillPar is not an error, it is the "never
  -- order this" state -- so absence is carried through as nil rather than
  -- filled in with a default, and the page draws it unchecked.
  ed.par = {}
  for key, p in pairs(config.drillPar or {}) do
    if type(p) == "table" then
      ed.par[key] = { tips = p.tips or 0, rods = p.rods or 0,
                      batch = p.batch or p.tips or 0 }
    end
  end

  -- The whole registry, in stored form. One working copy behind both the
  -- settings page and the drills page, so the same knob cannot hold two
  -- different pending values depending on where you looked at it.
  ed.settings = {}
  for key, value in pairs(config.settings) do ed.settings[key] = value end
end

-- ---------------------------------------------------------------------------
-- HOW MUCH WOULD CLOSING THROW AWAY?
--
-- Every edit in this editor lands in a working copy above and NOWHERE ELSE
-- until edSave runs -- edSave is what writes user_config.lua and what applies
-- the values live, in that order. So closing without saving silently discards
-- the session, which is what this exists to stop.
--
-- Compared against `config` rather than against a snapshot taken at open,
-- because config IS the last-saved state: edSave updates it in the same pass
-- that writes the file. That also means a save mid-session correctly drops the
-- count back to zero without anything having to reset a baseline.
--
-- Counts entries, not keystrokes: flipping a setting and flipping it back is
-- zero changes, which is the honest answer to "would I lose anything".
-- ---------------------------------------------------------------------------
-- Memoised against edGen, the same way dustList is at the dust panel: this is
-- read on every repaint for the legend, and every mutation in the editor goes
-- through edTouch or edRebuild (which calls it), so a stale answer is not
-- reachable. edGen also ticks for reasons outside the editor, which costs a
-- recount and never correctness.
local edDirtyGen, edDirtyCached = -1, 0

local function edDirtyCount()
  if edDirtyGen == edGen then return edDirtyCached end
  local n = 0

  -- Conditions: the tracked set and each threshold. Walk both directions so a
  -- removal counts as loudly as an addition.
  local liveCond = {}
  for _, cond in ipairs(config.conditions) do
    liveCond[cond.itemName] = cond.amountToMaintain
  end
  for item in pairs(ed.enabled) do
    if liveCond[item] == nil then n = n + 1
    elseif (ed.threshold[item] or DEFAULT_TARGET) ~= liveCond[item] then n = n + 1 end
  end
  for item in pairs(liveCond) do
    if not ed.enabled[item] then n = n + 1 end
  end

  -- Dust mappings: asteroid or priority moved.
  for item, t in pairs(ed.targets) do
    local live = config.dustTargets[item]
    if not live or live.asteroid ~= t.asteroid or (live.priority or 99) ~= t.priority then
      n = n + 1
    end
  end

  -- Drill par. Absence is a real state here ("never order this"), so a material
  -- present on one side and nil on the other is a change.
  local livePar = config.drillPar or {}
  for key, p in pairs(ed.par) do
    local live = livePar[key]
    if type(live) ~= "table" then n = n + 1
    elseif live.tips ~= p.tips or live.rods ~= p.rods
        or (live.batch or live.tips) ~= p.batch then n = n + 1 end
  end
  for key, live in pairs(livePar) do
    if type(live) == "table" and not ed.par[key] then n = n + 1 end
  end

  -- Settings, in stored form on both sides -- config.settings is the raw table
  -- the overlay and the editor share, not the applied runtime values.
  for key, value in pairs(ed.settings) do
    if config.settings[key] ~= value then n = n + 1 end
  end

  edDirtyGen, edDirtyCached = edGen, n
  return n
end

-- "naquadahAlloy" -> "Naquadah Alloy". The tip label is the only place the
-- printable name exists; the key is camelCase and config.drills has no name
-- field of its own.
function DRILL.name(key)
  local d = config.drills[key]
  if d and d.tip then return (d.tip:gsub(" Drill Tip$", "")) end
  return key
end

-- The kit floor tryDispatch() actually enforces. Derived, never stored, so the
-- page shows it rather than letting you discover it as a module that refuses to
-- go out with plenty of kits on the shelf.
function DRILL.floor()
  return math.max(ed.settings.tipsPerLoad or 64, ed.settings.rodsPerLoad or 64)
end

local function outputsFor(name)
  return (config.asteroidOutputs or {})[name]
end

-- Items mapped to this asteroid that are NOT one of its direct yields.
-- Items already covered by the asteroid's derived main/processed lists.
local function derivedFor(name)
  local o = outputsFor(name)
  local set = {}
  if not o then return set end
  for _, e in ipairs(o.main or {})      do set[e.item] = true end
  for _, e in ipairs(o.processed or {}) do set[e.item] = true end
  return set
end

-- dustTargets entries pointing at this asteroid that the dump did NOT derive.
-- These are the hand-typed ones: alloys, chemical lines, anything past the
-- ore-processing graph the mod walks.
local function manualFor(name)
  local derived = derivedFor(name)
  local list = {}
  for item, t in pairs(ed.targets) do
    if t.asteroid == name and not derived[item] then list[#list + 1] = item end
  end
  table.sort(list)
  return list
end

local function trackedCount(name)
  local n = 0
  for item, t in pairs(ed.targets) do
    if t.asteroid == name and ed.enabled[item] then n = n + 1 end
  end
  return n
end

local function nextPriority(name)
  local p = 0
  for _, t in pairs(ed.targets) do
    if t.asteroid == name and t.priority and t.priority < 90 and t.priority > p then
      p = t.priority
    end
  end
  return p + 1
end

local function matchesFilter(s)
  if not ed.filter or ed.filter == "" then return true end
  return s:lower():find(ed.filter, 1, true) ~= nil
end

local function buildAsteroids()
  local rows = {}
  local names = {}
  for name in pairs(config.asteroids) do names[#names + 1] = name end
  table.sort(names)
  for _, name in ipairs(names) do
    if matchesFilter(name) then
      local a = config.asteroids[name]
      rows[#rows + 1] = {
        kind = "asteroid", name = name,
        tier = a.minModule or 1,
        drones = string.format("%d-%d", a.minDrone or 0, a.maxDrone or 0),
        tracked = trackedCount(name),
        direct = outputsFor(name) ~= nil,
      }
    end
  end
  return rows
end

-- Three sections, as the data itself divides:
--   MAIN       processing the drop -- macerator, washer, thermal centrifuge,
--              sifter, chemical bath, EM separator. hops=0 means the module
--              drops it finished.
--   PROCESSED  breaking those down further in a centrifuge or electrolyzer.
--   MANUAL     typed in by hand. Everything past the ore-processing graph --
--              alloys, chemical lines -- which no dump can reach.
local function buildDetail(name)
  local rows = {}
  local o = outputsFor(name)

  -- The raw drops are context, not choices: they are ore, processing eats them
  -- on arrival, and their stock never accumulates. Shown for the item filter.
  if o and o.drops then
    local parts = {}
    for _, dr in ipairs(o.drops) do
      parts[#parts + 1] = string.format("%s (%.0f%%)", dr.item, (dr.chance or 0) / 100)
    end
    rows[#rows + 1] = { kind = "header", text = "DROPS  (for the module item filter -- do not track)" }
    rows[#rows + 1] = { kind = "note", text = table.concat(parts, "   ") }
  end

  rows[#rows + 1] = { kind = "header",
    text = o and "MAIN  (from macerating / washing / centrifuging the drop)"
             or  "MAIN  -- nothing derived for this asteroid" }
  if o then
    for _, e in ipairs(o.main or {}) do
      if matchesFilter(e.item) then
        rows[#rows + 1] = { kind = "item", item = e.item, source = e.via, direct = true }
      end
    end
    if #(o.main or {}) == 0 then
      rows[#rows + 1] = { kind = "note", text = "none" }
    end
  end

  rows[#rows + 1] = { kind = "header", text = "PROCESSED  (electrolyzing / centrifuging the above)" }
  if o and #(o.processed or {}) > 0 then
    for _, e in ipairs(o.processed) do
      if matchesFilter(e.item) then
        rows[#rows + 1] = { kind = "item", item = e.item, source = e.via, direct = true }
      end
    end
  else
    rows[#rows + 1] = { kind = "note", text = "none" }
  end

  rows[#rows + 1] = { kind = "header", text = "MANUAL  (typed in -- alloys, chemical lines)" }
  local man = manualFor(name)
  if #man == 0 then
    rows[#rows + 1] = { kind = "note", text = "none yet -- press A to add one" }
  end
  for _, item in ipairs(man) do
    if matchesFilter(item) then
      rows[#rows + 1] = { kind = "item", item = item, direct = false }
    end
  end
  return rows
end

local function buildItems()
  local seen, list = {}, {}
  for item in pairs(ed.targets)  do if not seen[item] then seen[item] = true; list[#list+1] = item end end
  for item in pairs(ed.enabled)  do if not seen[item] then seen[item] = true; list[#list+1] = item end end
  table.sort(list)
  local rows = {}
  for _, item in ipairs(list) do
    if matchesFilter(item) then
      local t = ed.targets[item]
      rows[#rows + 1] = { kind = "item", item = item, direct = false,
                          asteroid = t and t.asteroid or nil, showAsteroid = true }
    end
  end
  return rows
end

-- DRILL CONSUMABLES PAGE
--
-- Two sections, because they answer two different questions and get tuned at
-- different times:
--
--   LOAD BUFFER   how much a module is given, and how little it will settle for
--                 before starting. Tuned when loads feel slow or modules stall
--                 mid-run.
--   RESTOCK PAR   when the hw node auto-crafts more, and how many it asks for.
--                 Tuned when a material keeps running dry, or when an expensive
--                 tier is crafting more eagerly than you want.
--
-- The two are coupled through the dispatch floor, which is why that derived
-- number is spelled out between them rather than left to be rediscovered.
function DRILL.build()
  local rows = {}

  rows[#rows + 1] = { kind = "header",
    text = "LOAD BUFFER  (what a module load puts in the input bus)" }
  for _, key in ipairs(DRILL.fields) do
    local spec = SET.spec.byKey[key]
    if spec and (matchesFilter(spec.label) or matchesFilter(key)) then
      rows[#rows + 1] = { kind = "opt", spec = spec }
    end
  end

  local usable = usableDrillKeys()
  local floor  = DRILL.floor()
  rows[#rows + 1] = { kind = "note", text = string.format(
    "a module will not be dispatched unless %d kits of its material are in stock" ..
    "  (the larger of the two per-load figures)", floor) }

  rows[#rows + 1] = { kind = "header",
    text = "RESTOCK PAR  (fall below the floor and a whole batch is crafted)" }

  -- The master switch sits at the top of the section it governs, not away on
  -- the settings page. Someone looking at a par table that is not ordering is
  -- standing right here, and "is this even switched on" should be answerable
  -- without leaving the page.
  local restockOn = ed.settings.drillRestock ~= false
  local switch = SET.spec.byKey["drillRestock"]
  if switch then
    rows[#rows + 1] = { kind = "opt", spec = switch }
  end
  if not restockOn then
    rows[#rows + 1] = { kind = "note", text =
      "auto-crafting is OFF -- the figures below are kept but nothing is ordered" }
  end

  for _, key in ipairs(drillKeyOrder) do
    local name = DRILL.name(key)
    if matchesFilter(name) then
      -- `usable` stays truthful (do we own a drone for it) and `restockOn` is
      -- carried separately, so the row can name the ACTUAL reason it is not
      -- being published. Folding the two together made every row claim "no
      -- drone" the moment auto-crafting was switched off.
      rows[#rows + 1] = { kind = "par", key = key, name = name,
                          usable = usable[key], restockOn = restockOn }
    end
  end

  return rows
end

local function edRebuild()
  edTouch()
  if ed.mode == "asteroids" then
    ed.rows = buildAsteroids()
  elseif ed.mode == "detail" then
    ed.rows = buildDetail(ed.asteroid)
  elseif ed.mode == "drills" then
    ed.rows = DRILL.build()
  elseif ed.mode == "settings" then
    ed.rows = SET.build()
  else
    ed.rows = buildItems()
  end
  if ed.sel > #ed.rows then ed.sel = #ed.rows end
  if ed.sel < 1 then ed.sel = 1 end
  local maxScroll = math.max(0, #ed.rows - edRows())
  if ed.scroll > maxScroll then ed.scroll = maxScroll end
  if ed.scroll < 0 then ed.scroll = 0 end
end

local function edFollow()
  if ed.sel < ed.scroll + 1 then ed.scroll = ed.sel - 1 end
  if ed.sel > ed.scroll + edRows() then ed.scroll = ed.sel - edRows() end
  if ed.scroll < 0 then ed.scroll = 0 end
end

-- Headers and notes are not selectable; step over them.
local function edMoveSel(delta)
  local n = #ed.rows
  if n == 0 then return end
  local i = ed.sel
  for _ = 1, n do
    i = i + delta
    if i < 1 then i = 1 break end
    if i > n then i = n break end
    local k = ed.rows[i] and ed.rows[i].kind
    if k ~= "header" and k ~= "note" then break end
  end
  ed.sel = i
  edFollow()
end

local function selectedRow()
  local r = ed.rows[ed.sel]
  if r and (r.kind == "header" or r.kind == "note") then return nil end
  return r
end

-- Entry point used by the main loop when E is pressed.
local function edBuild()
  edLoad()
  ed.mode, ed.asteroid = "asteroids", nil
  ed.sel, ed.scroll, ed.filter, ed.filtering, ed.input = 1, 0, nil, false, nil
  edRebuild()
end

-- ---------------------------------------------------------------------------
-- MUTATIONS
-- ---------------------------------------------------------------------------

local function edToggle(item, asteroid)
  edTouch()
  if ed.enabled[item] then
    ed.enabled[item] = nil
    edSay("stopped tracking " .. item)
    return
  end
  ed.enabled[item]   = true
  ed.threshold[item] = ed.threshold[item] or DEFAULT_TARGET
  -- Turning something on is the moment the mapping has to exist, and here the
  -- asteroid is known, so write it rather than leaving a condition that can
  -- never dispatch.
  if asteroid and not ed.targets[item] then
    ed.targets[item] = { asteroid = asteroid, priority = nextPriority(asteroid) }
    ed.added[item] = true
    edSay("tracking " .. item .. " at " .. formatQty(ed.threshold[item]) ..
          "  (mapped to " .. asteroid .. ")", 0x00FF00)
  elseif not ed.targets[item] then
    edSay("tracking " .. item .. " -- but it has no asteroid, so it cannot mine", 0xFF4444)
  else
    edSay("tracking " .. item .. " at " .. formatQty(ed.threshold[item]), 0x00FF00)
  end
end

local function edCycleTarget(item)
  edTouch()
  local cur = ed.threshold[item] or 0
  local nxt = TARGET_LADDER[1]
  for _, v in ipairs(TARGET_LADDER) do
    if v > cur then nxt = v break end
  end
  ed.threshold[item] = nxt
  ed.enabled[item]   = true
  edSay(item .. " target " .. formatQty(nxt), 0x00FF00)
end

-- Incremental text entry. Never blocks: each keystroke is just another event.
local function edPrompt(label, onCommit, initial)
  ed.input = { label = label, buffer = initial or "", onCommit = onCommit }
end

-- "50m" / "2.5m" / "500k" / "1b" / "250000". g is accepted as a synonym for b,
-- and t for trillion, so muscle memory from either convention works.
local function parseQty(s)
  if not s then return nil end
  local num, suffix = s:lower():gsub("%s", ""):match("^(%d+%.?%d*)([kmgbt]?)$")
  if not num then return nil end
  num = tonumber(num)
  local mult = ({ k = 1e3, m = 1e6, g = 1e9, b = 1e9, t = 1e12 })[suffix] or 1
  return math.floor(num * mult)
end

local function edAddDownstream()
  local asteroid = ed.asteroid
  if not asteroid then return end
  edPrompt("item label yielded by " .. asteroid .. " (exact ME name):", function(name)
    if not name or name == "" then edSay("cancelled") return end
    if ed.targets[name] then
      edSay(name .. " is already mapped to " .. ed.targets[name].asteroid, 0xFFAA00)
      return
    end
    ed.targets[name] = { asteroid = asteroid, priority = nextPriority(asteroid) }
    ed.added[name]   = true
    edPrompt("amount to maintain for " .. name .. " (5m, 500k, 250000):", function(q)
      local n = parseQty(q)
      if not n or n <= 0 then
        ed.threshold[name] = DEFAULT_TARGET
        edSay("bad amount, defaulted " .. name .. " to " .. formatQty(DEFAULT_TARGET), 0xFFAA00)
      else
        ed.threshold[name] = n
        edSay("added " .. name .. " -> " .. asteroid .. " at " .. formatQty(n), 0x00FF00)
      end
      ed.enabled[name] = true
      edRebuild()
    end, "5m")
    edRebuild()
  end)
end

-- ---------------------------------------------------------------------------
-- SAVE
-- ---------------------------------------------------------------------------

local function fmtQtyLiteral(n)
  if n >= 1000000 and n % 1000000 == 0 then return string.format("%dm", n / 1000000) end
  if n >= 1000    and n % 1000    == 0 then return string.format("%dk", n / 1000) end
  return tostring(n)
end

-- Type an amount rather than cycling to it.
--
-- The ladder is fine for a rough choice and useless for a specific one: getting
-- to 37m meant pressing t past every rung and settling for whichever was
-- closest. The current value is pre-filled in the same shorthand it prints in,
-- so editing 50m to 37m is three keystrokes.
--
-- Entry is incremental, like every other prompt here -- the main loop keeps
-- running while you type, so a load in flight is not stalled by a text field.
local function edTypeTarget(item)
  local cur = ed.threshold[item]
  -- The current value goes in the LABEL, not the buffer. Pre-filling the buffer
  -- would mean backspacing it away before typing, which is the opposite of the
  -- point -- you would be editing a field instead of just stating a number.
  edPrompt("keep how much " .. item .. "?" ..
           (cur and ("  (now " .. fmtQtyLiteral(cur) .. ")") or "") ..
           "  e.g. 50m, 2.5m, 500k",
    function(txt)
      if not txt or txt == "" then edSay("unchanged") return end
      local n = parseQty(txt)
      if not n or n <= 0 then
        edSay("did not understand '" .. tostring(txt) .. "' -- unchanged", 0xFF4444)
        return
      end
      edTouch()
      ed.threshold[item] = n
      ed.enabled[item]   = true
      edSay(item .. " -> " .. formatQty(n), 0x00FF00)
      edRebuild()
    end)
end

-- ---------------------------------------------------------------------------
-- DRILL MUTATIONS
-- ---------------------------------------------------------------------------

-- Warnings, not refusals. Every value these complain about is legal and there
-- are reasons to want each of them; what is not acceptable is setting one by
-- accident and finding out days later from a module that will not dispatch.
function DRILL.warn(key)
  local floor = DRILL.floor()
  if key == "tipsToStart" and (ed.settings.tipsToStart or 0) > (ed.settings.tipsPerLoad or 0) then
    edSay("tips to start is above tips per load -- the loader clamps it down", 0xFFAA00)
    return
  end
  if key == "rodsToStart" and (ed.settings.rodsToStart or 0) > (ed.settings.rodsPerLoad or 0) then
    edSay("rods to start is above rods per load -- the loader clamps it down", 0xFFAA00)
    return
  end
  if key == "tipsPerLoad" or key == "rodsPerLoad" then
    -- Raising a per-load figure raises the dispatch floor with it, which can
    -- strand a material that was previously fine.
    local under = {}
    for k, par in pairs(ed.par) do
      if math.min(par.tips or 0, par.rods or 0) < floor then under[#under + 1] = DRILL.name(k) end
    end
    if #under > 0 then
      table.sort(under)
      edSay("dispatch floor is now " .. floor .. " kits -- par is below that for " ..
            table.concat(under, ", "), 0xFFAA00)
    end
  end
end

-- ---------------------------------------------------------------------------
-- SETTINGS: EDIT, TOGGLE, RESET
--
-- Everything here is driven by the declaration, never by the key. A bool flips,
-- a choice cycles, a number is typed and checked against its own bounds -- and
-- the type-specific part of that is exactly three branches, in SET.activate.
-- ---------------------------------------------------------------------------

function SET.shipped(key) return (config.shippedSettings or {})[key] end

function SET.changed(key)
  local shipped = SET.shipped(key)
  return shipped ~= nil and ed.settings[key] ~= shipped
end

-- Type a value. Numbers accept the same k/m suffixes as everything else in the
-- editor; text is taken as typed. Out-of-range input is REFUSED with the bound
-- that rejected it, rather than clamped -- a clamp hides a typo.
function SET.prompt(spec)
  -- A bool has nothing to type. Reaching the prompt for one -- via `t`, which
  -- means "edit this" everywhere else in the editor -- should still do the
  -- obvious thing rather than asking you to spell out "false".
  if spec.type == "bool" then SET.activate(spec) return end

  local cur = ed.settings[spec.key]
  local hint = ""
  if spec.type == "choice" then
    hint = "  [" .. table.concat(spec.choices, " ") .. "]"
  elseif spec.min or spec.max then
    hint = string.format("  [%s..%s]", tostring(spec.min or "-"), tostring(spec.max or "-"))
  end
  edPrompt(spec.label .. "?  (now " .. SET.spec.display(spec, cur) .. ")" .. hint ..
           "  -- " .. spec.help,
    function(txt)
      if not txt or txt == "" then edSay("unchanged") return end
      -- parseQty understands "4k", which is how every other number in this
      -- editor is typed -- but it FLOORS, so a fractional setting like
      -- runPollIdle would silently become an integer if it went through there.
      -- Fractions first for those, suffixes first for the rest, and text
      -- settings never go near it: "4k" is a perfectly good string.
      local candidate = txt
      if spec.type == "number" then
        candidate = tonumber(txt) or parseQty(txt) or txt
      elseif spec.type == "int" then
        candidate = parseQty(txt) or tonumber(txt) or txt
      end
      local value, why = SET.spec.coerce(spec, candidate)
      if value == nil then
        edSay(spec.label .. ": " .. tostring(why) .. " -- unchanged", 0xFF4444)
        return
      end
      SET.commit(spec, value)
    end)
end

function SET.commit(spec, value)
  edTouch()
  ed.settings[spec.key] = value
  edSay(spec.label .. " -> " .. SET.spec.display(spec, value), 0x00FF00)
  DRILL.warn(spec.key)
  edRebuild()
end

-- What space and enter do to a row, decided by the declaration. A bool or a
-- choice moves in place -- no prompt, no typing, which is the whole point of
-- being able to flip a setting from here.
function SET.activate(spec)
  if spec.type == "bool" or spec.type == "choice" then
    SET.commit(spec, SET.spec.cycle(spec, ed.settings[spec.key]))
  else
    SET.prompt(spec)
  end
end

function SET.reset(spec)
  local shipped = SET.shipped(spec.key)
  if shipped == nil then edSay("no shipped default for " .. spec.key, 0xFFAA00) return end
  if ed.settings[spec.key] == shipped then edSay(spec.label .. " is already the default") return end
  SET.commit(spec, shipped)
  edSay(spec.label .. " reset to the shipped default: " ..
        SET.spec.display(spec, shipped), 0x00FF00)
end

-- The page. Groups in declaration order, settings within a group in the order
-- they are declared, so settings.lua reads the way the screen looks.
function SET.build()
  local rows = {}
  for _, group in ipairs(SET.spec.groups) do
    local body = {}
    for _, spec in ipairs(SET.spec.list) do
      if (spec.group or "other") == group.id then
        if spec.type == "note" then
          body[#body + 1] = { kind = "note", text = spec.text }
        elseif (matchesFilter(spec.label) or matchesFilter(spec.key))
           and (not ed.changedOnly or SET.changed(spec.key)) then
          -- changedOnly composes with the / filter rather than replacing it,
          -- so "what did I touch in logging" is one search and one toggle.
          body[#body + 1] = { kind = "opt", spec = spec }
        end
      end
    end
    -- A group whose settings were all filtered out contributes nothing, not an
    -- empty heading. Notes go with them: a note about rows you cannot see is
    -- just clutter.
    local hasOpt = false
    for _, r in ipairs(body) do if r.kind == "opt" then hasOpt = true break end end
    if hasOpt then
      rows[#rows + 1] = { kind = "header", text = group.label }
      for _, r in ipairs(body) do rows[#rows + 1] = r end
    end
  end
  return rows
end

function DRILL.toggle(key)
  edTouch()
  if ed.par[key] then
    ed.par[key] = nil
    edSay(DRILL.name(key) .. " will no longer be auto-crafted", 0xFFAA00)
  else
    -- Restore what this material shipped with rather than inventing a number.
    -- The shipped pars are scaled to what each material costs to make, and that
    -- scaling is the whole reason they are not all the same.
    local sh = (config.shippedDrillPar or {})[key] or DRILL.fallback
    ed.par[key] = { tips = sh.tips or 0, rods = sh.rods or 0,
                    batch = sh.batch or sh.tips or 0 }
    edSay(string.format("%s par %d/%d, batch %d", DRILL.name(key),
      ed.par[key].tips, ed.par[key].rods, ed.par[key].batch), 0x00FF00)
  end
  edRebuild()
end

-- Set one field of one material's par.
--
-- Editing a material that is switched off switches it on: you cannot have meant
-- "set the floor to 4096 and keep not ordering it".
function DRILL.editField(key, field, andThen)
  local par = ed.par[key]
  local cur = par and par[field] or nil
  local what = ({ tips = "drill tip floor", rods = "drill rod floor",
                  batch = "craft batch size" })[field]
  edPrompt(what .. " for " .. DRILL.name(key) .. "?" ..
           (cur and ("  (now " .. cur .. ")") or "") .. "  e.g. 4096, 2k",
    function(txt)
      local n = parseQty(txt or "")
      -- Empty means keep, which is what makes walking all three fields cheap:
      -- enter, enter, type the one you came for.
      if not txt or txt == "" then
        edSay("unchanged")
        if andThen then andThen() end
        return
      end
      if not n or n < 0 then
        edSay("did not understand '" .. tostring(txt) .. "' -- unchanged", 0xFF4444)
        if andThen then andThen() end
        return
      end
      edTouch()
      if not ed.par[key] then
        local sh = (config.shippedDrillPar or {})[key] or DRILL.fallback
        ed.par[key] = { tips = sh.tips or 0, rods = sh.rods or 0,
                        batch = sh.batch or sh.tips or 0 }
      end
      ed.par[key][field] = n
      edSay(DRILL.name(key) .. " " .. what .. " -> " .. n, 0x00FF00)

      local p, floor = ed.par[key], DRILL.floor()
      if (field == "tips" or field == "rods") and n < floor then
        -- The exact stall this feature exists to remove: stock sits at par, so
        -- nothing is ever crafted, and dispatch still refuses the material.
        edSay(string.format("%s: %d is below the %d-kit dispatch floor -- it can " ..
          "sit at par and still never dispatch", DRILL.name(key), n, floor), 0xFF4444)
      elseif p.batch < math.max(p.tips or 0, p.rods or 0) then
        edSay(DRILL.name(key) .. ": batch is smaller than the floor -- restocking " ..
              "will take several crafts", 0xFFAA00)
      end
      edRebuild()
      if andThen then andThen() end
    end)
end

-- Enter on a par row walks all three fields in turn -- chained prompts, the same
-- shape edAddDownstream uses. Each link is still one non-blocking field, so a
-- load in flight keeps progressing between keystrokes, and tab drops out of the
-- chain wherever you are in it.
function DRILL.editAll(key)
  DRILL.editField(key, "tips", function()
    DRILL.editField(key, "rods", function()
      DRILL.editField(key, "batch")
    end)
  end)
end

-- ---------------------------------------------------------------------------
-- SAVE
--
-- Writes ONLY /home/user_config.lua. config.lua is shipped data -- hand-kept
-- tables plus the generated asteroidOutputs block -- and gets regenerated
-- wholesale, so anything written there would be destroyed on the next update.
-- One writer per file: this editor owns user_config.lua and nothing else, and
-- nothing else ever writes it.
--
-- Only mappings that are genuinely yours are persisted, worked out against
-- config.shippedDustTargets, the snapshot config.lua takes before applying the
-- overlay. Writing all of them back would freeze the shipped table and mask
-- every future label correction. The same diff is applied to drillPar and to
-- the load scalars, against their own snapshots, for the same reason.
--
-- Every table the overlay reads has to be emitted here, because the file is
-- rewritten whole. Before the drill page existed this function wrote only
-- conditions and dustTargets, which meant a hand-written drillPar block was
-- destroyed by the next save -- silently, since nothing reads that file back.
-- ---------------------------------------------------------------------------

local function edSave()
  local shipped = config.shippedDustTargets or {}

  local mine = {}
  local mineCount = 0
  for item, t in pairs(ed.targets) do
    local sh = shipped[item]
    if not sh or sh.asteroid ~= t.asteroid or sh.priority ~= t.priority then
      mine[item] = t
      mineCount = mineCount + 1
    end
  end

  local conds = {}
  for item in pairs(ed.enabled) do conds[#conds + 1] = item end
  table.sort(conds)

  local out = {}
  out[#out + 1] = "-- user_config.lua"
  out[#out + 1] = "--"
  out[#out + 1] = "-- Written by the broker condition editor (press E). Safe to hand-edit."
  out[#out + 1] = "-- Nothing else writes this file, and config.lua updates never touch it."
  out[#out + 1] = "--"
  out[#out + 1] = "--   conditions   what to keep in stock. Replaces the shipped list."
  out[#out + 1] = "--   dustTargets  mappings you added or corrected. Merged over the"
  out[#out + 1] = "--                shipped table, so untouched entries still follow"
  out[#out + 1] = "--                config.lua."
  out[#out + 1] = "--   drillPar     restock floors you changed. Merged per material;"
  out[#out + 1] = "--                false means stop auto-crafting that material."
  out[#out + 1] = "--   settings     tunables you changed, validated against settings.lua."
  out[#out + 1] = "--                Anything not listed follows the shipped default."
  out[#out + 1] = ""
  out[#out + 1] = "return {"

  out[#out + 1] = "  conditions = {"
  for _, item in ipairs(conds) do
    local t = ed.targets[item]
    local ast = t and t.asteroid or nil
    out[#out + 1] = string.format("    { itemName = %-38s amountToMaintain = %-10d },%s",
      QUOTE .. item .. QUOTE .. ",", ed.threshold[item] or DEFAULT_TARGET,
      ast and ("   -- " .. ast) or "   -- NO ASTEROID: cannot dispatch")
  end
  out[#out + 1] = "  },"

  out[#out + 1] = "  dustTargets = {"
  local names = {}
  for item in pairs(mine) do names[#names + 1] = item end
  table.sort(names)
  for _, item in ipairs(names) do
    local t = mine[item]
    out[#out + 1] = string.format("    [%s%s%s] = { asteroid = %s%s%s, priority = %d },",
      QUOTE, item, QUOTE, QUOTE, t.asteroid, QUOTE, t.priority or 99)
  end
  out[#out + 1] = "  },"

  -- drillPar: only what differs from the shipped table. A material you switched
  -- OFF that ships ON has to be written as `false` -- omitting it would just let
  -- the shipped default come back on the next boot.
  local shippedPar = config.shippedDrillPar or {}
  local parOut, parCount = {}, 0
  for _, key in ipairs(drillKeyOrder) do
    local sh, cur = shippedPar[key], ed.par[key]
    if cur == nil then
      if sh then parOut[key] = false; parCount = parCount + 1 end
    elseif not sh or sh.tips ~= cur.tips or sh.rods ~= cur.rods or sh.batch ~= cur.batch then
      parOut[key] = cur; parCount = parCount + 1
    end
  end

  out[#out + 1] = "  drillPar = {"
  for _, key in ipairs(drillKeyOrder) do
    local v = parOut[key]
    if v == false then
      out[#out + 1] = string.format("    %-18s = false,   -- do not auto-craft", key)
    elseif v then
      out[#out + 1] = string.format("    %-18s = { tips = %d, rods = %d, batch = %d },",
        key, v.tips or 0, v.rods or 0, v.batch or 0)
    end
  end
  out[#out + 1] = "  },"

  -- Settings: only what differs from the shipped default, for the same reason
  -- as the two tables above. Written in DECLARATION order rather than pairs()
  -- order so the file is stable across saves and a diff of it is readable.
  --
  -- No drillLoad block any more. Its five fields are ordinary settings now, and
  -- writing both would leave two places claiming to hold tipsPerLoad. config.lua
  -- still READS a legacy drillLoad, so an upgrade does not lose tuning -- but
  -- the first save from here rewrites it into `settings` and it never comes back.
  local setCount = 0
  out[#out + 1] = "  settings = {"
  for _, spec in ipairs(SET.spec.list) do
    if spec.key and SET.changed(spec.key) then
      local v = ed.settings[spec.key]
      local lit
      if type(v) == "string"  then lit = QUOTE .. v .. QUOTE
      elseif type(v) == "boolean" then lit = v and "true" or "false"
      else lit = tostring(v) end
      -- A dotted key is a path into a nested table (logging.enabled), and
      -- `logging.enabled = true` inside a table constructor is a syntax error,
      -- not a nested write. Bracket it. The overlay reads these back with
      -- pairs() and looks each one up in the registry by its full dotted name,
      -- so the string form is what it wants.
      local name = spec.key:find(".", 1, true)
        and string.format("[%s%s%s]", QUOTE, spec.key, QUOTE)
        or spec.key
      out[#out + 1] = string.format("    %-24s = %s,   -- default %s", name, lit,
        SET.spec.display(spec, SET.shipped(spec.key)))
      setCount = setCount + 1
    end
  end
  out[#out + 1] = "  },"

  out[#out + 1] = "}"

  local w = io.open(USER_CONFIG_PATH, "w")
  if not w then edSay("cannot write " .. USER_CONFIG_PATH, 0xFF4444) return end
  w:write(table.concat(out, "\n") .. "\n")
  w:close()

  -- Apply live. Rebuilding in memory beats re-reading, which every other
  -- subsystem already holds references into.
  local fresh = {}
  for _, item in ipairs(conds) do
    fresh[#fresh + 1] = { itemName = item, amountToMaintain = ed.threshold[item] or DEFAULT_TARGET }
  end
  config.conditions = fresh

  for item, t in pairs(ed.targets) do
    config.dustTargets[item] = { asteroid = t.asteroid, priority = t.priority }
  end

  local newDust = {}
  for _, cond in ipairs(config.conditions) do
    local prev = brokerState.dust[cond.itemName]
    newDust[cond.itemName] = { stock = prev and prev.stock or 0,
                               threshold = cond.amountToMaintain }
  end
  brokerState.dust   = newDust
  dustScroll         = 0
  edRequestWatchlist = true

  -- Apply the settings live, through the SAME mapping config.lua used at boot,
  -- so a knob cannot behave one way after a reboot and another after an edit.
  -- The loader and the dispatch loop read config on every pass, so nothing here
  -- needs a restart.
  for key, value in pairs(ed.settings) do
    config.settings[key] = value
    SET.spec.applyOne(config, key, value)
  end
  -- Anything with scope="node" has to reach the nodes, which is what this asks
  -- the main loop to do rather than waiting out the broadcast cadence.
  edRequestNodes = true

  local newPar = {}
  for key, p in pairs(ed.par) do
    newPar[key] = { tips = p.tips, rods = p.rods, batch = p.batch }
  end
  config.drillPar = newPar
  edRequestPar    = true
  -- The dust panel caches its sorted list against edGen, and a save can change
  -- which items exist and what their thresholds are, not just their stock.
  edTouch()

  edSay(string.format(
    "saved %d tracked, %d own mappings, %d drill par, %d setting(s) -> applied live",
    #conds, mineCount, parCount, setCount), 0x00FF00)
end

local edButtons = {}
local function edLayoutButtons()
  local defs
  -- A PROMPT OWNS THE BUTTON ROW.
  --
  -- The row keeps painting underneath an open prompt, and its buttons kept
  -- firing mode actions -- clicking SAVE while typing a number ran a save with
  -- the prompt still up. Swapping the set means the mouse does the two things
  -- that make sense here and nothing else, and it gives the cancel a target for
  -- anyone who has not found Tab yet.
  if ed.input or ed.filtering then
    defs = { { "OK", "input_ok" }, { "CANCEL", "input_cancel" } }
  elseif ed.mode == "asteroids" then
    defs = { { "ITEMS", "items" }, { "DRILLS", "drills" }, { "SETTINGS", "settings" },
             { "FIND", "find" }, { "SAVE", "save" }, { "CLOSE", "close" } }
  elseif ed.mode == "detail" then
    defs = { { "BACK", "back" }, { "ADD", "add" }, { "FIND", "find" },
             { "SAVE", "save" }, { "CLOSE", "close" } }
  elseif ed.mode == "drills" then
    defs = { { "ASTEROIDS", "asteroids" }, { "SETTINGS", "settings" }, { "FIND", "find" },
             { "SAVE", "save" }, { "CLOSE", "close" } }
  elseif ed.mode == "settings" then
    defs = { { "ASTEROIDS", "asteroids" }, { "DRILLS", "drills" }, { "FIND", "find" },
             { "RESET", "reset" }, { "SAVE", "save" }, { "CLOSE", "close" } }
  else
    defs = { { "ASTEROIDS", "asteroids" }, { "DRILLS", "drills" }, { "SETTINGS", "settings" },
             { "FIND", "find" }, { "SAVE", "save" }, { "CLOSE", "close" } }
  end
  edButtons = {}
  local x = 2
  for _, d in ipairs(defs) do
    local label = " " .. d[1] .. " "
    edButtons[#edButtons + 1] = { x1 = x, x2 = x + #label - 1, label = label, action = d[2] }
    x = x + #label + 2
  end
end

local X_MARK, X_NAME = 2, 6
local X_A, X_B, X_C = 44, 56, 68
-- Fourth column, used only by the drills page: what is actually in stock, right
-- beside the floor it is being compared against.
--
-- Every other column here is a fixed offset that quietly assumes a tier-3
-- screen, which the three-panel dashboard needs anyway. This one is guarded
-- rather than assumed, because a narrow screen would not truncate it -- it would
-- collide with the BATCH column and print nonsense.
DRILL.xStock    = 80
DRILL.stockFits = W >= 90

-- ---------------------------------------------------------------------------
-- EDITOR PAINTER
--
-- edDraw cost ~625 component calls per repaint: a term.setCursor plus an
-- io.write for every field, a setForeground before most of them, and a
-- full-width fill on every one of the ~44 list rows -- all repeated whether or
-- not anything on that row had changed.
--
-- In OpenComputers each of those is a direct call against a per-tick budget, so
-- one repaint spanned several game ticks. With modules loading it competed with
-- the loader's transposer and ME calls for the same budget, which is why the
-- editor felt worst exactly when the miner was busy.
--
-- Three changes:
--   1. gpu.set instead of term.setCursor + io.write -- one call rather than
--      two, and it skips the OpenOS term layer's cursor bookkeeping.
--   2. Colour changes are guarded, so consecutive fields sharing a colour cost
--      one setForeground between them instead of one each.
--   3. Rows are cached by content signature. Moving the selection repaints the
--      two rows that actually changed, not the whole list.
-- ---------------------------------------------------------------------------
local edCache = {}
local edFG, edBG

-- Call whenever something else has painted over the screen (drawUI, boot). The
-- cache describes what is physically on screen, so if that assumption breaks
-- the cache has to go with it.
local edLastScroll, edLastMode

local function edInvalidate()
  edCache = {}
  edFG, edBG = nil, nil
  edLastScroll, edLastMode = nil, nil
end

-- Scrolling is the cache's worst case: every visible row shows different
-- content, so every signature misses and the whole list repaints -- the full
-- cold-paint cost, on every keypress once the selection reaches the window edge.
--
-- But a scroll is a SHIFT, not new content. gpu.copy moves the whole block in a
-- single call, leaving only the newly exposed rows to paint.
--
-- The cache is shifted to match, and stays truthful precisely because copy
-- really does move what the cache claims is there. A row whose new content
-- happens to equal the shifted content is then correctly skipped; one that
-- differs -- the selection highlight, usually -- is correctly repainted by the
-- signature check.
local function edScrollBlock()
  local first, rows = edFirst(), edRows()
  local prev, mode = edLastScroll, edLastMode
  edLastScroll, edLastMode = ed.scroll, ed.mode
  if not prev or mode ~= ed.mode then return end

  local d = ed.scroll - prev
  if d == 0 or math.abs(d) >= rows then return end

  -- Source row is further down the list when scrolling down, the top of the
  -- window when scrolling up. Either way the block moves by -d.
  gpu.copy(1, (d > 0) and (first + d) or first, W, rows - math.abs(d), 0, -d)

  local moved = {}
  for y, sig in pairs(edCache) do
    if y >= first and y < first + rows then
      local ny = y - d
      if ny >= first and ny < first + rows then moved[ny] = sig end
    else
      moved[y] = sig   -- header and footer rows sit outside the copied block
    end
  end
  edCache = moved
end

-- cells = { {x, s, fg}, ... }, painted left to right over a cleared row.
--
-- `key` identifies the content rather than describing it. Two rows with the
-- same key are guaranteed to hold identical content, so the caller can skip
-- building the cells at all -- which is the expensive part in Lua terms, not
-- the painting.
local function edPaint(y, key, bg, cells)
  if edCache[y] == key then return end
  edCache[y] = key

  if edBG ~= bg then gpu.setBackground(bg); edBG = bg end
  gpu.fill(1, y, W, 1, " ")
  for i = 1, #cells do
    local c = cells[i]
    if edFG ~= c[3] then gpu.setForeground(c[3]); edFG = c[3] end
    gpu.set(c[1], y, c[2])
  end
end

-- True when row y already shows exactly this content, so the caller can skip
-- past it without constructing anything at all.
local function edFresh(y, key) return edCache[y] == key end

local function edDraw()
  local title
  if ed.mode == "asteroids" then
    title = "CONDITION EDITOR  /  asteroids"
  elseif ed.mode == "detail" then
    title = "CONDITION EDITOR  /  " .. tostring(ed.asteroid)
  elseif ed.mode == "drills" then
    title = "CONDITION EDITOR  /  drill consumables"
  elseif ed.mode == "settings" then
    title = "CONDITION EDITOR  /  settings"
  else
    title = "CONDITION EDITOR  /  all tracked items"
  end
  edPaint(1, title, 0x000000, { { 2, title, 0x00FF00 } })

  local n = 0
  for _ in pairs(ed.enabled) do n = n + 1 end
  -- The key half of this line is generated from EDKEYS, so it cannot advertise
  -- a binding that does not exist -- which is the bug that started all this.
  -- Only the counts and the filter state are assembled here.
  local lead
  if ed.mode == "drills" then
    lead = "enter=edit all three"
  elseif ed.mode == "settings" then
    local changed = 0
    for key in pairs(ed.settings) do if SET.changed(key) then changed = changed + 1 end end
    lead = string.format("%d changed from shipped", changed)
  else
    lead = string.format("%d tracked", n)
  end

  local tail = ""
  if ed.changedOnly and ed.mode == "settings" then tail = tail .. "  |  changed only" end
  if ed.filter then tail = tail .. "  |  filter: " .. ed.filter end

  -- Unsaved work is stated in the one line that is always on screen, so it is
  -- something you see before reaching for CLOSE rather than only after.
  local pending = edDirtyCount()
  local hint = lead .. "  |  " .. edLegend() .. tail
  if pending > 0 then hint = hint .. string.format("  |  %d UNSAVED", pending) end
  edPaint(2, hint, 0x000000, { { 2, hint, pending > 0 and 0xFFAA00 or 0x888888 } })

  if ed.mode == "asteroids" then
    edPaint(4, "h:ast", 0x000000, {
      { X_NAME, "ASTEROID", 0x888888 }, { X_A, "MODULE", 0x888888 },
      { X_B, "DRONES", 0x888888 },      { X_C, "TRACKED", 0x888888 },
    })
  elseif ed.mode == "settings" then
    edPaint(4, "h:settings", 0x000000, {
      { X_NAME, "SETTING", 0x888888 }, { X_A, "VALUE", 0x888888 },
      { X_C, "WHAT IT DOES", 0x888888 },
    })
  elseif ed.mode == "drills" then
    edPaint(4, "h:drills", 0x000000, {
      { X_NAME, "MATERIAL / SETTING", 0x888888 }, { X_A, "TIPS", 0x888888 },
      { X_B, "RODS", 0x888888 },                 { X_C, "BATCH", 0x888888 },
      table.unpack(DRILL.stockFits and { { DRILL.xStock, "IN STOCK", 0x888888 } } or {}),
    })
  else
    edPaint(4, "h:" .. ed.mode, 0x000000, {
      { X_NAME, "ITEM", 0x888888 },  { X_A, "TARGET", 0x888888 },
      { X_B, "HAVE", 0x888888 },
      { X_C, ed.mode == "detail" and "VIA" or "ASTEROID", 0x888888 },
    })
  end

  edScrollBlock()

  for r = 0, edRows() - 1 do
    local y   = edFirst() + r
    local idx = ed.scroll + r + 1
    local row = ed.rows[idx]

    local sel = (idx == ed.sel and row and row.kind ~= "header" and row.kind ~= "note")
    -- Content is fully determined by which list entry is here, whether it is
    -- selected, and the model generation. Same key means the row on screen is
    -- already right, so skip it before building a single table.
    local key = idx .. (sel and "*" or "-") .. edGen
    if edFresh(y, key) then goto continue end

    do
    local bg = sel and 0x222222 or 0x000000
    local cells = {}

    if row then
      if row.kind == "header" then
        cells[1] = { 2, "-- " .. row.text, 0x00AAFF }

      elseif row.kind == "note" then
        cells[1] = { 6, row.text, 0x555555 }

      elseif row.kind == "opt" then
        local spec = row.spec
        local value = ed.settings[spec.key]
        -- A boolean gets a checkbox, because that is what a boolean is and
        -- because the checkbox is also the click target. Everything else shows
        -- its value in the VALUE column and is typed or cycled.
        if spec.type == "bool" then
          cells[#cells+1] = { X_MARK, value and "[x]" or "[ ]",
                              value and 0x00FFFF or 0x555555 }
        end
        -- Anything moved off its shipped default is marked, so a page of
        -- defaults reads as untouched at a glance and the one line you changed
        -- three weeks ago is still findable.
        local moved = SET.changed(spec.key)
        cells[#cells+1] = { X_NAME, (moved and "* " or "  ") .. spec.label,
                            moved and 0xFFFFFF or 0x00FFFF }
        cells[#cells+1] = { X_A, SET.spec.display(spec, value),
                            moved and 0xFFAA00 or 0x00FF00 }
        cells[#cells+1] = { X_C, spec.help:sub(1, W - X_C), 0x666666 }

      elseif row.kind == "par" then
        local par  = ed.par[row.key]
        local on   = par ~= nil
        local fg   = on and 0x00FFFF or 0x555555
        cells[#cells+1] = { X_MARK, on and "[x]" or "[ ]", fg }
        cells[#cells+1] = { X_NAME, row.name, fg }
        cells[#cells+1] = { X_A, on and tostring(par.tips)  or "-", fg }
        cells[#cells+1] = { X_B, on and tostring(par.rods)  or "-", fg }
        cells[#cells+1] = { X_C, on and tostring(par.batch) or "-",
                            on and 0x888888 or 0x555555 }

        -- Kits, not tips and rods separately: a kit is what a load consumes,
        -- and it is what the dispatch floor is counted in.
        if DRILL.stockFits then
          local d     = brokerState.drills[row.key]
          local kits  = (d and d.kits) or 0
          local floor = on and math.min(par.tips or 0, par.rods or 0) or DRILL.floor()
          cells[#cells+1] = { DRILL.xStock, tostring(kits) .. " kits",
            (kits == 0 and 0xFF4444) or (kits >= floor and 0x00FF00) or 0xFFAA00 }

          -- Par is only published for materials a drone in this base actually
          -- uses. Say so on the row, or switching one on for a tier you do not
          -- own looks like the save did nothing.
          if on and W >= DRILL.xStock + 36 then
            if not row.restockOn then
              cells[#cells+1] = { DRILL.xStock + 10, "auto-craft off", 0x666666 }
            elseif not row.usable then
              cells[#cells+1] = { DRILL.xStock + 10, "no drone -- not published", 0x666666 }
            end
          end
        end

      elseif row.kind == "asteroid" then
        cells[#cells+1] = { X_NAME, row.name:sub(1, X_A - X_NAME - 1),
                            row.tracked > 0 and 0x00FFFF or 0x777777 }
        cells[#cells+1] = { X_A, "MK-" .. tostring(row.tier), 0x888888 }
        cells[#cells+1] = { X_B, row.drones, 0x888888 }
        cells[#cells+1] = { X_C, tostring(row.tracked),
                            row.tracked > 0 and 0x00FF00 or 0x555555 }
        if not row.direct then
          cells[#cells+1] = { X_C + 6, "no derived outputs", 0xFFAA00 }
        end

      else -- item
        local item = row.item
        local on   = ed.enabled[item]
        local fg   = on and 0x00FFFF or 0x555555
        cells[#cells+1] = { X_MARK, on and "[x]" or "[ ]", fg }
        cells[#cells+1] = { X_NAME,
          ((row.direct == false and ed.mode == "detail") and "~ " or "  ")
          .. item:sub(1, X_A - X_NAME - 3), fg }
        cells[#cells+1] = { X_A,
          on and formatQty(ed.threshold[item] or DEFAULT_TARGET) or "-", fg }

        local d    = brokerState.dust[item]
        local have = d and d.stock or 0
        local tgt  = ed.threshold[item] or DEFAULT_TARGET
        cells[#cells+1] = { X_B, formatQty(have),
          have >= tgt and 0x00FF00 or (have > 0 and 0xFFAA00 or 0x555555) }

        if ed.mode == "detail" then
          cells[#cells+1] = { X_C, tostring(row.source or "hand-typed"):sub(1, W - X_C),
                              0x666666 }
        else
          local t = ed.targets[item]
          if t then
            cells[#cells+1] = { X_C, tostring(t.asteroid):sub(1, W - X_C), 0x888888 }
          else
            cells[#cells+1] = { X_C, "NOT MINEABLE", 0xFF4444 }
          end
        end
      end
    end

    edPaint(y, key, bg, cells)
    end
    ::continue::
  end

  edLayoutButtons()
  local by    = H - 1
  local cells = {}
  for _, b in ipairs(edButtons) do
    cells[#cells+1] = { b.x1, b.label, 0xFFFFFF }
  end
  local pos = string.format("%d-%d/%d", math.min(ed.scroll + 1, #ed.rows),
    math.min(ed.scroll + edRows(), #ed.rows), #ed.rows)
  cells[#cells+1] = { W - #pos - 1, pos, 0x888888 }
  edPaint(by, "b:" .. pos .. ":" .. #edButtons, 0x000000, cells)

  if ed.input then
    local t = ed.input.label .. " " .. ed.input.buffer .. "_    enter=commit  tab=cancel"
    edPaint(H, "i:" .. t, 0x000000, { { 2, t, 0xFFAA00 } })
  elseif ed.filtering then
    local t = "/" .. (ed.filter or "") .. "_    enter=keep  tab=clear"
    edPaint(H, "f:" .. t, 0x000000, { { 2, t, 0xFFAA00 } })
  else
    local t = ed.msg:sub(1, W - 2)
    edPaint(H, "m:" .. t .. ":" .. tostring(ed.msgColor), 0x000000, { { 2, t, ed.msgColor } })
  end
end

-- ---------------------------------------------------------------------------
-- INPUT
-- ---------------------------------------------------------------------------

local function edOpenSelected()
  local row = ed.rows[ed.sel]
  if not row then return end
  if row.kind == "asteroid" then
    ed.mode, ed.asteroid = "detail", row.name
    ed.sel, ed.scroll = 1, 0
    edRebuild()
    edMoveSel(1)
  elseif row.kind == "opt" then
    SET.activate(row.spec)
  elseif row.kind == "par" then
    DRILL.editAll(row.key)
  elseif row.kind == "item" and ed.mode == "items" then
    local t = ed.targets[row.item]
    if t then
      ed.mode, ed.asteroid = "detail", t.asteroid
      ed.sel, ed.scroll = 1, 0
      edRebuild(); edMoveSel(1)
    else
      edSay(row.item .. " has no asteroid mapping", 0xFFAA00)
    end
  end
end

local function edAction(a)
  -- Any action other than a second CLOSE disarms the discard confirmation, so
  -- an armed CLOSE cannot sit waiting through a dozen further edits and then
  -- throw them away on a stray click.
  if a ~= "close" then ed.closeArmed = false end

  -- The prompt's own buttons. Handled first and returned from, because while a
  -- prompt is open nothing else on the button row should be reachable.
  if a == "input_ok" then
    if ed.input then
      local cb, buf = ed.input.onCommit, ed.input.buffer
      ed.input = nil
      cb(buf)
    elseif ed.filtering then
      ed.filtering = false; edSay("filter: " .. (ed.filter or ""))
    end
    return
  elseif a == "input_cancel" then
    if ed.input then
      ed.input = nil; edSay("cancelled -- value unchanged")
    elseif ed.filtering then
      ed.filtering = false; ed.filter = nil; edRebuild(); edSay("filter cleared")
    end
    return
  end

  if a == "close" then
    -- REFUSE THE FIRST CLOSE IF IT WOULD LOSE WORK.
    --
    -- Everything typed in here lives in a working copy until edSave runs; close
    -- used to drop the lot without a word. Two presses rather than a modal
    -- dialog: the editor has no modal machinery and this does not justify
    -- inventing some.
    local pending = edDirtyCount()
    if pending > 0 and not ed.closeArmed then
      ed.closeArmed = true
      edSay(string.format(
        "%d unsaved change(s) -- s saves them, CLOSE again discards", pending), 0xFFAA00)
      return
    end
    ed.open = false
    ed.closeArmed = false
    -- Same reason as on open: the panels are about to overwrite these rows, so
    -- the cache must not claim they still hold editor content.
    edInvalidate()
    drawStaticFrame()
  elseif a == "activate" then
    -- Space. What it activates depends on the row, which is why this lives here
    -- beside the other row-sensitive actions rather than inline in the key
    -- dispatch -- the dispatch table only needs to know the name.
    local row = selectedRow()
    if row and row.kind == "item" then
      edToggle(row.item, ed.mode == "detail" and ed.asteroid or
                         (ed.targets[row.item] and ed.targets[row.item].asteroid))
      edRebuild()
    elseif row and row.kind == "asteroid" then
      edOpenSelected()
    elseif row and row.kind == "par" then
      DRILL.toggle(row.key)
    elseif row and row.kind == "opt" then
      SET.activate(row.spec)
    end
  elseif a == "type" then
    local row = selectedRow()
    if row and row.kind == "item" then edTypeTarget(row.item)
    elseif row and row.kind == "par" then DRILL.editAll(row.key)
    elseif row and row.kind == "opt" then SET.prompt(row.spec) end
  elseif a == "step" then
    local row = selectedRow()
    if row and row.kind == "item" then edCycleTarget(row.item) end
  elseif a == "changed" then
    if ed.mode ~= "settings" then
      edSay("changed-only applies to the settings page", 0xFFAA00)
    else
      ed.changedOnly = not ed.changedOnly
      ed.sel, ed.scroll = 1, 0
      edRebuild()
      edMoveSel(1)
      edSay(ed.changedOnly and "showing only settings that differ from shipped"
                            or "showing all settings")
    end
  elseif a == "back" then
    if ed.mode == "detail" or ed.mode == "drills" or ed.mode == "settings" then
      ed.mode, ed.asteroid = "asteroids", nil
      ed.sel, ed.scroll = 1, 0
      edRebuild()
      edMoveSel(1)
    else
      edAction("close")
    end
  elseif a == "items" then
    ed.mode = "items"; ed.sel, ed.scroll = 1, 0; edRebuild()
  elseif a == "drills" then
    ed.mode, ed.asteroid = "drills", nil
    ed.sel, ed.scroll = 1, 0
    edRebuild()
    edMoveSel(1)   -- row 1 is a header
  elseif a == "settings" then
    ed.mode, ed.asteroid = "settings", nil
    ed.sel, ed.scroll = 1, 0
    edRebuild()
    edMoveSel(1)   -- row 1 is a header
  elseif a == "reset" then
    local row = selectedRow()
    if row and row.kind == "opt" then SET.reset(row.spec)
    else edSay("select a setting first -- R restores its shipped default", 0xFFAA00) end
  elseif a == "asteroids" then
    ed.mode, ed.asteroid = "asteroids", nil; ed.sel, ed.scroll = 1, 0; edRebuild()
  elseif a == "add" then
    if ed.mode == "detail" then edAddDownstream()
    else edSay("open an asteroid first, then A adds one of its outputs", 0xFFAA00) end
  elseif a == "find" then
    ed.filtering = true; ed.filter = ""; edRebuild()
  elseif a == "save" then
    edSave()
  end
end


-- Returns true if the event was consumed.
local function edHandle(ev)
  local kind = ev[1]

  if kind == "touch" then
    local x, y = ev[3], ev[4]
    if y == H - 1 then
      for _, b in ipairs(edButtons) do
        if x >= b.x1 and x <= b.x2 then edAction(b.action) return true end
      end
      return true
    end
    -- A prompt is modal to the mouse as well as the keyboard: the button row
    -- above is OK/CANCEL while one is open, and clicking a list row underneath
    -- it used to open a second prompt over the first.
    if ed.input or ed.filtering then return true end
    if y >= edFirst() and y < edFirst() + edRows() then
      local idx = ed.scroll + (y - edFirst()) + 1
      local row = ed.rows[idx]
      if row and row.kind ~= "header" and row.kind ~= "note" then
        ed.sel = idx
        if row.kind == "asteroid" then
          edOpenSelected()
        elseif row.kind == "opt" then
          -- Clicking the VALUE column opens the prompt, so a long choice list
          -- can be typed rather than cycled through. A bool has nothing to
          -- type, so it toggles wherever you click it.
          if x >= X_A and x < X_C and row.spec.type ~= "bool" then
            SET.prompt(row.spec)
          else
            SET.activate(row.spec)
          end
        elseif row.kind == "par" then
          -- Click the column you want rather than walking all three.
          if     x >= X_A and x < X_B then DRILL.editField(row.key, "tips")
          elseif x >= X_B and x < X_C then DRILL.editField(row.key, "rods")
          elseif x >= X_C and x < DRILL.xStock then DRILL.editField(row.key, "batch")
          else DRILL.toggle(row.key) end
        elseif x >= X_A and x < X_B then
          edTypeTarget(row.item)
        else
          edToggle(row.item, ed.mode == "detail" and ed.asteroid or
                             (ed.targets[row.item] and ed.targets[row.item].asteroid))
          edRebuild()
        end
      end
    end
    return true

  elseif kind == "scroll" then
    ed.scroll = ed.scroll - (ev[5] or 0) * 3
    local maxScroll = math.max(0, #ed.rows - edRows())
    if ed.scroll > maxScroll then ed.scroll = maxScroll end
    if ed.scroll < 0 then ed.scroll = 0 end
    return true

  elseif kind == "key_down" then
    local ch, code = ev[3], ev[4]

    -- CANCELLING A TEXT PROMPT.
    --
    -- Tab, because it is the only one of these that can work here: q is a
    -- character you might be typing and backspace already deletes one. Delete
    -- and Escape ride along as aliases -- see the K table's header for why
    -- Escape never actually arrives.
    local isCancel = (code == K.TAB or code == K.DELETE or code == K.ESC)

    -- Text entry swallows printable keys. Never blocks the scheduler.
    if ed.input then
      if code == K.ENTER then
        local cb, buf = ed.input.onCommit, ed.input.buffer
        ed.input = nil
        cb(buf)
      elseif isCancel then
        ed.input = nil; edSay("cancelled -- value unchanged")
      elseif code == K.BACKSPACE then
        ed.input.buffer = ed.input.buffer:sub(1, -2)
      elseif ch and ch >= 32 and ch < 127 then
        ed.input.buffer = ed.input.buffer .. string.char(ch)
      end
      return true
    end

    if ed.filtering then
      if code == K.ENTER then
        ed.filtering = false; edSay("filter: " .. (ed.filter or ""))
      elseif isCancel then
        ed.filtering = false; ed.filter = nil; edRebuild(); edSay("filter cleared")
      elseif code == K.BACKSPACE then
        ed.filter = (ed.filter or ""):sub(1, -2); edRebuild()
      elseif ch and ch >= 32 and ch < 127 then
        ed.filter = (ed.filter or "") .. string.char(ch):lower(); edRebuild()
      end
      return true
    end

    -- Navigation stays a ladder: these are not actions, they advertise nothing,
    -- and putting them in EDKEYS would only give the legend rows to skip.
    if     code == K.UP   then edMoveSel(-1)
    elseif code == K.DOWN then edMoveSel(1)
    elseif code == K.PGUP then edMoveSel(-edRows())
    elseif code == K.PGDN then edMoveSel(edRows())
    elseif code == K.HOME then ed.sel = 1; edMoveSel(1); edMoveSel(-1); edFollow()
    elseif code == K.END_ then ed.sel = #ed.rows; edMoveSel(-1); edMoveSel(1); edFollow()
    elseif code == K.ENTER then edOpenSelected()
    else
      -- Everything else comes off EDKEYS, which is also what built the legend
      -- above, so the two cannot disagree about what is bound.
      local binding = edBindingFor(ch, code)
      if binding then edAction(binding.action) end
    end
    return true
  end

  return false
end

-- Dashboard repaint cadence: config.uiInterval. See SETTINGS.md for why 0.1.
local lastUIDraw = 0

-- ---------------------------------------------------------------------------
-- QUIESCING BEFORE THE EDITOR
--
-- The editor competes with the loader for the per-tick component call budget,
-- so it is least responsive exactly when the broker is busiest. Rather than
-- pause work mid-flight -- which risks failing a load, since every loader wait
-- is measured against computer.uptime() and would time out while frozen -- stop
-- handing out NEW jobs and let the in-flight ones land on their own.
--
-- Pressing "e" therefore starts a countdown instead of opening immediately.
-- Dispatch is suspended for its duration; loads already running finish
-- untouched. By the time the editor appears the broker has gone quiet.
--
-- If loads are still running when the countdown ends we keep waiting rather
-- than open into the exact contention this exists to avoid -- but only up to
-- config.quiesceGrace, so a wedged module cannot lock you out of the editor.
--
-- Both timings are settings (quiesceSeconds, quiesceGrace); see SETTINGS.md.
-- ---------------------------------------------------------------------------
local edPending = nil        -- { openAt, hardAt } while counting down
local edPendingShown = nil   -- last text painted, so we only repaint on change
local edPendingPaints = -1   -- dashPaints when we last drew it, to detect damage

-- How many modules are still doing component-heavy work.
--
-- DONE counts as well as LOADING: that state returns leftover tips and rods to
-- the ME network through the transposer, which contends for the call budget
-- just as much as a load does. Only counting LOADING let the editor open while
-- a module was mid-return.
--
-- Pinned restock tasks are deliberately NOT counted. They respawn every
-- PIN_RESTOCK_INTERVAL for as long as a pinned module runs, so waiting on them
-- would never finish -- the grace below would expire every single time and the
-- wait would be theatre.
local function modulesBusy()
  local n = 0
  for _, mod in ipairs(modules) do
    if mod.status == "LOADING" or mod.status == "DONE" then n = n + 1 end
  end
  return n
end

-- A small centred box over the panels. Deliberately drawn on top rather than
-- replacing the UI: the panels keep updating behind it, so it is obvious the
-- broker is still alive and finishing what it started.
local function drawQuiesce(line1, line2)
  local w  = 52
  local x  = math.max(1, math.floor((W - w) / 2))
  local y  = math.max(1, math.floor(H / 2) - 2)
  gpu.setBackground(0x000000)
  for i = 0, 4 do gpu.fill(x, y + i, w, 1, " ") end
  gpu.setForeground(0x00AAFF)
  gpu.fill(x, y, w, 1, "=")
  gpu.fill(x, y + 4, w, 1, "=")
  gpu.setForeground(0xFFAA00)
  gpu.set(x + math.max(0, math.floor((w - #line1) / 2)), y + 1, line1)
  gpu.setForeground(0x888888)
  gpu.set(x + math.max(0, math.floor((w - #line2) / 2)), y + 2, line2)
  gpu.setForeground(0x555555)
  local hint = "tab or q to cancel"
  gpu.set(x + math.max(0, math.floor((w - #hint) / 2)), y + 3, hint)
  -- Only the rows this box covers are now misdescribed by the cache. Dropping
  -- the whole thing here is what created the repaint loop above.
  dashInvalidateRows(y, y + 4)
  dashFG = nil
end

-- ---------------------------------------------------------------------------
-- DUST WATCHLIST
-- The dust node cannot scan an ME network of thousands of item types and fit the
-- result in one modem packet, so it needs a list to filter against. That list
-- used to be its own copy of config.conditions, which meant editing what to mine
-- in two files -- and if they drifted, the broker showed a permanent 0% for
-- anything the node was not scanning.
--
-- So the broker pushes it. config.conditions is now the single source of truth.
-- Thresholds ride along so the node's own dashboard can still show fill %.
-- Sent on startup and re-sent periodically, so a node that boots later (or
-- restarts) picks it up without having to ask.
-- ---------------------------------------------------------------------------
local lastWatchlistSend = 0

local function broadcastWatchlist()
  local list = {}
  for _, cond in ipairs(config.conditions) do
    list[cond.itemName] = cond.amountToMaintain
  end
  modem.broadcast(config.ports.command, serial.serialize({
    protocol    = "MEDINA_COMMAND",
    sender      = nodeId,
    payloadType = "DUST_WATCHLIST",
    data        = list,
  }))
end

-- ---------------------------------------------------------------------------
-- NODE SETTINGS
--
-- The scope="node" subset of the settings registry, pushed to the dust and
-- fluid nodes on the command port. This is what lets those machines ship as a
-- single file with no config at all, instead of a copy of config.lua they only
-- ever read three values out of.
--
-- The same payload goes to every node; each one applies only the keys it holds
-- and ignores the rest, so this does not need to know who is listening.
--
-- Sent on the same slow timer as the watchlist, and again immediately after a
-- save, so an edit lands within a second rather than within a cadence. Nodes
-- cache what they receive, so one that restarts during a broker outage comes
-- back configured rather than reverting to its fallbacks.
--
-- The hw node is not an audience here: it stays off the command port (see the
-- note beside config.ports), and the one setting it cares about,
-- drillCraftSlots, already rides along with DRILL_PAR on its own port.
-- ---------------------------------------------------------------------------
local function broadcastNodeSettings()
  modem.broadcast(config.ports.command, serial.serialize({
    protocol    = "MEDINA_COMMAND",
    sender      = nodeId,
    payloadType = "NODE_SETTINGS",
    data        = config.settingsSpec.nodePayload(config.settings),
  }))
end

-- ---------------------------------------------------------------------------
-- DRILL PAR
-- Same split as the watchlist above: policy here, execution on the node. The hw
-- node holds the ME controller proxy and the freshest counts (our copy of them
-- is up to an HW_UPDATE cycle stale), so it does the comparing and ordering --
-- but what "enough" means is a broker decision, and it lives in config.drillPar.
--
-- Sent as ME labels rather than drill keys because the node resolves crafting
-- patterns by label, and because it does not load config.lua at all -- it has no
-- way to turn "naquadahAlloy" into "Naquadah Alloy Drill Tip".
--
-- Goes out on config.ports.hardware, not the command port: see the note beside
-- config.ports for why the hw node does not want the dust watchlist traffic.
-- ---------------------------------------------------------------------------
local function broadcastDrillPar()
  local list = {}
  local usable = usableDrillKeys()
  -- config.drillRestock off means the hw node is told to order nothing at all,
  -- whatever config.drillPar says. Building an empty list rather than skipping
  -- the broadcast is deliberate: the node has to HEAR that it should stop, and
  -- a broker that simply went quiet is indistinguishable from a broker that is
  -- down -- which is the state the node keeps its last par through.
  --
  -- The par table itself is left untouched, so switching this back on restores
  -- exactly the floors you had rather than making you re-enter them.
  local enabled = config.drillRestock ~= false
  for key, par in pairs(enabled and config.drillPar or {}) do
    local drill = config.drills[key]
    -- An unknown key is a config typo. Skip it rather than shipping a nil label
    -- the node would have to defend against.
    if drill and drill.tip and drill.rod and usable[key] then
      -- Each label carries its own floor plus the shared batch size. Sent per
      -- label rather than per material because the node works in ME labels and
      -- has no idea which tip pairs with which rod.
      local batch = par.batch
      list[drill.tip] = { min = par.tips or 0, batch = batch or par.tips or 0 }
      list[drill.rod] = { min = par.rods or 0, batch = batch or par.rods or 0 }
    end
  end
  -- An empty table still goes out: that is how a node that was ordering learns
  -- to stop after you cleared config.drillPar.
  modem.broadcast(config.ports.hardware, serial.serialize({
    protocol    = "MEDINA_COMMAND",
    sender      = nodeId,
    payloadType = "DRILL_PAR",
    -- The node cannot read config.lua, so the concurrency limit rides along
    -- with the par table rather than being configured over there.
    --
    -- The `or 1` is the absent-value case, not the default -- config ships 2.
    -- An older config.lua tells us nothing about the CPU count, and guessing
    -- low only slows restocking whereas guessing high produces rejected
    -- requests. Leave it at 1.
    --
    -- `enabled` is sent as well as the empty table, because those are two
    -- different states to be in and the node's dashboard should not have to
    -- guess. An empty par with enabled=true means "nothing is currently
    -- restockable" -- no drone in stock for any material, say. Empty with
    -- enabled=false means "you have turned this off". An older broker sends
    -- neither, which the node reads as enabled.
    data        = { par = list, slots = config.drillCraftSlots or 1,
                    enabled = enabled },
  }))
  local n = 0
  for _ in pairs(list) do n = n + 1 end
  brokerState.lastParSend  = os.date("%X")
  brokerState.lastParCount = n
end

-- Publish par once before entering the loop. The interval timer below compares
-- against computer.uptime(), which is time since this COMPUTER booted, not since
-- this program started -- so on a freshly booted machine the first send would
-- otherwise be 30s away, and a node that just started sits on "Awaiting par"
-- long enough to look broken.
pcall(broadcastDrillPar)
pcall(broadcastNodeSettings)

-- ---------------------------------------------------------------------------
-- SHUTDOWN
--
-- Runs on every exit path, crash included. A broker that dies mid-cycle leaves
-- its modules exactly as they were: work gates open, so a multiblock keeps
-- consuming the tips and rods in its bus with nobody watching, and interface
-- configuration slots still standing, so the ME keeps stocking consumables into
-- buffers for jobs that will never run. Neither clears itself, and neither is
-- obvious from looking at the machines -- they look busy.
--
-- Everything here is pcall'd individually. This is the last code to run before
-- the program is gone; one unhappy adapter must not stop the other five modules
-- being shut down properly.
--
-- Goes through loader.clearInterfaceSlots like every other cleanup path, so a
-- module that was mid-load with several slots allocated has all of them
-- released rather than the first three.
-- ---------------------------------------------------------------------------
local function shutdown()
  for _, mod in ipairs(modules) do
    pcall(function() mod.adapter.setWorkAllowed(false) end)
    pcall(clearInterfaceSlots, mod)
  end
end

-- The main loop, as a function so it can be wrapped. It never returns on its
-- own: the broker runs until it is interrupted or something throws.
--
-- The loop body below keeps its original indentation rather than being shifted
-- in a level. Two hundred lines of pure whitespace change would bury the actual
-- edits in this file's history for no reading benefit.
local function mainLoop()
while true do
  -- 1. Service one inbound message. Very short timeout: returns immediately if a
  --    message is waiting, otherwise yields the CPU for ~10ms and comes back so
  --    the scheduler keeps ticking fast.
  -- Pull ANY event, not just modem_message: the dust panel is scrollable and
  -- nothing else in this program consumes input.
  local ev = { event.pull(0.01) }
  if ev[1] == "modem_message" then
    processMessage(table.unpack(ev))
    -- Only DUST_UPDATE can move anything the editor shows (the HAVE column).
    -- HW_UPDATE and FLUID_UPDATE used to force a full repaint too, several times
    -- a minute, for a screen whose contents they cannot affect. Even for dust,
    -- do not repaint here: the 2s tick below already refreshes it, and stock
    -- figures do not need sub-second latency. Keypresses still repaint at once.

  elseif ed.open then
    -- The editor owns input while it is up, but ONLY input. Execution still
    -- falls through to sched.tick() and stepModules() below, so loads in flight
    -- keep progressing while someone edits. That is the whole reason this is a
    -- UI mode rather than a separate blocking program.
    if edHandle(ev) then ed.dirty = true end

  elseif ev[1] == "scroll" then
    -- ev = { "scroll", screenAddr, x, y, direction, player }
    local sx, dir = ev[3], ev[5]
    if sx and dir and sx >= P2 and sx < P3 then
      dustScroll = dustScroll - dir * 2   -- clamped in drawDustPanel
      lastUIDraw = 0                      -- repaint now, do not wait for the tick
    end

  elseif ev[1] == "key_down" and ev[3] == 101 and not edPending then  -- "e"
    -- Do not open yet: start quiescing. See QUIESCING above.
    local up = computer.uptime()
    edPending = { openAt = up + config.quiesceSeconds,
                  hardAt = up + config.quiesceSeconds + config.quiesceGrace }
    edPendingShown = nil

  elseif ev[1] == "key_down" and edPending
     and (ev[4] == K.TAB or ev[4] == K.ESC or ev[3] == 113 or ev[3] == 81) then
    -- Aborting the countdown. Escape is listed last and never fires; see the K
    -- table's header. Without tab and q this box could not be cancelled at all.
    edPending, edPendingShown = nil, nil
    lastUIDraw = 0   -- wipe the box on the next pass
  end

  -- Countdown, and the handover into the editor.
  if edPending then
    local up = computer.uptime()
    local busy = modulesBusy()
    if up >= edPending.openAt and (busy == 0 or up >= edPending.hardAt) then
      edPending, edPendingShown = nil, nil
      ed.open = true
      -- drawUI has been painting over this screen; the row cache describes what
      -- was there before, so it is now a lie. Drop it.
      edInvalidate()
      edBuild()
      if busy > 0 then
        -- Opened on the grace rather than because the broker went quiet. Say so:
        -- otherwise it looks like the wait did not work, and it explains why the
        -- editor may feel sluggish for the next few seconds.
        edSay(busy .. " module(s) still working -- editor may lag briefly", 0xFFAA00)
      else
        edSay("new jobs paused while this is open -- tab or q to resume mining")
      end
      ed.dirty = true
    end
  end

  -- A save inside the editor rewrites config.conditions and applies it live, so
  -- push the new watchlist immediately rather than waiting out the 30s cadence.
  if edRequestWatchlist then
    broadcastWatchlist()
    lastWatchlistSend  = computer.uptime()
    edRequestWatchlist = false
  end

  -- Same for drill par. Separate flag rather than folded into the one above,
  -- because edSave sets both and this is the only place broadcastDrillPar is in
  -- scope -- it is defined below the editor. Without it a par change waited out
  -- the 30s cadence, which reads as the edit not having taken.
  if edRequestPar then
    broadcastDrillPar()
    edRequestPar = false
  end

  if edRequestNodes then
    broadcastNodeSettings()
    edRequestNodes = false
  end

  -- 1b. Re-publish the dust watchlist on its own slow cadence.
  local nowW = computer.uptime()
  if nowW - lastWatchlistSend >= config.watchlistInterval then
    broadcastWatchlist()
    broadcastDrillPar()      -- one timer, three audiences; all three change rarely
    broadcastNodeSettings()
    lastWatchlistSend = nowW
  end

  -- 2. Redraw, BEFORE advancing any work.
  --
  -- Two reasons this comes first rather than last. Latency: the event that was
  -- just handled is usually a keypress, and running the scheduler, the module
  -- lifecycle and dispatch before repainting put all of that in the
  -- keypress-to-pixels path. Budget: OpenComputers meters direct component
  -- calls per tick, and whoever calls first in a tick gets served first -- so
  -- drawing ahead of the loader means the UI is not left waiting on the next
  -- tick behind a batch of transposer and ME calls.
  --
  -- The cost is that a frame reflects state from just before this iteration's
  -- sched.tick(). At a 0.25s panel cadence and 2s in the editor, one iteration
  -- of staleness is not observable.
  local up = computer.uptime()

  -- Sample computation demand every pass, not from the draw path. The editor
  -- suppresses redraws for up to two seconds at a time while modules carry on
  -- mining, and a window that only saw the frames it painted would quietly lose
  -- that time out of its average.
  computationSample()

  if ed.open then
    -- Event-driven: repaint when the editor changed, plus a slow tick so live
    -- HAVE values from telemetry still refresh. Repainting a full-screen list
    -- four times a second was the other half of the flicker.
    if ed.dirty or (up - lastUIDraw >= 2.0) then
      edDraw()
      ed.dirty   = false
      lastUIDraw = up
    end
  else
    if up - lastUIDraw >= config.uiInterval then
      drawUI()
      lastUIDraw = up
    end
    if edPending then
      local left = math.max(0, math.ceil(edPending.openAt - up))
      local n    = modulesBusy()
      local l1, l2
      if left > 0 then
        l1 = "OPENING EDIT MENU IN " .. left
        l2 = (n > 0) and ("new jobs paused -- " .. n .. " module(s) finishing")
                      or "new jobs paused -- broker going idle"
      else
        l1 = "WAITING FOR " .. n .. " MODULE(S) TO FINISH"
        l2 = "opens anyway in " .. math.max(0, math.ceil(edPending.hardAt - up)) .. "s"
      end
      -- Redraw when the text changes (once a second) or when the panels have
      -- actually painted something, which is the only way the box gets damaged.
      -- Unchanged rows are skipped by the cache, so a settled dashboard leaves
      -- the box alone and this costs nothing.
      local shown = l1 .. "|" .. l2
      if edPendingShown ~= shown or edPendingPaints ~= dashPaints then
        drawQuiesce(l1, l2)
        edPendingShown  = shown
        edPendingPaints = dashPaints
      end
    end
  end

  -- 3. Advance every in-flight load task. This is the hot path — runs every
  --    iteration so concurrent loads progress as fast as the hardware allows.
  sched.tick()

  -- 4. Advance module lifecycle (load results, running->done, cleanup).
  stepModules()

  -- 5. Telemetry-ready gate. All three telem sources are required: dust (what to
  --    mine), hardware (drones/kits available), and fluid (plasma — modules can't
  --    run without it). Wait for all three before dispatching.
  if not brokerState.telemetryReady then
    brokerState.telemetryReady = (brokerState.lastDustSyncTime > 0)
        and (brokerState.lastHWSyncTime > 0)
        and (brokerState.lastFluidSyncTime > 0)
  end

  -- 6. Dispatch on its own cadence -- unless we are quiescing for the editor or
  --    it is already open. Existing work is never interrupted; we simply stop
  --    starting more, so the broker drains to idle and stays there.
  local now = computer.uptime()
  -- `not nodeFault()` sits here beside the other gates rather than inside
  -- dispatchBatch, because it is the same kind of condition as the two next to
  -- it: a reason not to start new work, not a rule about how work is chosen.
  if brokerState.telemetryReady and not ed.open and not edPending
     and not nodeFault()
     and (now - lastDispatchCheck >= config.dispatchInterval) then
    dispatchBatch()
    lastDispatchCheck = now
  end

end
end

-- Wrapped, so a throw anywhere in the loop lands here instead of killing the
-- program outright and leaving the array running. space-pumping/autoPump.lua
-- has done this since it was written; the broker never did, which is why an
-- unexpected nil from a component could take six mining modules with it.
local ok, err = xpcall(mainLoop, debug.traceback)

pcall(shutdown)

if gpu then pcall(function() gpu.setForeground(0xFFFFFF) end) end
if ok then
  logger:info("clean shutdown")
  print("Broker stopped. All modules gated off.")
else
  logger:error("CRASH: " .. tostring(err))
  print("broker-mk3 crashed - all modules gated off and interfaces cleared.")
  print(tostring(err))
end
