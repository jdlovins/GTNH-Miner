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
--           /home/editor.lua, /home/job_node_config.lua, /home/config.lua,
--           /home/logger.lua
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
local editor        = dofile("/home/editor.lua")

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
    -- initModules() from config.gtVersion -- not probed; see module_api.lua for
    -- why the drone label forced that. Still nil for a module whose adapter
    -- answers neither dialect, which must be reported on the dashboard rather
    -- than erroring the whole boot.
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

  -- Every drone the fleet owns, whether it is in the network or in a module.
  --
  -- This used to read the ME figure and then re-add "anything a busy module is
  -- holding", because a drone loaded into a running module reports as zero and
  -- dropping its material from par mid-run is exactly backwards -- that is the
  -- material actively being consumed. The declared fleet does not go missing
  -- while it is being used, so the second loop is gone with the reason for it.
  for droneKey, count in pairs(config.droneStock or {}) do
    if (tonumber(count) or 0) > 0 then
      local tier = config.droneTierKeys[droneKey]
      local dk   = tier and config.droneDrillMap[tier]
      if dk then keys[dk] = true end
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

  -- Nothing is recorded here any more. This used to stamp mod.returned so the
  -- pool could count a drone that had left the bus but not yet reached the
  -- network -- a blind spot that only existed because the pool was derived from
  -- what the ME could see. It is derived from the declared fleet now, and a
  -- drone in transit never stopped being counted, so there is nothing to
  -- remember. (The stamp was also wrong: it recorded the drone the JOB wanted,
  -- not the one the bus HELD, so a failed load -- where no drone ever
  -- arrived -- credited one that did not exist.)
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
    logger:info(
      "[LOAD] M%d %.1fs = pre %.1fs + fill %.1fs (%d passes, %d waiting) start %d/%d",
      mod.index, elapsed, s.preDrainSecs or 0, s.fillSecs or 0,
      s.fillPasses or 0, s.fillWaits or 0, sw.tips or 0, sw.rods or 0)
    logger:info(
      "[LOAD] M%d ready (confirm polls d=%s t=%s r=%s, arrive=%s)",
      mod.index, tostring(cp.drone), tostring(cp.tip), tostring(cp.rod),
      tostring(s.arrivePolls))
    mod.status = "RUNNING"
    mod.runStartedAt = computer.uptime()
    mod.lastRunPollAt = 0
    mod.inactiveStreak = 0
    mod.inactiveSinceAt = nil
    mod.nextHeartbeatAt = computer.uptime() + RUN_HEARTBEAT_INTERVAL
    mod.lastRunWarnAt = 0
    mod.job.startTime = computer.uptime()
    logger:info(
      "[HEALTH] M%d started asteroid=%s dist=%s x%s",
      mod.index,
      tostring(mod.job and mod.job.asteroid or "?"),
      tostring(mod.job and mod.job.distance or "?"),
      tostring(mod.job and mod.job.parallels or "?"))
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
-- WHEN and WHAT to top up. The HOW -- reading the inventories and moving the
-- items -- is loader.topUp, next to drain(), which is the same job and had the
-- same lesson learned in it years earlier. This function used to do both, and
-- its half of the work asked the hardware the same question four times per
-- consumable per pass.
local function restockRunning(mod)
  if mod.status ~= "RUNNING" or not mod.job then return end
  local drill = config.drills[mod.job.drillKey]
  if not drill then return end

  local TIPS_PER = config.tipsPerLoad or 64
  local RODS_PER = config.rodsPerLoad or 64
  local _, slotTip, slotRod = loader.dbSlotsFor(mod.index)

  local wanted = {
    { label = drill.tip, target = TIPS_PER, cfgSlot = 2, dbSlot = slotTip },
    { label = drill.rod, target = RODS_PER, cfgSlot = 3, dbSlot = slotRod },
  }

  local results, totals, moved = loader.topUp(mod, wanted, dbAddr)

  if moved then
    mod.refills        = (mod.refills or 0) + 1
    cycleStats.refills = (cycleStats.refills or 0) + 1
  end

  -- Stop asking once each consumable is either at target or cannot fit. Waiting
  -- for both to reach target meant a bus too small for two full stacks retried
  -- for the entire window and never finished -- which looked like "sometimes it
  -- does not top up at all".
  local tipState, rodState = results[1], results[2]
  local settled = (tipState ~= "partial") and (rodState ~= "partial")
  if settled then
    -- `totals` came back from the pass that just ran. The old code re-read the
    -- whole bus twice here purely to build this line -- every three seconds,
    -- forever, on a pinned module that had nothing left to do.
    logger:info("[RESTOCK] M%d settled at tips %d/%d (%s), rods %d/%d (%s)",
      mod.index, totals[drill.tip] or 0, TIPS_PER, tipState,
      totals[drill.rod] or 0, RODS_PER, rodState)
    if tipState == "nofit" or rodState == "nofit" then
      logger:warn("[RESTOCK] M%d input bus has no room for a full buffer -- it needs %d free slots " ..
        "(drone + %d stacks of tips + %d stacks of rods)",
        mod.index, 1 + math.ceil(TIPS_PER / 64) + math.ceil(RODS_PER / 64),
        math.ceil(TIPS_PER / 64), math.ceil(RODS_PER / 64))
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
        logger:info("[SPINUP] M%d running %.2fs after enable", mod.index, spin)
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
      logger:warn(
        "[HEALTH] M%d recovered after %.1fs inactive blip (streak=%d)",
        mod.index, downFor, mod.inactiveStreak)
    end
    mod.inactiveStreak = 0
    mod.inactiveSinceAt = nil
    if now >= (mod.nextHeartbeatAt or 0) then
      logger:info(
        "[HEALTH] M%d running asteroid=%s for %.0fs",
        mod.index,
        tostring(mod.job and mod.job.asteroid or "?"),
        now - (mod.runStartedAt or now))
      mod.nextHeartbeatAt = now + RUN_HEARTBEAT_INTERVAL
    end
    return
  end

  if not mod.inactiveSinceAt then
    mod.inactiveSinceAt = now
  end
  mod.inactiveStreak = (mod.inactiveStreak or 0) + 1
  if mod.inactiveStreak == 1 or (now - (mod.lastRunWarnAt or 0) >= RUN_WARN_COOLDOWN) then
    logger:warn(
      "[HEALTH] M%d inactive while RUNNING (streak=%d/%d, asteroid=%s)",
      mod.index,
      mod.inactiveStreak,
      RUN_INACTIVE_CONFIRM,
      tostring(mod.job and mod.job.asteroid or "?"))
    mod.lastRunWarnAt = now
  end
  if mod.inactiveStreak < RUN_INACTIVE_CONFIRM then
    return
  end

  logger:warn(
    "[HEALTH] M%d marking DONE after %.1fs inactive confirmation",
    mod.index,
    now - (mod.inactiveSinceAt or now))
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
    logger:info("[CYCLE] M%d done (%d total, duty %.0f%%)",
      mod.index, cycleStats.cycles, statsDuty())
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
  logger:info("[HOLD] M%d released after %.0fs unclaimed",
    mod.index, computer.uptime() - (mod.heldSince or 0))
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
    -- A module with no dialect is never dispatchable: the load would run in
    -- full and only then discover there is no way to tell the module where to
    -- mine. Leave it out of dispatch entirely, including out of the ERROR
    -- recovery below, which would otherwise hand it a job every ERROR_TIMEOUT
    -- seconds forever.
    --
    -- There used to be a re-probe here, for an adapter caught mid chunk-reload
    -- at boot. The dialect comes from the gtVersion setting now, not from the
    -- hardware, so it is set for every module or for none and there is nothing
    -- a retry could discover.
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

  -- ONE GATE FOR DRONES, TWO FOR KITS, AND THE DIFFERENCE IS THE POINT.
  --
  -- There used to be a second drone gate on brokerState.drones -- the raw ME
  -- figure -- asking "can this actually be FETCHED". It was there because the
  -- pool was derived from telemetry and could disagree with it. The pool is the
  -- declared fleet minus what modules are using now, so there is nothing left
  -- for a second opinion to add: if the ledger says free and the network cannot
  -- hand it over, the fleet has drifted from what you declared, and the loader
  -- says so by name rather than this silently picking a weaker drone.
  --
  -- Kits keep both, because they ARE measured: enough unpromised, and enough
  -- actually in the network.
  --
  -- A module that holds the hardware needs none of it: the drone never left it,
  -- and the loader only fetches what it is short of.
  if not holds then
    if (avail[droneKey] or 0) <= 0 then return false end

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
    logger:info("[FASTLOAD] M%d keeping %s for %s (consumables fetched fresh)",
      mod.index, tostring(config.drones[droneKey]), asteroid)
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
-- KITS ONLY, now. Drones stopped asking this the moment the pool became
-- "declared minus committed" -- there is no sweep in that sum to be ahead of.
-- Tips and rods are consumed, so their figure really is measured and this
-- question really does have to be answered.
--
-- hw_telem scans and broadcasts once per loop around a 10s event.pull, so a
-- figure older than this means the node has genuinely stopped reporting rather
-- than merely being between sweeps.
local HW_STALE = 30

