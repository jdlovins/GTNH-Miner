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
-- Requires: /home/scheduler.lua, /home/loader.lua,
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

local loggingModule = dofile("/home/logger.lua")
assert(loggingModule and loggingModule.createLogger, "logger.lua not loaded")
local logger = loggingModule.createLogger("broker-mk3")
local getUnixTime = loggingModule.getCurrentTimestamp

logger:info("========== BROKER-MK3 (v1.5) STARTUP ==========")

-- Surface task crashes in the log instead of swallowing them.
-- CRITICAL: also set loadResult so the module doesn't get stuck in LOADING forever.
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
-- HARDWARE VALIDATION
-- =============================================================================

if not component.isAvailable("modem") then error("Missing network card.") end
local modem = component.modem
if not modem.isWireless or not modem.isWireless() then
  error("Requires a T2 Wireless Network Card.")
end
modem.setStrength(400)
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
  }
end

-- (Modules are disabled/cleared after the dashboard frame is drawn, so boot
--  shows progress instead of a blank console. See initModules() below.)

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
  jobs = {},
  cooldowns = {},
  lastDustSyncTime = 0,
  lastFluidSyncTime = 0,
  lastHWSyncTime = 0,
  lastDustSync = "--:--:--",
  lastFluidSync = "--:--:--",
  lastHWSync = "--:--:--",
  nextTarget = nil,
  telemetryReady = false,
  priorityMode = "threshold", -- "threshold" (lowest fill first) | "rarity" (dust priority first)
}

local drillKeyOrder = {
  "steel", "titanium", "tungstensteel", "naquadah",
  "naquadahAlloy", "neutronium", "cosmicNeutronium", "infinity", "transcendentMetal"
}

for _, cond in ipairs(config.conditions) do
  brokerState.dust[cond.itemName] = { stock = 0, threshold = cond.amountToMaintain }
end
for _, name in ipairs(config.plasmaKeyOrder) do brokerState.plasma[name] = 0 end
for _, key in ipairs(config.droneKeyOrder) do brokerState.drones[key] = 0 end
for _, key in ipairs(drillKeyOrder) do brokerState.drills[key] = { kits = 0, tips = 0, rods = 0 } end

-- UI layout (three panels).
local W, H = gpu and gpu.maxResolution() or 120, 50
if gpu then gpu.setResolution(W, H) end
local P1 = 1
local P2 = math.floor(W / 3) + 1
local P3 = math.floor(W * 2 / 3) + 1
local PW = P2 - 2

-- Dust panel scroll offset (index into the sorted list, 0 = top). Each entry
-- occupies two rows, so a full condition list runs off the bottom long before
-- it is fully shown; without this the overflow was simply invisible.
local dustScroll = 0

local DISPATCH_INTERVAL = 0.2
local lastDispatchCheck = 0
local ERROR_TIMEOUT = 10
local lastErrorTime = {}

-- RUNNING watchdog tuning (real seconds via computer.uptime).
-- Require brief startup grace plus repeated inactive polls before DONE.
local RUN_STARTUP_GRACE = 3.0
local RUN_POLL_INTERVAL = 0.5
local RUN_INACTIVE_CONFIRM = 3
local RUN_HEARTBEAT_INTERVAL = 120
local RUN_WARN_COOLDOWN = 60

-- Pinned modules keep their input bus topped up on this interval (real seconds)
-- so they never run dry and bounce through DONE/reload.
local PIN_RESTOCK_INTERVAL = 3.0

-- =============================================================================
-- MODULE LIFECYCLE
-- =============================================================================

local function returnItemsToME(mod)
  local busSize = mod.transposer.getInventorySize(mod.conf.inputBusSide) or 16
  for slot = 1, busSize do
    local size = mod.transposer.getSlotStackSize(mod.conf.inputBusSide, slot) or 0
    if size > 0 then
      mod.transposer.transferItem(mod.conf.inputBusSide, mod.conf.interfaceSide, size, slot)
    end
  end
end

local function clearInterfaceSlots(mod)
  mod.iface.setInterfaceConfiguration(1)
  mod.iface.setInterfaceConfiguration(2)
  mod.iface.setInterfaceConfiguration(3)
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
    -- Compact on-screen diagnostic: time to load + read-back poll counts.
    -- "db" = max polls any fingerprint needed (low => store() reliable here),
    -- "buf" = polls waiting for items to arrive in the interface buffer.
    local maxConfirm = math.max(cp.drone or 0, cp.tip or 0, cp.rod or 0)
    mod.lastLoad = string.format("loaded %.1fs  db:%d buf:%d", elapsed, maxConfirm, s.arrivePolls or 0)
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
    mod.job.startTime = os.time()
    logger:info(string.format(
      "[HEALTH] M%d started asteroid=%s dist=%s x%s",
      mod.index,
      tostring(mod.job and mod.job.asteroid or "?"),
      tostring(mod.job and mod.job.distance or "?"),
      tostring(mod.job and mod.job.parallels or "?")))
    -- GTNH 2.9: set all required named parameters before enabling.
    -- Keys confirmed live via getParameters() on an MK-II:
    --   cycle (bool), cycleDistance, distance, parallel, range, step
    -- "cycle=false" pins a static distance; with cycle on, the module sweeps
    -- between distance-range and distance+range and getOptimalDistance's choice
    -- stops meaning anything.
    --
    -- pcall is deliberate and not upstream's: a nil setParameter is exactly what
    -- took this broker down before, and a crash in pollLoad kills all six
    -- modules. On failure this one goes ERROR and the rest keep mining.
    local okParams, paramErr = pcall(function()
      mod.adapter.setParameter("distance", mod.job.distance)
      mod.adapter.setParameter("parallel", mod.job.parallels or 1)
      mod.adapter.setParameter("cycle", false)
    end)
    if not okParams then
      mod.status = "ERROR"
      mod.lastError = "setParameter: " .. tostring(paramErr)
      logger:error("[LOAD] M" .. mod.index .. " setParameter failed: " .. tostring(paramErr))
      return
    end

    mod.adapter.setWorkAllowed(true)
  else
    mod.status = "ERROR"
    mod.lastError = tostring(r.err)
    logger:error("[LOAD] M" .. mod.index .. " failed: " .. tostring(r.err))
  end
