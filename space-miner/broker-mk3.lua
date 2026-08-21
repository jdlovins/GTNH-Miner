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

local component = require("component")
local serial    = require("serialization")
local event     = require("event")
local term      = require("term")
local fs        = require("filesystem")
local computer  = require("computer")

local config = dofile("/home/config.lua")
local sched  = dofile("/home/scheduler.lua")
local loader = dofile("/home/loader.lua")

local loggingModule = dofile("/home/logger.lua")
assert(loggingModule and loggingModule.createLogger, "logger.lua not loaded")
local logger = loggingModule.createLogger("broker-mk3")
local getUnixTime = loggingModule.getCurrentTimestamp

logger:info("========== BROKER-MK3 (v1.5) STARTUP ==========")

-- Surface task crashes in the log instead of swallowing them.
sched.onError = function(name, err)
  logger:error("[TASK] " .. tostring(name) .. " crashed: " .. tostring(err))
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
    index      = i,
    tier       = mc.tier,
    conf       = mc,
    adapter    = getProxy(mc.moduleAddr,     lbl .. " moduleAddr"),
    iface      = getProxy(mc.ifaceAddr,      lbl .. " ifaceAddr"),
    transposer = getProxy(mc.transposerAddr, lbl .. " transposerAddr"),
    status     = "IDLE",  -- IDLE | LOADING | RUNNING | DONE | ERROR
    job        = nil,
    doneTime   = nil,
    loadHandle = nil,     -- scheduler task handle while LOADING
    loadResult = nil,     -- set by the load task: { ok=bool, err=?, stats=? }
  }
end

-- (Modules are disabled/cleared after the dashboard frame is drawn, so boot
--  shows progress instead of a blank console. See initModules() below.)

-- =============================================================================
-- BROKER STATE
-- =============================================================================

local brokerState = {
  dust = {}, plasma = {}, drones = {}, drills = {}, jobs = {}, cooldowns = {},
  lastDustSyncTime = 0, lastFluidSyncTime = 0, lastHWSyncTime = 0,
  lastDustSync = "--:--:--", lastFluidSync = "--:--:--", lastHWSync = "--:--:--",
  nextTarget = nil, telemetryReady = false,
  priorityMode = "threshold",  -- "threshold" (lowest fill first) | "rarity" (dust priority first)
}

local drillKeyOrder = {
  "steel","titanium","tungstensteel","naquadah",
  "naquadahAlloy","neutronium","cosmicNeutronium","infinity","transcendentMetal"
}

for _, cond in ipairs(config.conditions) do
  brokerState.dust[cond.itemName] = { stock=0, threshold=cond.amountToMaintain }
end
for _, name in ipairs(config.plasmaKeyOrder) do brokerState.plasma[name] = 0 end
for _, key in ipairs(config.droneKeyOrder) do brokerState.drones[key] = 0 end
for _, key in ipairs(drillKeyOrder) do brokerState.drills[key] = { kits=0, tips=0, rods=0 } end

-- UI layout (three panels).
local W, H = gpu and gpu.maxResolution() or 120, 50
if gpu then gpu.setResolution(W, H) end
local P1 = 1
local P2 = math.floor(W / 3) + 1
local P3 = math.floor(W * 2 / 3) + 1
local PW = P2 - 2

local DISPATCH_INTERVAL = 0.2
local lastDispatchCheck = 0
local ERROR_TIMEOUT = 10
local lastErrorTime = {}

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
  mod.loadStart = computer.uptime()  -- real seconds, for elapsed readout
  mod.loadHandle = sched.spawn(function()
    local ok, errOrStats = loader.run(mod, mod.job, {
      config = config, logger = logger, db = db, dbAddr = dbAddr,
    })
    mod.loadResult = ok and { ok = true, stats = errOrStats }
                        or  { ok = false, err = errOrStats }
  end, "load-M" .. mod.index)
end