-- `trustStaleFigure` only relaxes the staleness bail-out below; an unseen
-- commitment is charged either way. Default (no argument) is the careful answer,
-- so a new call site has to opt IN to trusting a figure that stopped moving.
local function telemetryHasSeen(mod, trustStaleFigure)
  local at = mod.job and mod.job.dispatchedAt
  if not at then return true end   -- pre-existing job from before this field
  local sync = brokerState.lastHWSyncTime or 0
  -- A STALE FIGURE IS NOT EVIDENCE, whatever its timestamp says about the past.
  -- If the node has gone quiet, sync stops advancing and every commitment older
  -- than it would otherwise count as "already excluded from the stock figure" --
  -- so the broker would keep dispatching against a number that will never move
  -- again. Charging everything instead stops dispatch and self-corrects the
  -- moment the node reports.
  --
  -- This used to be behind a reserveWhileMining setting. That is gone,
  -- because its off position was identical to on whenever telemetry was healthy
  -- and strictly worse whenever it was not -- which is not a preference.
  if not trustStaleFigure and (computer.uptime() - sync) > HW_STALE then
    return false
  end
  return at <= sync
end

-- How many of each drone are actually free to assign right now?
--
-- DECLARED, MINUS WHAT IS COMMITTED. No telemetry, no timestamps, no windows.
--
-- This used to start from the ME figure and try to reconstruct reality from it:
-- subtract commitments a sweep had not seen, add back what modules were holding,
-- add back what was in flight to the network. Every one of those corrections
-- existed because hw_telem can only see the NETWORK, and a drone in an input
-- bus, an interface buffer, or mid-transfer is not in it. Four separate bugs
-- came out of that seam -- a tier frozen at a stale count, a returned drone
-- invisible for a sweep, a drone left in a bus invisible at boot, and a sweep
-- timestamp that records arrival rather than when the scan ran.
--
-- config.droneStock is the fleet, stated by the operator. Everything else here
-- is bookkeeping the broker does itself and therefore knows exactly.
--
-- Takes no arguments, and that is the tell: there is no "how much do we trust
-- the sweep" question left to answer for drones. availableKits still has one,
-- because tips and rods ARE consumed and their figure really is measured.
local function availableDrones()
  local avail = {}
  for key, count in pairs(config.droneStock or {}) do
    avail[key] = tonumber(count) or 0
  end

  for _, mod in ipairs(modules) do
    -- Anything not idle is using its drone, full stop. No exception for a
    -- commitment the sweep has already accounted for, because there is no sweep
    -- in this sum any more -- the double-charge that exception existed to
    -- prevent cannot occur.
    if mod.status ~= "IDLE" and mod.job and mod.job.droneKey then
      local k = mod.job.droneKey
      avail[k] = (avail[k] or 0) - 1
    end
    -- NOTHING IS ADDED BACK FOR A HOLD, and that is not an omission. With
    -- fastReload a finished module keeps its drone and goes IDLE with job = nil,
    -- so the charge above skips it -- and it is already inside the declared
    -- total, because it never stopped being ours. The old version had to credit
    -- holds explicitly to undo the ME figure calling them missing; there is no
    -- ME figure here to undo. preferHolder still hands it back to the same
    -- module, which is a routing decision, not an accounting one.
  end

  -- A fleet declared smaller than what is actually committed -- you dispatched
  -- ten and then edited the setting down to eight -- must not read as negative.
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
-- `trustStaleFigure` picks the view, and the two callers want opposite answers.
-- Dispatch passes false: committing against a figure that stopped updating is
-- how you over-promise a material. The dust panel's reachability check passes
-- true, because its question is "can this array ever mine that" -- and a hw node
-- that died five minutes ago is no reason to report every asteroid as beyond us.
local function availableKits(trustStaleFigure)
  local perLoad = math.max(config.tipsPerLoad or 64, config.rodsPerLoad or 64)
  local avail = {}
  for key, d in pairs(brokerState.drills) do avail[key] = (d and d.kits) or 0 end
  for _, mod in ipairs(modules) do
    if mod.status ~= "IDLE" and mod.job and mod.job.drillKey
       and not telemetryHasSeen(mod, trustStaleFigure) then
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
    -- The panels report what dispatch will actually do, so they take the same
    -- conservative kit view it does.
    POOL.drones = availableDrones()
    POOL.kits   = availableKits(false)
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
  local avail          = availableDrones()
  local availKit       = availableKits(false)
  local minKitsForLoad = math.max(config.tipsPerLoad or 64, config.rodsPerLoad or 64)

  -- A SECOND view, for reachability only.
  --
  -- Reachability asks whether this array can ever serve a need at all -- not
  -- what is free this instant. Answering it from the dispatch pool would fill
  -- the dust panel with "NO KITS" for materials we hold plenty of, whenever the
  -- hw node happened to be quiet.
  --
  -- Drones need no second view: the declared fleet is what we own, and dispatch
  -- reads the same table. This used to build a duplicate of it under
  -- reserveWhileMining, which is a table per batch for no difference.
  local reachAvail    = avail
  local reachAvailKit = availableKits(true)

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

    -- WHY A BETTER DRONE WAS NOT USED.
    --
    -- assignOne walks the tiers high to low and takes the first one it can
    -- place, which means a module ending up on a weak drone is the RESULT of
    -- several silent refusals. Three of them are legitimate -- the asteroid caps
    -- below that tier, its drill material is short, every one is already out --
    -- and telling them apart from the outside is guesswork. Record the first
    -- skip so the dispatch log can name it.
    local skipped
    local function note(key, why)
      if not skipped then skipped = { model = config.droneModel(key), why = why } end
    end

    for _, droneKey in ipairs(config.droneKeyOrder) do
      local droneTier = config.droneTierKeys[droneKey]
      -- Only worth explaining for a tier we actually own; the rest is noise.
      if droneTier and (tonumber((config.droneStock or {})[droneKey]) or 0) > 0 then
        if droneTier > asteroidData.maxDrone or droneTier < asteroidData.minDrone then
          note(droneKey, string.format("%s takes tier %d-%d",
            asteroidName, asteroidData.minDrone, asteroidData.maxDrone))
        elseif (avail[droneKey] or 0) <= 0 then
          note(droneKey, string.format("none free (%d owned, all committed)",
            tonumber((config.droneStock or {})[droneKey]) or 0))
        else
          local dk = config.droneDrillMap[droneTier]
          if dk and (availKit[dk] or 0) < minKitsForLoad then
            note(droneKey, string.format("%s kits %d < %d",
              dk, availKit[dk] or 0, minKitsForLoad))
          end
        end
      end

      if (avail[droneKey] or 0) > 0 then
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
                if skipped then
                  logger:info("[DISPATCH] M%d <- %s on %s; passed over %s: %s",
                    mod.index, config.droneModel(droneKey), asteroidName,
                    skipped.model, skipped.why)
                end
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