end

-- Top a pinned module's input bus back up to full while it runs. Reuses the db
-- fingerprints written by the initial load (still valid — we never cleared those
-- slots), so the interface can restock tips/rods by identity. Runs as a task, so
-- it yields while waiting for items to arrive and never blocks the main loop.
local function restockPinned(mod)
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
  local function busTotal(label)
    local total, firstSlot = 0, nil
    for s = 1, busSize do
      local st = mod.transposer.getStackInSlot(mod.conf.inputBusSide, s)
      if st and st.label == label then
        total = total + (st.size or 0)
        firstSlot = firstSlot or s
      end
    end
    return total, firstSlot
  end

  local function findBuf(label)
    for s = 1, ibufSize do
      local stack = mod.transposer.getStackInSlot(mod.conf.interfaceSide, s)
      if stack and stack.label == label then return s, stack.size or 0 end
    end
    return nil, 0
  end

  -- Refill one consumable in the bus back up to `target` from the ME interface.
  local function refill(label, target, cfgSlot, dbSlot)
    if mod.status ~= "RUNNING" then return end
    local have, slot = busTotal(label)
    local deficit = target - have
    if deficit <= 0 then return end
    slot = slot or cfgSlot
    mod.iface.setInterfaceConfiguration(cfgSlot, dbAddr, dbSlot, target)
    sched.await(function() return (select(1, findBuf(label))) ~= nil end, 5, 0.2)
    if mod.status ~= "RUNNING" then
      mod.iface.setInterfaceConfiguration(cfgSlot)
      return
    end
    local src = select(1, findBuf(label))
    if src then
      mod.transposer.transferItem(mod.conf.interfaceSide, mod.conf.inputBusSide, deficit, src, slot)
    end
    mod.iface.setInterfaceConfiguration(cfgSlot) -- stop hoarding the buffer between refills
  end

  refill(drill.tip, TIPS_PER, 2, slotTip)
  refill(drill.rod, RODS_PER, 3, slotRod)
end

local function stepRunning(mod)
  local now = computer.uptime()

  -- Pinned modules: keep the input bus continuously topped up so they never run
  -- dry (and never cycle through DONE -> return -> IDLE -> reload). We fire a
  -- short cooperative task on an interval that refills tips/rods from the ME via
  -- the interface + transposer. The drone (bus slot 1) isn't consumed, so only
  -- tips (slot 2) and rods (slot 3) are refreshed.
  if mod.pinnedAsteroid and mod.job then
    if (not mod.restockHandle or mod.restockHandle.done()) and now >= (mod.nextRestockAt or 0) then
      mod.nextRestockAt = now + PIN_RESTOCK_INTERVAL
      mod.restockHandle = sched.spawn(function()
        local ok, err = pcall(restockPinned, mod)
        if not ok then logger:warn("[PIN] M" .. mod.index .. " restock error: " .. tostring(err)) end
      end, "restock-M" .. mod.index)
    end
  end

  if mod.runStartedAt and (now - mod.runStartedAt) < RUN_STARTUP_GRACE then
    return
  end

  if (now - (mod.lastRunPollAt or 0)) < RUN_POLL_INTERVAL then
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
  mod.status = "DONE"
  mod.adapter.setWorkAllowed(false)
end

local function stepDone(mod)
  if not mod.doneTime then
    mod.doneTime = os.time()
    returnItemsToME(mod)
    clearInterfaceSlots(mod)
    mod.adapter.setWorkAllowed(false)
  elseif os.time() - mod.doneTime >= 1 then
    if mod.job and brokerState.jobs[mod.job.jobId] then
      brokerState.jobs[mod.job.jobId] = nil
    end
    mod.job = nil
    mod.status = "IDLE"
    mod.doneTime = nil
    mod.runStartedAt = nil
    mod.lastRunPollAt = 0
    mod.inactiveStreak = 0
    mod.inactiveSinceAt = nil
    mod.nextHeartbeatAt = 0
    mod.lastRunWarnAt = 0
    lastDispatchCheck = os.time() - DISPATCH_INTERVAL
  end
end

local function stepModules()
  for _, mod in ipairs(modules) do
    if mod.status == "LOADING" then
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
  local now = os.time()
  for jobId, job in pairs(brokerState.jobs) do
    if now - job.startTime > 300 then brokerState.jobs[jobId] = nil end
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

local function getIdleModules()
  local idle = {}
  local now = os.time()
  for i, mod in ipairs(modules) do
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
  return idle
end

local function tryDispatch(mod, asteroid, droneKey)
  local asteroidData = config.asteroids[asteroid]
  if not asteroidData then return false end
  if not droneKey or (brokerState.drones[droneKey] or 0) <= 0 then return false end

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

  -- Don't dispatch if we don't have enough drill kits for a full load.
  -- The loader needs config.tipsPerLoad tips + config.rodsPerLoad rods per module.
  local drill = brokerState.drills[drillKey]
  local minKits = math.max(config.tipsPerLoad or 64, config.rodsPerLoad or 64)
  if not drill or (drill.kits or 0) < minKits then return false end

  local jobId = nodeId .. "-" .. os.time() .. "-M" .. mod.index
  mod.status = "LOADING"
  mod.job = {
    jobId = jobId,
    asteroid = asteroid,
    droneKey = droneKey,
    drillKey = drillKey,
    distance = getOptimalDistance(mod.tier, asteroid, droneKey),
    parallels = config.moduleTiers[mod.tier].maxParallels,
    startTime = os.time(),
  }
  brokerState.jobs[jobId] = { moduleIndex = mod.index, asteroid = asteroid, startTime = os.time() }
  brokerState.nextTarget = { asteroid = asteroid, reason = "dispatched" }

  beginLoad(mod) -- non-blocking: spawns the cooperative load task
  return true
end