-- Called each frame for a LOADING module: check whether its task finished.
local function pollLoad(mod)
  if not mod.loadResult then return end  -- still loading

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
    mod.job.startTime = os.time()
    -- NOTE: this used to call
    --   mod.adapter.setParameters(mod.conf.distanceParam, 0, mod.job.distance)
    -- to push the chosen asteroid distance into the module. GT no longer exposes
    -- setParameters on the machine's OC interface, so the call died with
    -- "attempt to call a nil value (field 'setParameters')". Distance must now be
    -- set on the module by hand.
    --
    -- job.distance is still computed by getOptimalDistance() and shown on the
    -- dashboard, but it is ADVISORY ONLY now -- nothing applies it.
    mod.adapter.setWorkAllowed(true)
  else
    mod.status = "ERROR"
    logger:error("[LOAD] M" .. mod.index .. " failed: " .. tostring(r.err))
  end
end

local function stepRunning(mod)
  if not mod.adapter.isMachineActive() then
    mod.status = "DONE"
    mod.adapter.setWorkAllowed(false)
  end
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
    lastDispatchCheck = os.time() - DISPATCH_INTERVAL
  end
end

local function stepModules()
  for _, mod in ipairs(modules) do
    if     mod.status == "LOADING" then pollLoad(mod)
    elseif mod.status == "RUNNING" then stepRunning(mod)
    elseif mod.status == "DONE"    then stepDone(mod)
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
        needs[#needs+1] = { itemName=cond.itemName, asteroid=ast, ratio=ratio, priority=entry.priority or 99 }
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
      idle[#idle+1] = mod
    elseif mod.status == "ERROR" then
      if not lastErrorTime[i] then
        lastErrorTime[i] = now
      elseif now - lastErrorTime[i] >= ERROR_TIMEOUT then
        pcall(function() returnItemsToME(mod) end)
        mod.status = "IDLE"; mod.job = nil; mod.doneTime = nil
        lastErrorTime[i] = nil
        logger:info("[RECOVERY] M" .. i .. " auto-recovered from ERROR state")
        idle[#idle+1] = mod
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

  -- Don't dispatch if we have no drill kit for this drone tier — otherwise the
  -- load would just fail at the store() step waiting for tips/rods that aren't
  -- in the ME network.
  local drill = brokerState.drills[drillKey]
  if not drill or (drill.kits or 0) <= 0 then return false end

  local jobId = nodeId .. "-" .. os.time() .. "-M" .. mod.index
  mod.status = "LOADING"
  mod.job = {
    jobId = jobId, asteroid = asteroid, droneKey = droneKey, drillKey = drillKey,
    distance = getOptimalDistance(mod.tier, asteroid, droneKey),
    parallels = config.moduleTiers[mod.tier].maxParallels,
    startTime = os.time(),
  }
  brokerState.jobs[jobId] = { moduleIndex = mod.index, asteroid = asteroid, startTime = os.time() }
  brokerState.nextTarget = { asteroid = asteroid, reason = "dispatched" }

  beginLoad(mod)  -- non-blocking: spawns the cooperative load task
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
  return math.floor(#modules / 2) + 1   -- 6 modules -> 4, 24 -> 13
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

local function dispatchBatch()
  pruneStaleJobs()

  -- No plasma = modules can't run. Hold dispatch until some is in stock.
  if not hasPlasma() then return end

  local idleModules = getIdleModules()
  if #idleModules == 0 then return end

  local needs = findNeedsList()
  if #needs == 0 then return end

  local neededAsteroids = {}
  for _, need in ipairs(needs) do neededAsteroids[need.asteroid] = need end

  -- Working pools we can still hand out this batch: drones and drill kits.
  local avail     = availableDrones()
  local availKit  = availableKits()

  -- Per-asteroid usage: start from what's already committed, count up as we go,
  -- and never exceed the cap. This is what frees module slots for lower-tier
  -- needs (e.g. Uranium-Plutonium) instead of one asteroid eating them all.
  local cap        = asteroidCap()
  local astCount   = activeAsteroidCounts()

  for _, droneKey in ipairs(config.droneKeyOrder) do
    if (avail[droneKey] or 0) > 0 then
      local droneTier = config.droneTierKeys[droneKey]
      local drillKey  = config.droneDrillMap[droneTier]

      -- Need both a free drone AND a free kit of the matching material.
      if drillKey and (availKit[drillKey] or 0) > 0 then
        for asteroidName, asteroidData in pairs(config.asteroids) do
          -- Stop scanning once we've exhausted this drone or its kits.
          if (avail[droneKey] or 0) <= 0 or (availKit[drillKey] or 0) <= 0 then break end
          if droneTier >= asteroidData.minDrone and droneTier <= asteroidData.maxDrone then
            -- Eligible if it's a current need AND under its module cap.
            if neededAsteroids[asteroidName] and (astCount[asteroidName] or 0) < cap then
              local assigned = false
              for idx = #idleModules, 1, -1 do
                local mod = idleModules[idx]
                if tryDispatch(mod, asteroidName, droneKey) then
                  astCount[asteroidName] = (astCount[asteroidName] or 0) + 1
                  avail[droneKey]        = avail[droneKey] - 1     -- consume a drone
                  availKit[drillKey]     = availKit[drillKey] - 1  -- consume a kit
                  table.remove(idleModules, idx)
                  assigned = true
                  break
                end
              end
              if assigned and #idleModules == 0 then return end
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
    for name, entry in pairs(msg.data) do
      brokerState.dust[name] = { stock = entry.stock or 0, threshold = entry.threshold or 0 }
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
  if n >= 1000000 then return string.format("%.1fm", n / 1000000)
  elseif n >= 1000 then return string.format("%.0fk", n / 1000)
  else return tostring(n) end
end

local function drawModulePanel()
  local row = 6
  local function clear(r) gpu.fill(P1 + 1, r, PW, 1, " ") end
  for r = 6, H do clear(r) end  -- wipe column first; sections shift between frames
  for _, mod in ipairs(modules) do
    if row > H then break end
    clear(row); term.setCursor(P1 + 1, row)
    if mod.status == "RUNNING" then
      gpu.setForeground(0xFFAA00)
      io.write(string.format("  M%d [%-5s]  %s", mod.index, mod.tier, mod.job and mod.job.asteroid or "?"))
    elseif mod.status == "LOADING" then
      gpu.setForeground(0xFFFF00)
      io.write(string.format("  M%d [%-5s]  LOADING %s", mod.index, mod.tier, mod.job and mod.job.asteroid or ""))
    elseif mod.status == "ERROR" then
      gpu.setForeground(0xFF4444)
      io.write(string.format("  M%d [%-5s]  ERROR", mod.index, mod.tier))
    else
      gpu.setForeground(0x555555)
      io.write(string.format("  M%d [%-5s]  IDLE", mod.index, mod.tier))
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
        gpu.setForeground(0x668866)  -- dim green: informational
        io.write(mod.lastLoad)
        row = row + 1
      end

      -- Blank spacer line before the next module, per layout.
      if row <= H then clear(row); row = row + 1 end
    end
  end
  for r = row, H do gpu.fill(P1 + 1, r, PW, 1, " ") end
end

local function drawDustPanel()
  local row = 6
  for r = 6, H do gpu.fill(P2 + 1, r, PW, 1, " ") end  -- wipe column first
  local list = {}
  for _, cond in ipairs(config.conditions) do
    local name  = cond.itemName
    local stock = (brokerState.dust[name] and brokerState.dust[name].stock) or 0
    local ratio = stock / cond.amountToMaintain
    list[#list+1] = { name=name, stock=stock, threshold=cond.amountToMaintain, ratio=ratio }
  end
  table.sort(list, function(a, b) return a.ratio < b.ratio end)
  for _, item in ipairs(list) do
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

  -- Wipe the whole panel column first. Sections here grow/shrink between frames
  -- (plasma message appears/disappears, drone/kit lists change length), and
  -- clearing only the rows we draw leaves "ghost" text on vacated rows when the
  -- layout shifts up. Clearing the full column each frame makes ghosts impossible.
  for r = 6, H do clear(r) end

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

runBootPrompt()     -- ask priority mode (runs while you're at the console)
logger:info("Waiting for telemetry...")
drawStaticFrame()   -- frame appears immediately
initModules()       -- then clear modules with visible progress

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
local UI_INTERVAL = 0.25          -- seconds between full UI repaints
local lastUIDraw  = 0

while true do
  -- 1. Service one inbound message. Very short timeout: returns immediately if a
  --    message is waiting, otherwise yields the CPU for ~10ms and comes back so
  --    the scheduler keeps ticking fast.
  local ev = { event.pull(0.01, "modem_message") }
  if ev[1] == "modem_message" then processMessage(table.unpack(ev)) end

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
  if up - lastUIDraw >= UI_INTERVAL then
    drawUI()
    lastUIDraw = up
  end
end