-- ---------------------------------------------------------------------------
-- HARDWARE STOCK: REPLACE, DO NOT MERGE.
--
-- This was `for k, v in pairs(data.drones) do state.drones[k] = v end`, and the
-- combination of that with a node that only sent non-zero counts meant A TIER
-- THAT REACHED ZERO NEVER CAME BACK. Once the last LuV drone was committed, the
-- node stopped mentioning luv, the merge had nothing to overwrite the old 7
-- with, and the broker believed in seven drones that did not exist until it was
-- restarted.
--
-- What that cost: tryDispatch's only guard against handing out a drone the
-- network does not physically hold is `brokerState.drones[droneKey] <= 0`. With
-- the count frozen high that guard never fires, so a surplus module was
-- dispatched, waited out ARRIVE_TIMEOUT for a drone that was not there, failed
-- to ERROR, recovered, and went round again forever.
--
-- hw_telem now sends its zeroes, which fixes this from the other end. Both
-- halves are here on purpose: this one also covers an un-upgraded node, and
-- that one covers an un-upgraded broker. Neither should have to trust the
-- other to be current.
--
-- Keyed off the config lists rather than off the payload, so a node sending a
-- key we do not know cannot inject it into a table dispatch reads.
-- ---------------------------------------------------------------------------
local function applyHwStock(state, data)
  if type(data) ~= "table" then return end

  if type(data.drones) == "table" then
    for _, key in ipairs(config.droneKeyOrder) do
      state.drones[key] = tonumber(data.drones[key]) or 0
    end
  end

  if type(data.drills) == "table" then
    for _, key in ipairs(drillKeyOrder) do
      local d = data.drills[key]
      -- An absent material is zero of it, not "no opinion". Written out rather
      -- than left nil because every reader does (d and d.kits) or 0 and a nil
      -- would work by accident -- until one of them stopped guarding.
      state.drills[key] = (type(d) == "table")
        and { kits = tonumber(d.kits) or 0,
              tips = tonumber(d.tips) or 0,
              rods = tonumber(d.rods) or 0 }
        or  { kits = 0, tips = 0, rods = 0 }
    end
  end