-- How many of each drone are actually free to assign right now?
-- = telemetry stock  -  drones already committed to non-idle modules.
-- Telemetry lags (HW_UPDATE every 10s), so a drone we assigned 2s ago may still
-- show "in stock". Subtracting in-flight commitments prevents handing the same
-- physical drone to multiple modules — the bug that caused "Infinity Catalyst
-- everywhere" when only one high-tier drone existed.
local function availableDrones()
  local avail = {}
  for key, count in pairs(brokerState.drones) do avail[key] = count end
  for _, mod in ipairs(modules) do
    if mod.status ~= "IDLE" and mod.job and mod.job.droneKey then
      local k = mod.job.droneKey
      avail[k] = (avail[k] or 0) - 1
    end
  end
  return avail
end

-- Same idea for drill kits: stock minus kits already committed to busy modules.
local function availableKits()
  local avail = {}
  for key, d in pairs(brokerState.drills) do avail[key] = (d and d.kits) or 0 end
  for _, mod in ipairs(modules) do
    if mod.status ~= "IDLE" and mod.job and mod.job.drillKey then
      local k = mod.job.drillKey
      avail[k] = (avail[k] or 0) - 1
    end
  end
  return avail
end

-- Per-asteroid module cap: an asteroid may hold at most "half the modules plus
-- one" at once, so a single high-tier target (e.g. Infinity Catalyst) can take a
-- majority but never starve every other need. Scales with total module count, so
-- it stays correct if this broker grows back into a multi-job-node fleet (up to
-- 24 modules across multiple space elevators, like v1.0).
local function asteroidCap()
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
          if tryDispatch(mod, asteroid, droneKey) then
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

local function dispatchBatch()
  pruneStaleJobs()

  -- No plasma = modules can't run. Hold dispatch until some is in stock.
  if not hasPlasma() then return end

  local idleModules = getIdleModules()
  if #idleModules == 0 then return end

  -- Working pools we can still hand out this batch: drones and drill kits.
  local avail          = availableDrones()
  local availKit       = availableKits()
  local minKitsForLoad = math.max(config.tipsPerLoad or 64, config.rodsPerLoad or 64)

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

  local needs = findNeedsList()
  if #needs == 0 then return end

  local neededAsteroids = {}
  for _, need in ipairs(needs) do neededAsteroids[need.asteroid] = need end

  -- Per-asteroid usage: start from what's already committed (including pinned
  -- modules dispatched just above), count up as we go, and never exceed the cap.
  -- This is what frees module slots for lower-tier needs (e.g. Uranium-Plutonium)
  -- instead of one asteroid eating them all.
  local cap            = asteroidCap()
  local astCount       = activeAsteroidCounts()

  for _, droneKey in ipairs(config.droneKeyOrder) do
    if (avail[droneKey] or 0) > 0 then
      local droneTier = config.droneTierKeys[droneKey]
      local drillKey  = config.droneDrillMap[droneTier]

      -- Need both a free drone AND enough kits for a full load.
      if drillKey and (availKit[drillKey] or 0) >= minKitsForLoad then
        for asteroidName, asteroidData in pairs(config.asteroids) do
          -- Stop scanning once we've exhausted this drone or its kits.
          if (avail[droneKey] or 0) <= 0 or (availKit[drillKey] or 0) < minKitsForLoad then break end
          if droneTier >= asteroidData.minDrone and droneTier <= asteroidData.maxDrone then
            -- Eligible if it's a current need AND under its module cap.
            if neededAsteroids[asteroidName] and (astCount[asteroidName] or 0) < cap then
              local assigned = false
              for idx = #pool, 1, -1 do
                local mod = pool[idx]
                if tryDispatch(mod, asteroidName, droneKey) then
                  astCount[asteroidName] = (astCount[asteroidName] or 0) + 1
                  avail[droneKey]        = avail[droneKey] - 1                 -- consume a drone
                  availKit[drillKey]     = availKit[drillKey] - minKitsForLoad -- consume kits for this load
                  table.remove(pool, idx)
                  assigned = true
                  break
                end
              end
              if assigned and #pool == 0 then return end
            end
          end
        end
      end
    end
  end
end

-- =============================================================================
-- TELEMETRY
-- =============================================================================

local function processMessage(evType, _, _, _, _, rawMsg)
  if evType ~= "modem_message" then return end
  local ok, msg = pcall(serial.unserialize, rawMsg)
  if not ok or type(msg) ~= "table" then return end
  if msg.protocol ~= "MEDINA_TELEMETRY" or not msg.data then return end

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
    brokerState.lastDustSyncTime = os.time()
    brokerState.lastDustSync = os.date("%X")
  elseif msg.payloadType == "FLUID_UPDATE" and msg.data.plasmas then
    for name, amount in pairs(msg.data.plasmas) do
      if brokerState.plasma[name] ~= nil then brokerState.plasma[name] = amount end
    end
    brokerState.lastFluidSyncTime = os.time()
    brokerState.lastFluidSync = os.date("%X")
  elseif msg.payloadType == "HW_UPDATE" then
    if msg.data.drones then for k, v in pairs(msg.data.drones) do brokerState.drones[k] = v end end
    if msg.data.drills then for k, v in pairs(msg.data.drills) do brokerState.drills[k] = v end end
    -- Replaced wholesale, not merged like the two above. The node sends its
    -- complete set of outstanding orders every cycle, so assignment is what
    -- lets a resolved entry clear itself -- merging would pin a "nopattern"
    -- warning on screen forever after you added the pattern.
    brokerState.crafting = (type(msg.data.crafting) == "table") and msg.data.crafting or {}
    brokerState.lastHWSyncTime = os.time()
    brokerState.lastHWSync = os.date("%X")
  end
end

-- =============================================================================
-- UI
-- =============================================================================

local function getSyncColor(t)
  if not t or t == 0 then return 0x555555 end
  local ago = (os.time() - t) / 20
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