end

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
    applyHwStock(brokerState, msg.data)
    -- Replaced wholesale, like the stock tables above. The node sends its
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

-- ROW KEYS ARE NUMBERS, NOT STRINGS.
--
-- Every row used to key the cache with SLOT_M + row / SLOT_D + row / SLOT_H + row,
-- built fresh for that row on every frame -- roughly four hundred string
-- allocations a second whose entire job was to index a table and be dropped.
-- The three panels share y values on different parts of the screen, which is why
-- the key has to say which panel; a per-panel numeric base says it just as well
-- and allocates nothing.
local SLOT_M, SLOT_D, SLOT_H = 0, 1000, 2000
local SLOT_SYNC, SLOT_DTAG   = 9001, 9002

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
    dashCache[SLOT_M + y] = nil
    dashCache[SLOT_D + y] = nil
    dashCache[SLOT_H + y] = nil
  end
end

local function dashSetFG(c)
  if dashFG ~= c then gpu.setForeground(c); dashFG = c end
end

-- Write one row of a panel, clearing its column strip first. Indentation is
-- baked into `text` so every row of a panel starts at the same x.
-- CACHE THE INPUTS, NOT A RENDERED KEY.
--
-- This used to build `tostring(color) .. "|" .. text` on every call, for every
-- row, whether or not anything had changed -- two allocations per row per frame
-- purely to ask "is this the same as last time?". Across three panels at
-- uiInterval that was several hundred strings a second whose only purpose was to
-- be compared and dropped.
--
-- Comparing the two values directly costs nothing: Lua interns string literals,
-- so the constant rows (which are most of them) compare by pointer.
--
-- The cache entry is a table that is REUSED rather than replaced, so a settled
-- dashboard allocates nothing at all.
-- Three writers share one cache, so each one stamps EVERY field. Leaving a stale
-- field behind is not cosmetic: a slot blanked and then written would keep
-- `blank = true`, and the next dashBlank would skip a row that currently holds
-- text. Writing all of them costs nothing -- the entry table is reused.
local function dashStamp(e, kind, text, color, fmt, a, b, c, d)
  e.kind, e.text, e.color, e.fmt = kind, text, color, fmt
  e.a, e.b, e.c, e.d = a, b, c, d
end

local function dashRow(slot, x, width, y, text, color)
  local e = dashCache[slot]
  if e and e.kind == "t" and e.text == text and e.color == color then return end
  if not e then e = {}; dashCache[slot] = e end
  dashStamp(e, "t", text, color)
  dashPaints = dashPaints + 1
  gpu.fill(x, y, width, 1, " ")
  dashSetFG(color)
  gpu.set(x, y, text)
end

-- The same, for rows whose text has to be BUILT. The format string and its
-- arguments are compared instead of the result, so string.format runs only when
-- the row has actually changed -- the caller no longer pays to render a row the
-- cache is about to discard.
--
-- Four argument slots covers every row in this file, and every call site is in
-- the three panels below.
local function dashRowF(slot, x, width, y, color, fmt, a, b, c, d)
  local e = dashCache[slot]
  if e and e.kind == "f" and e.color == color and e.fmt == fmt
     and e.a == a and e.b == b and e.c == c and e.d == d then return end
  if not e then e = {}; dashCache[slot] = e end
  dashStamp(e, "f", nil, color, fmt, a, b, c, d)
  dashPaints = dashPaints + 1
  gpu.fill(x, y, width, 1, " ")
  dashSetFG(color)
  gpu.set(x, y, string.format(fmt, a, b, c, d))
end

-- Blank a row: spacers between sections, and the tail wipe under a panel that
-- shrank. Cached too, so a settled layout stops paying for its blank rows.
local function dashBlank(slot, x, width, y)
  local e = dashCache[slot]
  if e and e.kind == "b" then return end
  if not e then e = {}; dashCache[slot] = e end
  dashStamp(e, "b")
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
    -- The format and its arguments are chosen here and rendered by dashRowF
    -- only if the row actually changed. A module sitting in RUNNING repaints
    -- nothing between asteroid changes, and now formats nothing either.
    local fmt, a, b, c, d, color
    if mod.status == "RUNNING" then
      color = 0xFFAA00
      fmt, a, b, c, d = "%sM%d [%-5s]  %s", pin, mod.index, mod.tier, mod.job and mod.job.asteroid or "?"
    elseif mod.status == "LOADING" then
      color = 0xFFFF00
      fmt, a, b, c, d = "%sM%d [%-5s]  LOADING %s", pin, mod.index, mod.tier, mod.job and mod.job.asteroid or ""
    elseif mod.status == "ERROR" then
      color = 0xFF4444
      -- Still built eagerly: only an errored module pays it, and only while the
      -- error stands.
      local errMsg = mod.lastError and (" " .. mod.lastError:sub(1, PW - 20)) or ""
      fmt, a, b, c, d = "%sM%d [%-5s]  ERROR%s", pin, mod.index, mod.tier, errMsg
    else
      color = 0x555555
      if mod.pinnedAsteroid then
        fmt, a, b, c, d = "%sM%d [%-5s]  IDLE (pin: %s)", pin, mod.index, mod.tier, mod.pinnedAsteroid
      else
        fmt, a, b, c = "%sM%d [%-5s]  IDLE", pin, mod.index, mod.tier
        d = nil
      end
    end
    dashRowF(SLOT_M + row, P1 + 1, PW, row, color, fmt, a, b, c, d)
    row = row + 1

    if (mod.status == "RUNNING") and mod.job and row <= H then
      dashRowF(SLOT_M + row, P1 + 1, PW, row, 0xCCCCCC,
        "  dist=%d  drone=%s  refills=%d",
        mod.job.distance or 0, config.droneModel(mod.job.droneKey), mod.refills or 0)
      row = row + 1

      -- Load diagnostic from the most recent load of this module:
      -- "loaded 0.4s  db:1 buf:3" -- time taken + read-back poll counts.
      if mod.lastLoad and row <= H then
        dashRowF(SLOT_M + row, P1 + 1, PW, row, 0x668866, "  %s", mod.lastLoad)
        row = row + 1
      end

      -- Blank spacer line before the next module, per layout.
      if row <= H then
        dashBlank(SLOT_M + row, P1 + 1, PW, row); row = row + 1
      end
    end
  end
  for r = row, H do dashBlank(SLOT_M + r, P1 + 1, PW, r) end
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
    -- "%18s", literally: the old code rebuilt that format string from `tw` on
    -- every frame. Keep the two in step if tw changes.
    dashRow(SLOT_DTAG, tx, tw, 4, string.format("%18s", tag), color)
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
    dashRowF(SLOT_D + row, P2 + 1, PW, row, color,
      "  %s %-27s %3d%%", mark, item.name, pct)
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
    dashRow(SLOT_D + row, P2 + 1, PW, row, detail, stuckOn and 0xFF00FF or 0x666666)
    row = row + 1
  end
  for r = row, H do dashBlank(SLOT_D + r, P2 + 1, PW, r) end
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
    if row <= H then dashRow(SLOT_H + row, P3 + 1, PW, row, text, color) end
    row = row + 1
  end

  -- Same, but the row text is built only if the row changed. Use this wherever
  -- put() would have been handed a string.format or a concatenation; `put` is
  -- for constants, which Lua interns and which therefore cost nothing.
  local function putf(color, fmt, a, b, c, d)
    if row <= H then dashRowF(SLOT_H + row, P3 + 1, PW, row, color, fmt, a, b, c, d) end
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
      if row <= H then dashBlank(SLOT_H + row, P3 + 1, PW, row) end
      row = row + 1
    end
  end

  if brokerState.nextTarget then
    putf(0xFFAA00, "  NEXT: %s", brokerState.nextTarget.asteroid)
  else
    put("  NEXT: (idle)", 0x666666)
  end

  -- Show the cap dispatch actually used, not a fresh guess: it depends on how
  -- many asteroids are currently wanted, which this panel does not recompute.
  putf(0x666666, "  PRIORITY: %s   CAP: %s/asteroid",
       brokerState.priorityMode:upper(), brokerState.cap or asteroidCap(0))

  put("  TELEMETRY SYNC:", 0x666666)
  putf(getSyncColor(brokerState.lastDustSyncTime),  "  Dust:   %s", brokerState.lastDustSync)
  putf(getSyncColor(brokerState.lastFluidSyncTime), "  Fluid:  %s", brokerState.lastFluidSync)
  putf(getSyncColor(brokerState.lastHWSyncTime),    "  HW:     %s", brokerState.lastHWSync)
  -- Outbound par. Grey dashes here mean this broker has never sent DRILL_PAR --
  -- almost always an older broker-mk3.lua, since the send is unconditional.
  -- An explicit "off" rather than a grey zero. Restock disabled and restock
  -- broken look identical on a count alone, and the grey dashes here already
  -- mean a third thing (never sent). Say which one it is.
  if config.drillRestock == false then
    putf(0x888888, "  PAR TX: %s  (auto-craft OFF)", brokerState.lastParSend)
  else
    putf(brokerState.lastParCount > 0 and 0x00FF00 or 0x555555,
         "  PAR TX: %s (%s)", brokerState.lastParSend, brokerState.lastParCount)
  end
  skip(1)

  putf(0x888888, "  TASKS RUNNING: %s", sched.count())
  -- Where module time actually goes. Duty is the share spent mining rather than
  -- loading, returning or waiting for a job -- the number to compare between
  -- runs when output feels off.
  if cycleStats.cycles > 0 then
    local duty = statsDuty()
    -- Lifetime first, then the last few cycles. The pair matters: lifetime says
    -- how the run has gone, recent says how it is going, and reading one as the
    -- other has produced a wrong conclusion here more than once.
    local r = recentStats()
    putf(duty >= 80 and 0x00FF00 or duty >= 60 and 0xFFAA00 or 0xFF4444,
         "  CYCLES: %d   DUTY: %.0f%%%s", cycleStats.cycles, duty,
         r and string.format("   last%d %.0f%%", r.n, r.duty) or "")
    -- Divided by LOADS, not cycles. Dividing load seconds by completed cycles
    -- counted the loads of modules still running against cycles that had
    -- finished, and reported roughly double the real figure -- visibly at odds
    -- with the per-module times on the left of the screen.
    if cycleStats.loads > 0 then
      putf(0x668866, "  LOAD avg %.1fs%s  max %.1fs  (%d)",
           cycleStats.loadTime / cycleStats.loads,
           r and string.format("  last%d %.1fs", r.n, r.load) or "",
           cycleStats.loadMax, cycleStats.loads)
    end
    putf(0x668866, "  REFILLS: %d   %.1f/cycle%s",
         cycleStats.refills or 0, (cycleStats.refills or 0) / cycleStats.cycles,
         r and string.format("   last%d %.1f", r.n, r.refills) or "")
    if (cycleStats.spins or 0) > 0 then
      putf(0x668866, "  SPINUP avg %.1fs  max %.1fs",
           cycleStats.spinTime / cycleStats.spins, cycleStats.spinMax)
    end
    putf(0x666666, "  WAIT idle %.1fs/cyc  return %.1fs/cyc",
         cycleStats.idleTime / cycleStats.cycles,
         cycleStats.doneTime / cycleStats.cycles)
  else
    put("  CYCLES: none completed yet", 0x555555)
  end

  -- What the recipes actually draw. Written outside the cycles branch above on
  -- purpose: demand is real from the first running module, long before any cycle
  -- completes. "pk" is what the computation supply has to cover or a module
  -- stalls mid-recipe; "5m" is what it sustains while mining -- idle intervals
  -- are excluded, see computationSample.
  local cNow, cAvg, cPeak = computationStats()
  putf(0x668866, "  COMP/s now %s   5m %s   pk %s",
       fmtComp(cNow), cAvg and fmtComp(cAvg) or "--", fmtComp(cPeak))
  skip(1)

  -- Plasma stock (required to mine -- a module won't run without a plasma fluid).
  put("  PLASMA STOCK:", 0x888888)
  local anyPlasma = false
  for _, name in ipairs(config.plasmaKeyOrder) do
    local amt = brokerState.plasma[name] or 0
    if row > H then break end
    local short = name:gsub(" Plasma", "")
    putf(amt > 0 and 0xFF00FF or 0x555555, "  %-16s %8d mB", short, amt)
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
    putf(0xFF4444, "  [ %s: %s ]", faultNode, faultWhy:sub(1, PW - 14))
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
    putf(0xFFAA00, "  [ telemetry held over %s scan(s) - node coping ]", held)
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
  -- DECLARED, FREE, AND WHAT THE NETWORK CAN ACTUALLY SEE.
  --
  -- The first two are the ledger: config.droneStock minus what modules are
  -- using. The third is telemetry, and it is here as an AUDIT rather than as an
  -- input -- it can only see the ME network, so a drone in a bus reads as
  -- missing and the two legitimately differ while modules are running.
  --
  -- What it catches is drift: declare ten, own nine, and every cycle one load
  -- fails for a drone that is not there. Without this line that reads as a
  -- hardware fault. With it, the fleet says so.
  local freeDrones = POOL.freeDrones()
  put("  DRONES (declared):", 0x888888)
  local any, declaredTotal, seenTotal = false, 0, 0
  for _, key in ipairs(config.droneKeyOrder) do
    local owned = tonumber((config.droneStock or {})[key]) or 0
    local free  = freeDrones[key] or 0
    declaredTotal = declaredTotal + owned
    seenTotal = seenTotal + (brokerState.drones[key] or 0)
    if owned > 0 then
      if row > H then break end
      -- Amber when nothing is free: the tier is owned but every one of them is
      -- out, which is a different state from not owning one at all.
      local color = (free > 0) and 0x00FFFF or 0xFFAA00
      putf(color, "  %-18s  %d owned  %d free", config.droneModel(key), owned, free)
      any = true
    end
  end
  if not any then
    put("  [ NO DRONES DECLARED ]", 0xFF4444)
    -- Telemetry cannot set this, but it is exactly the right thing to suggest
    -- it: a fresh install otherwise dispatches nothing and says nothing about
    -- why.
    if seenTotal > 0 then
      putf(0xFFAA00, "  network sees %d -- set them on the HARDWARE page (E)", seenTotal)
    end
  end

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
      if free ~= kits then
        putf(0x00AAFF, "  %-18s  x%d  (%d free)", name, kits, free)
      else
        putf(0x00AAFF, "  %-18s  x%d", name, kits)
      end
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
        putf(0xFFAA00, "  %-24s x%d", short:sub(1, 24), want)
      elseif state == "queued" then
        -- Not a problem: below par, waiting on a crafting CPU. Dim so it reads
        -- as backlog rather than as another thing demanding attention.
        putf(0x555555, "  %-24s queued x%d", short:sub(1, 24), want)
      else
        putf(0xFF4444, "  %-24s %s", short:sub(1, 24),
             state == "nopattern" and "NO PATTERN" or "REJECTED")
      end
    end
  end

  for r = row, H do dashBlank(SLOT_H + r, P3 + 1, PW, r) end
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
  -- Keyed on the integer second, so os.date and the concatenation run once a
  -- second rather than on all ten frames within it.
  dashRowF(SLOT_SYNC, W - 17, 17, 2, 0x555555, "SYNC: %s",
    os.date("%H:%M:%S", math.floor(getUnixTime())))
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

  -- gtVersion is NOT asked here, deliberately. It is a stored setting, it lives
  -- on the editor's COMPATIBILITY page, and it changes when you upgrade the pack
  -- -- which is to say almost never. Prompting for it would ask every boot for a
  -- value that is already saved, and hand back the saved value as the default.
  --
  -- Getting it wrong is not silent: initModules() compares every module's actual
  -- dialect against it and says so, by name, on the console. That is strictly
  -- better than a prompt, because it tells you the answer instead of asking you
  -- for it. Priority mode is asked because it is a genuine per-session choice.
  logger:info("[STARTUP] priority mode = " .. brokerState.priorityMode)
  -- The whole label, not just the marker. 2.8 differs from 2.9 in two ways --
  -- marker case AND whether the voltage is in the name -- so a line reading
  -- only "MK-" cannot tell a right guess from a wrong one, which is exactly how
  -- a 2.8 world sat there resolving no drones at all.
  logger:info("[STARTUP] GTNH " .. tostring(config.gtVersion) ..
              " -- drones named \"" .. tostring(config.drones.uhv) .. "\"")
  if gpu then gpu.setForeground(0x00FF00) end
  print("\n  Priority: " .. brokerState.priorityMode:upper() ..
        ".  GTNH " .. tostring(config.gtVersion) .. ".  Starting broker...")
  if gpu then gpu.setForeground(0xFFFFFF) end
  os.sleep(1)
end

-- Disable and clear every module's interface, and settle which GTNH parameter
-- API each one speaks. Shows live progress in the MODULES panel so boot feels
-- responsive instead of staring at a blank console while ~24 component calls
-- run. Cheap work; this is purely about feedback.
--
-- The dialect is settled HERE, once, rather than at every start: it is a
-- property of the pack the world is running and it cannot change while the
-- broker is up. It comes from the gtVersion setting now rather than from a
-- probe -- see module_api.lua for why an item label forced that -- so this pass
-- is really about checking the hardware agrees, and about the interface clear.
local function initModules()
  logger:info("[STARTUP] Initializing " .. #modules .. " modules...")
  local anyLegacy = false
  local anyMismatch = nil
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
      logger:info("[STARTUP] M%d speaks %s", mod.index, moduleApi.describe(mod))
      -- The probe does not decide any more, but it still knows. Comparing it
      -- against the parameter API the setting implies -- not against the setting
      -- itself, which is a different string on 2.9-pre-b3 -- is the ONLY chance
      -- to catch a wrong gtVersion before a job runs: without it a module loads a
      -- drone,
      -- a stack of tips and a stack of rods, and only then throws on a
      -- parameter call that does not exist. Warn, do not fail -- a forced
      -- setting beating a misreading probe is exactly why the setting exists.
      local mismatch = moduleApi.check(mod.adapter, config.gtVersion)
      if mismatch then
        anyMismatch = anyMismatch or mismatch
        logger:warn("[STARTUP] M" .. mod.index .. " " .. mismatch)
      end
    elseif moduleApi.detect(mod.adapter) then
      -- The adapter is a mining module, but gtVersion names a version this
      -- build does not know. Nothing downstream can run against that.
      mod.status = "ERROR"
      mod.lastError = "unknown gtVersion: " .. tostring(config.gtVersion)
      logger:error("[STARTUP] M" .. mod.index .. " " .. mod.lastError)
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

      -- AND THE BUS IS LAST RUN'S STATE TOO.
      --
      -- This used to be left alone, and a module that was mining when the
      -- broker went down kept its drone in bus slot 1 -- physically outside the
      -- ME network, so hw_telem truthfully reported none, and every module in
      -- the fleet was dispatched an LV because the model did not know ten LuV
      -- existed. The loads then pushed those drones back one by one, after the
      -- jobs were already committed.
      --
      -- Emptied, not inspected. A previous version read the bus first so a
      -- recovered drone could be stamped as in flight -- needed only while the
      -- pool came from telemetry and a drone outside the network read as gone.
      -- The declared fleet counts it wherever it is, so putting it back is the
      -- whole job.
      returnItemsToME(mod)
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

  -- An undeclared fleet dispatches nothing at all, and the dashboard panel is
  -- the only other place that says so. Say it at boot too, where someone who
  -- just upgraded into this change is actually looking.
  local declared = 0
  for _, n in pairs(config.droneStock or {}) do declared = declared + (tonumber(n) or 0) end
  if declared == 0 then
    local line = "No drones declared -- nothing will dispatch. Set how many you own on " ..
                 "the editor's HARDWARE page (press E). Drone counts are configured now " ..
                 "rather than read from the hw node, which can only see the ME network."
    logger:warn("[STARTUP] " .. line)
    print(line)
  end

  -- Loud, because the drone labels are wrong too when this fires and the only
  -- other symptom is every tier reading zero in stock -- which looks like an
  -- empty network, not a misconfiguration.
  if anyMismatch then
    print("WARNING: " .. anyMismatch)
    print("         Drone item names are picked from the same setting, so stock")
    print("         will read 0 for every tier until it matches the world.")
  end
end

-- =============================================================================
-- WIRE UP THE EDITOR
--
-- Here, not at the dofile above, because every one of these has to exist first
-- -- drawStaticFrame is the last of them. The editor holds no hardware handles
-- of its own and reaches for no globals; this list IS its entire coupling to
-- the broker, which is what keeps it loadable under desktop Lua for the tests.
--
-- edGen is passed as a function and edTouch as itself: the counter is the
-- broker's (the dust panel caches against it too) and a plain number would go
-- stale the moment it was copied.
-- =============================================================================
editor.init{
  config          = config,
  gpu             = gpu,
  W               = W,
  H               = H,
  brokerState     = brokerState,
  drillKeyOrder   = drillKeyOrder,
  usableDrillKeys = usableDrillKeys,
  formatQty       = formatQty,
  drawStaticFrame = drawStaticFrame,
  -- Closures rather than new top-level locals: this file has spent this whole
  -- refactor getting back under the 200 ceiling.
  resetDustScroll = function() dustScroll = 0 end,
  edTouch         = edTouch,
  edGen           = function() return edGen end,
}

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
    -- droneMark and droneSuffix ride along for the same reason drillCraftSlots
    -- does: the node holds no config.lua, so it cannot turn a version into an
    -- item name. It keeps its own default until this arrives, so an older
    -- broker that sends neither costs nothing.
    --
    -- Two scalars rather than the fourteen labels themselves. The node already
    -- holds the roman-and-voltage table -- it needs it to draw its own fleet
    -- column -- so shipping the labels would put a second copy on the wire
    -- every thirty seconds to say what four bytes already say.
    data        = { par = list, slots = config.drillCraftSlots or 1,
                    enabled = enabled, droneMark = config.droneMark,
                    droneSuffix = config.droneSuffix },
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
  -- Destructured, not collected into a table. This loop spins about a hundred
  -- times a second and `{ event.pull(...) }` allocated a fresh table on every one
  -- of those, almost always to look at element 1 and throw the rest away.
  -- event.pull returns at most six values for the signals this program sees.
  local e1, e2, e3, e4, e5, e6 = event.pull(0.01)
  if e1 == "modem_message" then
    processMessage(e1, e2, e3, e4, e5, e6)
    -- Only DUST_UPDATE can move anything the editor shows (the HAVE column).
    -- HW_UPDATE and FLUID_UPDATE used to force a full repaint too, several times
    -- a minute, for a screen whose contents they cannot affect. Even for dust,
    -- do not repaint here: the 2s tick below already refreshes it, and stock
    -- figures do not need sub-second latency. Keypresses still repaint at once.

  elseif editor.isOpen() then
    -- The editor owns input while it is up, but ONLY input. Execution still
    -- falls through to sched.tick() and stepModules() below, so loads in flight
    -- keep progressing while someone edits. That is the whole reason this is a
    -- UI mode rather than a separate blocking program.
    --
    -- The one place that still wants a table -- edHandle indexes it. Built only
    -- on this branch, which is not the hot path: dispatch is suspended for as
    -- long as the editor is up.
    editor.handle({ e1, e2, e3, e4, e5, e6 })

  elseif e1 == "scroll" then
    -- signal = "scroll", screenAddr, x, y, direction, player
    local sx, dir = e3, e5
    if sx and dir and sx >= P2 and sx < P3 then
      dustScroll = dustScroll - dir * 2   -- clamped in drawDustPanel
      lastUIDraw = 0                      -- repaint now, do not wait for the tick
    end

  elseif e1 == "key_down" and e3 == 101 and not edPending then  -- "e"
    -- Do not open yet: start quiescing. See QUIESCING above.
    local up = computer.uptime()
    edPending = { openAt = up + config.quiesceSeconds,
                  hardAt = up + config.quiesceSeconds + config.quiesceGrace }
    edPendingShown = nil

  elseif e1 == "key_down" and edPending
     and editor.isCancelKey(e3, e4) then
    -- Aborting the countdown. Asked of the editor rather than tested here, so
    -- this cannot drift from EDKEYS -- which is how "esc" outlived the key
    -- working. Without tab and q this box could not be cancelled at all.
    edPending, edPendingShown = nil, nil
    lastUIDraw = 0   -- wipe the box on the next pass
  end

  -- Countdown, and the handover into the editor.
  if edPending then
    local up = computer.uptime()
    local busy = modulesBusy()
    if up >= edPending.openAt and (busy == 0 or up >= edPending.hardAt) then
      edPending, edPendingShown = nil, nil
      -- The editor drops the row cache and says why it opened; both of those
      -- are its business, not this loop's.
      editor.open(busy)
    end
  end

  -- A save inside the editor rewrites config.conditions and applies it live, so
  -- push the new watchlist immediately rather than waiting out the 30s cadence.
  local wantWatchlist, wantPar, wantNodes = editor.takeRequests()
  if wantWatchlist then
    broadcastWatchlist()
    lastWatchlistSend = computer.uptime()
  end

  -- Same for drill par. Separate flag rather than folded into the one above,
  -- because edSave sets both and this is the only place broadcastDrillPar is in
  -- scope -- it is defined below the editor. Without it a par change waited out
  -- the 30s cadence, which reads as the edit not having taken.
  if wantPar then
    broadcastDrillPar()
  end

  if wantNodes then
    broadcastNodeSettings()
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

  if editor.isOpen() then
    -- Event-driven: repaint when the editor changed, plus a slow tick so live
    -- HAVE values from telemetry still refresh. Repainting a full-screen list
    -- four times a second was the other half of the flicker.
    if editor.needsRepaint() or (up - lastUIDraw >= 2.0) then
      editor.draw()
      editor.clearRepaint()
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
    -- Back to a plain first-sweep test. This briefly compared the hw sweep
    -- against when initModules emptied the buses, because dispatching before a
    -- sweep had seen the returned drones handed every module the weakest drone
    -- in stock. Drones do not come from a sweep any more; kits still do, and one
    -- sweep is all that needs waiting for.
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
  if brokerState.telemetryReady and not editor.isOpen() and not edPending
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