local function drawModulePanel()
  local row = 6
  local function clear(r) gpu.fill(P1 + 1, r, PW, 1, " ") end
  -- No full-column pre-wipe here. Every row below clears itself before it is
  -- written, and the tail wipe at the end of this function blanks whatever
  -- rows the layout vacated -- so ghosts are already impossible. Blanking the
  -- whole column up front only added a visible blank frame between the wipe
  -- and the repaint, four times a second: that was the flicker.
  for _, mod in ipairs(modules) do
    if row > H then break end
    clear(row); term.setCursor(P1 + 1, row)
    -- Pinned/reserved modules get a "*" marker so it's clear at a glance which
    -- ones are locked to a single asteroid. Same width as the normal "  " prefix.
    local pin = mod.pinnedAsteroid and " *" or "  "
    if mod.status == "RUNNING" then
      gpu.setForeground(0xFFAA00)
      io.write(string.format("%sM%d [%-5s]  %s", pin, mod.index, mod.tier, mod.job and mod.job.asteroid or "?"))
    elseif mod.status == "LOADING" then
      gpu.setForeground(0xFFFF00)
      io.write(string.format("%sM%d [%-5s]  LOADING %s", pin, mod.index, mod.tier, mod.job and mod.job.asteroid or ""))
    elseif mod.status == "ERROR" then
      gpu.setForeground(0xFF4444)
      local errMsg = mod.lastError and (" " .. mod.lastError:sub(1, PW - 20)) or ""
      io.write(string.format("%sM%d [%-5s]  ERROR%s", pin, mod.index, mod.tier, errMsg))
    else
      gpu.setForeground(0x555555)
      if mod.pinnedAsteroid then
        io.write(string.format("%sM%d [%-5s]  IDLE (pin: %s)", pin, mod.index, mod.tier, mod.pinnedAsteroid))
      else
        io.write(string.format("%sM%d [%-5s]  IDLE", pin, mod.index, mod.tier))
      end
    end
    row = row + 1
    if (mod.status == "RUNNING") and mod.job and row <= H then
      clear(row); term.setCursor(P1 + 3, row)
      gpu.setForeground(0xCCCCCC)
      local droneName = config.drones[mod.job.droneKey] or "?"
      local lvl = droneName:match("MK%-(.+)") or "?"
      io.write(string.format("dist=%d  drone=MK-%s", mod.job.distance or 0, lvl))
      row = row + 1

      -- Load diagnostic from the most recent load of this module:
      -- "loaded 0.4s  db:1 buf:3" — time taken + read-back poll counts.
      if mod.lastLoad and row <= H then
        clear(row); term.setCursor(P1 + 3, row)
        gpu.setForeground(0x668866) -- dim green: informational
        io.write(mod.lastLoad)
        row = row + 1
      end

      -- Blank spacer line before the next module, per layout.
      if row <= H then
        clear(row); row = row + 1
      end
    end
  end
  for r = row, H do gpu.fill(P1 + 1, r, PW, 1, " ") end
end

local function drawDustPanel()
  local row = 6
  -- No full-column pre-wipe here. Every row below clears itself before it is
  -- written, and the tail wipe at the end of this function blanks whatever
  -- rows the layout vacated -- so ghosts are already impossible. Blanking the
  -- whole column up front only added a visible blank frame between the wipe
  -- and the repaint, four times a second: that was the flicker.
  local list = {}
  for _, cond in ipairs(config.conditions) do
    local name      = cond.itemName
    local stock     = (brokerState.dust[name] and brokerState.dust[name].stock) or 0
    local ratio     = stock / cond.amountToMaintain
    list[#list + 1] = { name = name, stock = stock, threshold = cond.amountToMaintain, ratio = ratio }
  end
  table.sort(list, function(a, b) return a.ratio < b.ratio end)

  -- Two rows per entry, so this is how many entries actually fit.
  local capacity  = math.floor((H - row + 1) / 2)
  local maxScroll = math.max(0, #list - capacity)
  if dustScroll > maxScroll then dustScroll = maxScroll end
  if dustScroll < 0 then dustScroll = 0 end

  -- Range indicator in the panel header, so a truncated list is obvious rather
  -- than looking like the whole list.
  if #list > 0 then
    local tag = string.format("%d-%d/%d",
      math.min(dustScroll + 1, #list), math.min(dustScroll + capacity, #list), #list)
    if maxScroll > 0 then tag = tag .. " ^v" end
    local tx = P3 - #tag - 1
    gpu.fill(tx, 4, #tag + 1, 1, " ")
    gpu.setForeground(maxScroll > 0 and 0xFFAA00 or 0x888888)
    term.setCursor(tx, 4)
    io.write(tag)
  end

  for i = dustScroll + 1, #list do
    local item = list[i]
    if row > H then break end
    gpu.fill(P2 + 1, row, PW, 1, " "); term.setCursor(P2 + 1, row)
    local pct = math.floor(item.ratio * 100)
    local color = (item.ratio >= 1.0) and 0x446644 or (item.ratio < 0.25) and 0xFF4444
        or (item.ratio < 0.75) and 0xFFAA00 or 0x00FFFF
    local mark = item.ratio < 1.0 and "!" or " "
    gpu.setForeground(color)
    io.write(string.format("  %s %-27s %3d%%", mark, item.name, pct))
    row = row + 1
    if row > H then break end
    gpu.fill(P2 + 1, row, PW, 1, " "); term.setCursor(P2 + 1, row)
    gpu.setForeground(0x666666)
    io.write(string.format("      %s / %s", formatQty(item.stock), formatQty(item.threshold)))
    row = row + 1
  end
  for r = row, H do gpu.fill(P2 + 1, r, PW, 1, " ") end
end

local function drawHWPanel()
  local row = 6
  local function clear(r) gpu.fill(P3 + 1, r, PW, 1, " ") end

  -- No full-column pre-wipe here. Every row below clears itself before it is
  -- written, and the tail wipe at the end of this function blanks whatever
  -- rows the layout vacated -- so ghosts are already impossible. Blanking the
  -- whole column up front only added a visible blank frame between the wipe
  -- and the repaint, four times a second: that was the flicker.

  clear(row); term.setCursor(P3 + 1, row)
  if brokerState.nextTarget then
    gpu.setForeground(0xFFAA00)
    io.write("  NEXT: " .. brokerState.nextTarget.asteroid)
  else
    gpu.setForeground(0x666666); io.write("  NEXT: (idle)")
  end
  row = row + 1

  clear(row); term.setCursor(P3 + 1, row)
  gpu.setForeground(0x666666)
  io.write("  PRIORITY: " .. brokerState.priorityMode:upper() .. "   CAP: " .. asteroidCap() .. "/asteroid")
  row = row + 1

  clear(row); term.setCursor(P3 + 1, row)
  gpu.setForeground(0x666666); io.write("  TELEMETRY SYNC:")
  row = row + 1
  clear(row); term.setCursor(P3 + 1, row)
  gpu.setForeground(getSyncColor(brokerState.lastDustSyncTime)); io.write("  Dust:   " .. brokerState.lastDustSync)
  row = row + 1
  clear(row); term.setCursor(P3 + 1, row)
  gpu.setForeground(getSyncColor(brokerState.lastFluidSyncTime)); io.write("  Fluid:  " .. brokerState.lastFluidSync)
  row = row + 1
  clear(row); term.setCursor(P3 + 1, row)
  gpu.setForeground(getSyncColor(brokerState.lastHWSyncTime)); io.write("  HW:     " .. brokerState.lastHWSync)
  row = row + 2

  clear(row); term.setCursor(P3 + 1, row)
  gpu.setForeground(0x888888); io.write("  TASKS RUNNING: " .. sched.count())
  row = row + 2

  -- Plasma stock (required to mine — a module won't run without a plasma fluid).
  clear(row); term.setCursor(P3 + 1, row)
  gpu.setForeground(0x888888); io.write("  PLASMA STOCK:")
  row = row + 1
  local anyPlasma = false
  for _, name in ipairs(config.plasmaKeyOrder) do
    local amt = brokerState.plasma[name] or 0
    if row > H then break end
    clear(row); term.setCursor(P3 + 1, row)
    gpu.setForeground(amt > 0 and 0xFF00FF or 0x555555)
    local short = name:gsub(" Plasma", "")
    io.write(string.format("  %-16s %8d mB", short, amt))
    row = row + 1
    if amt > 0 then anyPlasma = true end
  end
  if not anyPlasma then
    if row > H then return end
    clear(row); term.setCursor(P3 + 1, row)
    if brokerState.lastFluidSyncTime == 0 then
      gpu.setForeground(0xFFAA00); io.write("  [ waiting for fluid telemetry... ]")
    else
      gpu.setForeground(0xFF4444); io.write("  [ NO PLASMA - MINING BLOCKED ]")
    end
    row = row + 1
  end
  row = row + 1

  clear(row); term.setCursor(P3 + 1, row)
  gpu.setForeground(0x888888); io.write("  DRONES IN STOCK:")
  row = row + 1
  local any = false
  for _, key in ipairs(config.droneKeyOrder) do
    local count = brokerState.drones[key] or 0
    if count > 0 then
      if row > H then break end
      clear(row); term.setCursor(P3 + 1, row)
      gpu.setForeground(0x00FFFF)
      local droneName = config.drones[key] or ("Drone-" .. key)
      local lvl = droneName:match("MK%-(.+)") or "?"
      io.write(string.format("  %-18s  x%d", "MK-" .. lvl, count))
      row = row + 1; any = true
    end
  end
  if not any then
    clear(row); term.setCursor(P3 + 1, row)
    gpu.setForeground(0xFF4444); io.write("  [ NO DRONES IN STOCK ]")
    row = row + 1
  end

  row = row + 1

  -- Drill kits (a "kit" = one drill tip + one rod of the same material).
  clear(row); term.setCursor(P3 + 1, row)
  gpu.setForeground(0x888888); io.write("  DRILL KITS IN STOCK:")
  row = row + 1
  local anyDrill = false
  for _, key in ipairs(drillKeyOrder) do
    local d = brokerState.drills[key]
    local kits = (d and d.kits) or 0
    if kits > 0 then
      if row > H then break end
      clear(row); term.setCursor(P3 + 1, row)
      gpu.setForeground(0x00AAFF)
      -- Display the material name, stripped of " Drill Tip".
      local entry = config.drills[key]
      local name = (entry and entry.tip and entry.tip:gsub(" Drill Tip", "")) or key
      io.write(string.format("  %-18s  x%d", name, kits))
      row = row + 1; anyDrill = true
    end
  end
  if not anyDrill then
    if row <= H then
      clear(row); term.setCursor(P3 + 1, row)
      gpu.setForeground(0xFF4444); io.write("  [ NO DRILL KITS IN STOCK ]")
      row = row + 1
    end
  end

  -- Restock: what the hw node has on order against config.drillPar.
  --
  -- This is the only place a per-material shortage becomes visible. The block
  -- above lists kits > 0, so a single material sitting under the 64-kit
  -- dispatch floor used to render as an ordinary blue count -- or vanish
  -- entirely at zero -- while its whole drone tier quietly stopped dispatching.
  local restock = {}
  for label in pairs(brokerState.crafting) do restock[#restock + 1] = label end
  -- Two reasons to sort. pairs() order is arbitrary and this panel repaints four
  -- times a second, so an unsorted list visibly shuffles between frames. And
  -- nopattern/failed go first because they are the entries a human has to act
  -- on: if the panel runs out of rows, the benign "crafting" lines are the ones
  -- that should be cut.
  table.sort(restock, function(a, b)
    local oa, ob = brokerState.crafting[a], brokerState.crafting[b]
    local ba = (type(oa) == "table" and oa.state == "crafting") and 1 or 0
    local bb = (type(ob) == "table" and ob.state == "crafting") and 1 or 0
    if ba ~= bb then return ba < bb end
    return a < b
  end)

  if #restock > 0 then
    row = row + 1
    if row <= H then
      clear(row); term.setCursor(P3 + 1, row)
      gpu.setForeground(0x888888); io.write("  RESTOCK:")
      row = row + 1
    end
    for _, label in ipairs(restock) do
      if row > H then break end
      local o     = brokerState.crafting[label]
      local state = (type(o) == "table" and o.state) or "?"
      -- "Naquadah Alloy Drill Tip" -> "Naquadah Alloy TIP": the material is what
      -- distinguishes these, and it is the part that gets truncated away.
      local short = label:gsub(" Drill Tip$", " TIP"):gsub(" Rod$", " ROD")
      clear(row); term.setCursor(P3 + 1, row)
      if state == "crafting" then
        gpu.setForeground(0xFFAA00)
        io.write(string.format("  %-24s x%d", short:sub(1, 24), (type(o) == "table" and o.want) or 0))
      else
        gpu.setForeground(0xFF4444)
        io.write(string.format("  %-24s %s", short:sub(1, 24),
          state == "nopattern" and "NO PATTERN" or "FAILED"))
      end
      row = row + 1
    end
  end

  for r = row, H do clear(r) end
end

local function drawStaticFrame()
  if not gpu then return end
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
  term.setCursor(W - 17, 2); gpu.setForeground(0x555555)
  io.write("SYNC: " .. os.date("%H:%M:%S", math.floor(getUnixTime())) .. "   ")
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

-- Disable and clear every module's interface. Shows live progress in the MODULES
-- panel so boot feels responsive instead of staring at a blank console while ~24
-- component calls run. Cheap work; this is purely about feedback.
local function initModules()
  logger:info("[STARTUP] Initializing " .. #modules .. " modules...")
  for i, mod in ipairs(modules) do
    if gpu then
      local row = 5 + i
      gpu.fill(P1 + 1, row, PW, 1, " ")
      term.setCursor(P1 + 1, row)
      gpu.setForeground(0xFFFF00)
      io.write(string.format("  M%d [%-5s]  clearing...", mod.index, mod.tier))
    end
    pcall(function()
      mod.adapter.setWorkAllowed(false)
      mod.iface.setInterfaceConfiguration(1)
      mod.iface.setInterfaceConfiguration(2)
      mod.iface.setInterfaceConfiguration(3)
    end)
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
--   - dispatch: every DISPATCH_INTERVAL
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
-- KEYS: up/down/pgup/pgdn/home/end move   enter drill in / commit
--       space toggle   t cycle target   a add downstream item
--       / filter       s save           esc back, or close at the top level
-- =============================================================================

local USER_CONFIG_PATH   = "/home/user_config.lua"
local QUOTE              = string.char(34)
local TARGET_LADDER      = { 1000000, 2000000, 5000000, 10000000, 25000000, 50000000, 100000000 }
local DEFAULT_TARGET     = 5000000

local edRequestWatchlist = false   -- set on save; main loop re-broadcasts

local ed = {
  open = false,
  mode = "asteroids",          -- "asteroids" | "detail" | "items"
  asteroid = nil,              -- selected asteroid while in detail mode
  rows = {},                   -- row model for the current mode
  sel = 1, scroll = 0,
  filter = nil, filtering = false,
  input = nil,                 -- { label, buffer, onCommit }
  enabled = {}, threshold = {},-- working copy of config.conditions
  targets = {},                -- working copy of config.dustTargets
  added = {},                  -- items newly mapped this session
  msg = "", msgColor = 0x888888,
  dirty = true,
}

local function edSay(m, c) ed.msg = m; ed.msgColor = c or 0x888888 end

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

local function edRebuild()
  if ed.mode == "asteroids" then
    ed.rows = buildAsteroids()
  elseif ed.mode == "detail" then
    ed.rows = buildDetail(ed.asteroid)
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

local function parseQty(s)
  if not s then return nil end
  local num, suffix = s:lower():gsub("%s", ""):match("^(%d+%.?%d*)([kmb]?)$")
  if not num then return nil end
  num = tonumber(num)
  if suffix == "k" then return math.floor(num * 1000) end
  if suffix == "m" then return math.floor(num * 1000000) end
  if suffix == "b" then return math.floor(num * 1000000000) end
  return math.floor(num)
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
-- every future label correction.
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

  edSay(string.format("saved %d tracked, %d own mappings -> user_config.lua, applied live",
    #conds, mineCount), 0x00FF00)
end

local edButtons = {}
local function edLayoutButtons()
  local defs
  if ed.mode == "asteroids" then
    defs = { { "ITEMS", "items" }, { "FIND", "find" }, { "SAVE", "save" }, { "CLOSE", "close" } }
  elseif ed.mode == "detail" then
    defs = { { "BACK", "back" }, { "ADD", "add" }, { "FIND", "find" }, { "SAVE", "save" }, { "CLOSE", "close" } }
  else
    defs = { { "ASTEROIDS", "asteroids" }, { "FIND", "find" }, { "SAVE", "save" }, { "CLOSE", "close" } }
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

local function edDraw()
  gpu.setBackground(0x000000)

  gpu.fill(1, 1, W, 1, " ")
  gpu.setForeground(0x00FF00)
  term.setCursor(2, 1)
  if ed.mode == "asteroids" then
    io.write("CONDITION EDITOR  /  asteroids")
  elseif ed.mode == "detail" then
    io.write("CONDITION EDITOR  /  " .. tostring(ed.asteroid))
  else
    io.write("CONDITION EDITOR  /  all tracked items")
  end

  gpu.fill(1, 2, W, 1, " ")
  gpu.setForeground(0x888888)
  term.setCursor(2, 2)
  local n = 0
  for _ in pairs(ed.enabled) do n = n + 1 end
  io.write(string.format("%d tracked  |  enter=open  space=toggle  t=target  a=add  /=find  s=save  esc=back%s",
    n, ed.filter and ("  |  filter: " .. ed.filter) or ""))

  gpu.fill(1, 4, W, 1, " ")
  gpu.setForeground(0x888888)
  if ed.mode == "asteroids" then
    term.setCursor(X_NAME, 4); io.write("ASTEROID")
    term.setCursor(X_A, 4); io.write("MODULE")
    term.setCursor(X_B, 4); io.write("DRONES")
    term.setCursor(X_C, 4); io.write("TRACKED")
  else
    term.setCursor(X_NAME, 4); io.write("ITEM")
    term.setCursor(X_A, 4); io.write("TARGET")
    term.setCursor(X_B, 4); io.write("HAVE")
    term.setCursor(X_C, 4); io.write(ed.mode == "detail" and "VIA" or "ASTEROID")
  end

  for r = 0, edRows() - 1 do
    local y   = edFirst() + r
    local idx = ed.scroll + r + 1
    local row = ed.rows[idx]

    gpu.setBackground((idx == ed.sel and row and row.kind ~= "header" and row.kind ~= "note")
                      and 0x222222 or 0x000000)
    gpu.fill(1, y, W, 1, " ")

    if row then
      if row.kind == "header" then
        gpu.setForeground(0x00AAFF)
        term.setCursor(2, y); io.write("-- " .. row.text)

      elseif row.kind == "note" then
        gpu.setForeground(0x555555)
        term.setCursor(6, y); io.write(row.text)

      elseif row.kind == "asteroid" then
        gpu.setForeground(row.tracked > 0 and 0x00FFFF or 0x777777)
        term.setCursor(X_NAME, y); io.write(row.name:sub(1, X_A - X_NAME - 1))
        gpu.setForeground(0x888888)
        term.setCursor(X_A, y); io.write("MK-" .. tostring(row.tier))
        term.setCursor(X_B, y); io.write(row.drones)
        gpu.setForeground(row.tracked > 0 and 0x00FF00 or 0x555555)
        term.setCursor(X_C, y); io.write(tostring(row.tracked))
        if not row.direct then
          gpu.setForeground(0xFFAA00)
          term.setCursor(X_C + 6, y); io.write("no derived outputs")
        end

      else -- item
        local item = row.item
        local on   = ed.enabled[item]
        gpu.setForeground(on and 0x00FFFF or 0x555555)
        term.setCursor(X_MARK, y); io.write(on and "[x]" or "[ ]")
        term.setCursor(X_NAME, y)
        io.write(((row.direct == false and ed.mode == "detail") and "~ " or "  ")
                 .. item:sub(1, X_A - X_NAME - 3))

        term.setCursor(X_A, y)
        io.write(on and formatQty(ed.threshold[item] or DEFAULT_TARGET) or "-")

        local d    = brokerState.dust[item]
        local have = d and d.stock or 0
        local tgt  = ed.threshold[item] or DEFAULT_TARGET
        gpu.setForeground(have >= tgt and 0x00FF00 or (have > 0 and 0xFFAA00 or 0x555555))
        term.setCursor(X_B, y); io.write(formatQty(have))

        if ed.mode == "detail" then
          gpu.setForeground(0x666666)
          term.setCursor(X_C, y)
          io.write(tostring(row.source or "hand-typed"):sub(1, W - X_C))
        else
          local t = ed.targets[item]
          if t then
            gpu.setForeground(0x888888)
            term.setCursor(X_C, y); io.write(tostring(t.asteroid):sub(1, W - X_C))
          else
            gpu.setForeground(0xFF4444)
            term.setCursor(X_C, y); io.write("NOT MINEABLE")
          end
        end
      end
      gpu.setBackground(0x000000)
    end
  end

  edLayoutButtons()
  local by = H - 1
  gpu.setBackground(0x000000)
  gpu.fill(1, by, W, 1, " ")
  for _, b in ipairs(edButtons) do
    gpu.setBackground(0x333333); gpu.setForeground(0xFFFFFF)
    term.setCursor(b.x1, by); io.write(b.label)
  end
  gpu.setBackground(0x000000)
  gpu.setForeground(0x888888)
  local pos = string.format("%d-%d/%d", math.min(ed.scroll + 1, #ed.rows),
    math.min(ed.scroll + edRows(), #ed.rows), #ed.rows)
  term.setCursor(W - #pos - 1, by); io.write(pos)

  gpu.fill(1, H, W, 1, " ")
  term.setCursor(2, H)
  if ed.input then
    gpu.setForeground(0xFFAA00)
    io.write(ed.input.label .. " " .. ed.input.buffer .. "_")
  elseif ed.filtering then
    gpu.setForeground(0xFFAA00)
    io.write("/" .. (ed.filter or "") .. "_    enter=keep  esc=clear")
  else
    gpu.setForeground(ed.msgColor)
    io.write(ed.msg:sub(1, W - 2))
  end
end

-- ---------------------------------------------------------------------------
-- INPUT
-- ---------------------------------------------------------------------------

local function edAction(a)
  if a == "close" then
    ed.open = false
    drawStaticFrame()
  elseif a == "back" then
    if ed.mode == "detail" then
      ed.mode, ed.asteroid = "asteroids", nil
      ed.sel, ed.scroll = 1, 0
      edRebuild()
    else
      edAction("close")
    end
  elseif a == "items" then
    ed.mode = "items"; ed.sel, ed.scroll = 1, 0; edRebuild()
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

local function edOpenSelected()
  local row = ed.rows[ed.sel]
  if not row then return end
  if row.kind == "asteroid" then
    ed.mode, ed.asteroid = "detail", row.name
    ed.sel, ed.scroll = 1, 0
    edRebuild()
    edMoveSel(1)
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
    if y >= edFirst() and y < edFirst() + edRows() then
      local idx = ed.scroll + (y - edFirst()) + 1
      local row = ed.rows[idx]
      if row and row.kind ~= "header" and row.kind ~= "note" then
        ed.sel = idx
        if row.kind == "asteroid" then
          edOpenSelected()
        elseif x >= X_A and x < X_B then
          edCycleTarget(row.item)
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

    -- Text entry swallows printable keys. Never blocks the scheduler.
    if ed.input then
      if code == 28 then            -- enter
        local cb, buf = ed.input.onCommit, ed.input.buffer
        ed.input = nil
        cb(buf)
      elseif code == 1 then         -- esc
        ed.input = nil; edSay("cancelled")
      elseif code == 14 then        -- backspace
        ed.input.buffer = ed.input.buffer:sub(1, -2)
      elseif ch and ch >= 32 and ch < 127 then
        ed.input.buffer = ed.input.buffer .. string.char(ch)
      end
      return true
    end

    if ed.filtering then
      if code == 28 then
        ed.filtering = false; edSay("filter: " .. (ed.filter or ""))
      elseif code == 1 then
        ed.filtering = false; ed.filter = nil; edRebuild(); edSay("filter cleared")
      elseif code == 14 then
        ed.filter = (ed.filter or ""):sub(1, -2); edRebuild()
      elseif ch and ch >= 32 and ch < 127 then
        ed.filter = (ed.filter or "") .. string.char(ch):lower(); edRebuild()
      end
      return true
    end

    if     code == 200 then edMoveSel(-1)
    elseif code == 208 then edMoveSel(1)
    elseif code == 201 then edMoveSel(-edRows())
    elseif code == 209 then edMoveSel(edRows())
    elseif code == 199 then ed.sel = 1; edMoveSel(1); edMoveSel(-1); edFollow()
    elseif code == 207 then ed.sel = #ed.rows; edMoveSel(-1); edMoveSel(1); edFollow()
    elseif code == 28  then edOpenSelected()
    elseif code == 1   then edAction("back")
    elseif ch == 32 then
      local row = selectedRow()
      if row and row.kind == "item" then
        edToggle(row.item, ed.mode == "detail" and ed.asteroid or
                           (ed.targets[row.item] and ed.targets[row.item].asteroid))
        edRebuild()
      elseif row and row.kind == "asteroid" then
        edOpenSelected()
      end
    elseif ch == 116 then
      local row = selectedRow()
      if row and row.kind == "item" then edCycleTarget(row.item) end
    elseif ch == 97  then edAction("add")
    elseif ch == 47  then edAction("find")
    elseif ch == 115 then edAction("save")
    elseif ch == 105 then edAction("items")
    end
    return true
  end

  return false
end

local UI_INTERVAL = 0.25 -- seconds between full UI repaints
local lastUIDraw  = 0

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
local WATCHLIST_INTERVAL = 30   -- seconds between re-broadcasts
local lastWatchlistSend  = 0

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
  for key, par in pairs(config.drillPar or {}) do
    local drill = config.drills[key]
    -- An unknown key is a config typo. Skip it rather than shipping a nil label
    -- the node would have to defend against.
    if drill and drill.tip and drill.rod then
      list[drill.tip] = par.tips or 0
      list[drill.rod] = par.rods or 0
    end
  end
  -- An empty table still goes out: that is how a node that was ordering learns
  -- to stop after you cleared config.drillPar.
  modem.broadcast(config.ports.hardware, serial.serialize({
    protocol    = "MEDINA_COMMAND",
    sender      = nodeId,
    payloadType = "DRILL_PAR",
    data        = list,
  }))
end

while true do
  -- 1. Service one inbound message. Very short timeout: returns immediately if a
  --    message is waiting, otherwise yields the CPU for ~10ms and comes back so
  --    the scheduler keeps ticking fast.
  -- Pull ANY event, not just modem_message: the dust panel is scrollable and
  -- nothing else in this program consumes input.
  local ev = { event.pull(0.01) }
  if ev[1] == "modem_message" then
    processMessage(table.unpack(ev))
    if ed.open then ed.dirty = true end   -- HAVE values may have moved

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

  elseif ev[1] == "key_down" and ev[3] == 101 then   -- "e" opens the editor
    ed.open = true
    edBuild()
    edSay("click a row to toggle, click its target to cycle -- mining continues")
    ed.dirty = true
  end

  -- A save inside the editor rewrites config.conditions and applies it live, so
  -- push the new watchlist immediately rather than waiting out the 30s cadence.
  if edRequestWatchlist then
    broadcastWatchlist()
    lastWatchlistSend  = computer.uptime()
    edRequestWatchlist = false
  end

  -- 1b. Re-publish the dust watchlist on its own slow cadence.
  local nowW = computer.uptime()
  if nowW - lastWatchlistSend >= WATCHLIST_INTERVAL then
    broadcastWatchlist()
    broadcastDrillPar()  -- one timer, two audiences; par changes just as rarely
    lastWatchlistSend = nowW
  end

  -- 2. Advance every in-flight load task. This is the hot path — runs every
  --    iteration so concurrent loads progress as fast as the hardware allows.
  sched.tick()

  -- 3. Advance module lifecycle (load results, running->done, cleanup).
  stepModules()

  -- 4. Telemetry-ready gate. All three telem sources are required: dust (what to
  --    mine), hardware (drones/kits available), and fluid (plasma — modules can't
  --    run without it). Wait for all three before dispatching.
  if not brokerState.telemetryReady then
    brokerState.telemetryReady = (brokerState.lastDustSyncTime > 0)
        and (brokerState.lastHWSyncTime > 0)
        and (brokerState.lastFluidSyncTime > 0)
  end

  -- 5. Dispatch on its own cadence.
  local now = os.time()
  if brokerState.telemetryReady and (now - lastDispatchCheck >= DISPATCH_INTERVAL) then
    dispatchBatch()
    lastDispatchCheck = now
  end

  -- 6. Redraw the UI a few times a second, not every iteration. The full
  --    three-panel repaint is the most expensive thing we do; throttling it
  --    frees the loop to tick the scheduler hundreds of times per second.
  local up = computer.uptime()
  if ed.open then
    -- Event-driven: repaint when the editor changed, plus a slow tick so live
    -- HAVE values from telemetry still refresh. Repainting a full-screen list
    -- four times a second was the other half of the flicker.
    if ed.dirty or (up - lastUIDraw >= 2.0) then
      edDraw()
      ed.dirty   = false
      lastUIDraw = up
    end
  elseif up - lastUIDraw >= UI_INTERVAL then
    drawUI()
    lastUIDraw = up
  end
end
