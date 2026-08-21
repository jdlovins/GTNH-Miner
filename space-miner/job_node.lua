-- =============================================================================
-- File:    job_node.lua
-- Purpose: Runs on each distributed mining computer. Controls up to 6 Space
--          Elevator Mining Modules. Self-registers with the MEDINA broker,
--          receives job assignments, loads consumables, runs modules, and
--          reports completion.
--
--   Port 2027  - inbound:  broker -> this node (JOB_ASSIGN)
--   Port 2026  - outbound: this node -> broker (register / status / complete)
--
-- Hardware required per node:
--   Shared:  T2 Wireless Network Card
--            OC Database component (tier 2 recommended, 25 slots covers 6 modules)
--   Per module:
--            OC Adapter adjacent to the Mining Module controller block
--            OC Adapter adjacent to the ME Interface
--            OC Transposer between the ME Interface buffer and the Input Bus
--
-- Plasma is supplied by hardware only (ME Fluid Export Bus -> Input Hatch).
-- The script does not load plasma.
--
-- Requires /home/job_node_config.lua  - auto-generated on first run.
-- Fill in component addresses, then restart.
-- =============================================================================

local component    = require("component")
local computer     = require("computer")
local serial       = require("serialization")
local event        = require("event")
local term         = require("term")
local fs           = require("filesystem")
local createLogger = dofile("/home/logger.lua")

local config = dofile("/home/config.lua")
local loggingModule = createLogger  -- the module exports {createLogger, bootUnixTime, bootComputerTime}
local logger = loggingModule.createLogger("jobnode1")
local loggingBootUnixTime = loggingModule.bootUnixTime

logger:info("========== JOB_NODE STARTUP ==========")

-- =============================================================================
-- PER-NODE CONFIG (auto-generated if missing)
-- =============================================================================

local CONFIG_PATH = "/home/job_node_config.lua"

if not fs.exists(CONFIG_PATH) then
  local f = assert(io.open(CONFIG_PATH, "w"))
  f:write([[
-- job_node_config.lua
-- Fill in the component addresses for this computer, then restart job_node.lua.
-- Run  component.list()  in the OC Lua console to find addresses.
--
-- SHARED HARDWARE
--   dbAddr         OC Database component (tier 2 = 25 slots, supports 6 modules).
--                  One database serves the whole node. Each module uses 3 slots:
--                    M1 -> slots 1-3,  M2 -> slots 4-6,  M3 -> slots 7-9
--                    M4 -> slots 10-12, M5 -> slots 13-15, M6 -> slots 16-18
--
-- PER-MODULE HARDWARE
--   moduleAddr     OC Adapter adjacent to the Mining Module controller block.
--                  Exposes setParameters() / setWorkAllowed() / isMachineActive().
--
--   ifaceAddr      OC Adapter adjacent to the ME Interface.
--                  Exposes store() and setInterfaceConfiguration().
--
--   transposerAddr OC Transposer sitting between the ME Interface and the Input Bus.
--                  Moves items from the interface buffer into the module.
--
--   interfaceSide  Side of the transposer that faces the ME Interface buffer.
--   inputBusSide   Side of the transposer that faces the module Input Bus.
--                  Sides: 0=down  1=up  2=north  3=south  4=west  5=east
--
--   distanceParam  setParameters index for the asteroid distance value.
--                  Confirmed in-game as index 0. Verify with:
--                    component.proxy(component.get("moduleAddr")).getParametersInfo()
return {
  nodeId = "MEDINA-Ring-1",
  dbAddr = "",  -- shared OC Database component address (first 8 chars is enough)
  modules = {
    [1] = {
      tier           = "MK-II",
      moduleAddr     = "",
      ifaceAddr      = "",
      transposerAddr = "",
      interfaceSide  = 0,
      inputBusSide   = 1,
      distanceParam  = 0,
    },
    -- Copy the block above for each additional module slot (up to 6 total)
  }
}
]])
  f:close()
  error("Created " .. CONFIG_PATH .. "  - fill in component addresses and restart.")
end

local nodeConf = dofile(CONFIG_PATH)
local nodeId   = assert(nodeConf.nodeId, "nodeId missing from job_node_config.lua")

-- =============================================================================
-- HARDWARE VALIDATION & COMPONENT RESOLUTION
-- =============================================================================

if not component.isAvailable("modem") then error("Missing network card.") end
local modem = component.modem
if not modem.isWireless or not modem.isWireless() then
  error("Job node requires a T2 Wireless Network Card.")
end
modem.setStrength(400)
modem.open(config.ports.telemetry)  -- for outbound broadcasts (register, complete)
modem.open(config.ports.command)    -- for inbound commands (JOB_ASSIGN)

local function getProxy(addr, label)
  if not addr or addr == "" then error(label .. ": address not configured") end
  local full = component.get(addr)
  if not full then error(label .. ": component '" .. addr .. "' not found") end
  return component.proxy(full)
end

-- Resolve the shared database address once. All modules reference it by UUID string.
assert(nodeConf.dbAddr and nodeConf.dbAddr ~= "", "dbAddr not set in job_node_config.lua")
local dbAddress = component.get(nodeConf.dbAddr)
assert(dbAddress, "database component '" .. nodeConf.dbAddr .. "' not found")

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
    -- Runtime state
    status     = "IDLE",   -- IDLE | LOADING | RUNNING | DONE | ERROR
    job        = nil,      -- jobData table from broker while active
    startTime  = 0,        -- os.time() when module last started (for startup grace)
    lastPoll   = 0,        -- os.time() of last isMachineActive() call
    errorMsg   = nil,
  }
end

-- =============================================================================
-- DISPLAY  (optional  - job nodes may run headless without a GPU)
-- =============================================================================

local gpu = component.isAvailable("gpu") and component.gpu or nil
if gpu then
  gpu.setResolution(80, math.max(25, #modules + 8))
  term.clear()
end

-- Per-module message buffers (3 lines each)
local function initModuleBuffers()
  for _, mod in ipairs(modules) do
    mod.logLines = { "", "", "" }
  end
end

local function modLog(modIndex, msg)
  -- Add message to module's log buffer
  if modIndex >= 1 and modIndex <= #modules then
    local mod = modules[modIndex]
    if mod.logLines then
      table.remove(mod.logLines, 1)
      table.insert(mod.logLines, msg)
    end
  end
end

local function log(msg)
  logger:debug(msg)
  if not gpu then
    print(os.date("[%X] ") .. tostring(msg))
  end
end

-- =============================================================================
-- STARTUP CLEANUP
-- =============================================================================

local function clearInputBuses()
  for _, mod in ipairs(modules) do
    local busSize = mod.transposer.getInventorySize(mod.conf.inputBusSide) or 16
    for slot = 1, busSize do
      local size = mod.transposer.getSlotStackSize(mod.conf.inputBusSide, slot) or 0
      if size > 0 then
        mod.transposer.transferItem(mod.conf.inputBusSide, mod.conf.interfaceSide, size, slot)
      end
    end
  end
end

local function clearInterfaces()
  for _, mod in ipairs(modules) do
    mod.iface.setInterfaceConfiguration(1)
    mod.iface.setInterfaceConfiguration(2)
    mod.iface.setInterfaceConfiguration(3)
    local ifaceSize = mod.transposer.getInventorySize(mod.conf.interfaceSide) or 16
    for slot = 1, ifaceSize do
      local size = mod.transposer.getSlotStackSize(mod.conf.interfaceSide, slot) or 0
      if size > 0 then
        mod.transposer.transferItem(mod.conf.interfaceSide, mod.conf.inputBusSide, size, slot)
      end
    end
  end
end

local function clearScreen()
  if not gpu then return end
  term.clear()
  gpu.setForeground(0x00FF00)
  gpu.fill(1, 1, 80, 1, "=")
  gpu.fill(1, 3, 80, 1, "=")
  term.setCursor(2, 2)
  gpu.setForeground(0xFFFFFF)
  io.write(" MEDINA JOB NODE")
  gpu.setForeground(0x888888)
  io.write(" | " .. nodeId)
  gpu.setForeground(0x555555)
  term.setCursor(70, 2)
  io.write(os.date("%X"))

  -- Show real-world Unix time on line 3 for tracking
  term.setCursor(2, 3)
  gpu.setForeground(0x555555)
  local elapsedSinceBoot = computer.uptime() - loggingModule.bootComputerTime
  local realWorldNow = loggingBootUnixTime + elapsedSinceBoot
  io.write("Real-world: " .. os.date("!%Y-%m-%d %H:%M:%S", math.floor(realWorldNow)) .. " UTC")
end

local function drawModules()
  if not gpu then return end
  clearScreen()

  local row = 5
  for i, mod in ipairs(modules) do
    gpu.fill(1, row, 80, 1, " ")
    term.setCursor(2, row)

    -- Show validation error in red if present
    if mod.validationError then
      gpu.setForeground(0xFF4444)
      io.write(string.format("M%d [%-6s]  ✗ MISMATCH (%s)", mod.index, mod.tier, mod.validationError))
      row = row + 1
    else
      local color = (mod.status == "RUNNING")  and 0xFFAA00 or
                    (mod.status == "LOADING")  and 0xAAAA00 or
                    (mod.status == "ERROR")    and 0xFF4444 or
                    (mod.status == "DONE")     and 0x00FF00 or 0x555555
      gpu.setForeground(color)

      local detail = ""
      if mod.job then
        detail = "  " .. mod.job.asteroid
      end

      io.write(string.format("M%d [%-6s]  %s%s", mod.index, mod.tier, mod.status, detail))
      row = row + 1
    end
  end
end

-- =============================================================================
-- BROKER MESSAGING
-- =============================================================================

local function broadcast(payloadType, data)
  modem.broadcast(config.ports.telemetry, serial.serialize({
    protocol    = "MEDINA_JOB",
    sender      = nodeId,
    payloadType = payloadType,
    data        = data
  }))
end

local function buildModuleList()
  local list = {}
  for _, mod in ipairs(modules) do
    list[#list+1] = {
      index  = mod.index,
      tier   = mod.tier,
      status = mod.status,
      job    = mod.job and mod.job.asteroid or nil
    }
  end
  return list
end

local function sendRegister()
  broadcast("NODE_REGISTER", {
    modules = buildModuleList()
  })
end

local function sendComplete(jobId, success, errMsg)
  broadcast("JOB_COMPLETE", { jobId=jobId, success=success, error=errMsg })
end

local function sendJobAck(jobId, status)
  -- status: "RECEIVED" (job assigned), "STARTED" (job running)
  broadcast("JOB_ACK", { jobId=jobId, status=status })
end

-- =============================================================================
-- CONSUMABLE LOADING
--
-- Item loading flow (proven in-game path):
--   1. me_interface.store()                 - write label->fingerprint into db slot
--   2. me_interface.setInterfaceConfiguration()  - tell interface to pull that item from ME
--   3. Poll transposer.getSlotStackSize()   - wait for items to appear in buffer
--   4. transposer.transferItem()            - move items into the Input Bus
--   5. me_interface.setInterfaceConfiguration(slot)  - clear slot so ME stops refilling
--
-- Each module uses 3 reserved database slots to avoid conflicts when multiple
-- modules load simultaneously:
--   M1 -> db slots 1,2,3  |  M2 -> 4,5,6  |  M3 -> 7,8,9
--   M4 -> 10,11,12        |  M5 -> 13,14,15 | M6 -> 16,17,18
-- =============================================================================

local LOAD_TIMEOUT = 6 * 20  -- Minecraft seconds (6 real seconds for ME pulls with contention)
local LOAD_POLL    = 0.05 * 20 -- Minecraft seconds between buffer-ready checks (1 Minecraft tick)
local STORE_DELAY  = 1         -- Minecraft seconds to wait after store() call (reduced from 8, ME is fast)

-- Returns the three database slot indices reserved for this module index.
-- Slot layout: drone=base+1, drill tip=base+2, drill rod=base+3
local function dbSlotsFor(modIndex)
  local base = (modIndex - 1) * 3
  return base + 1, base + 2, base + 3
end

-- Clears all three interface configuration slots for this module.
-- Called after transfer completes to prevent ME from refilling with stale items.
local function clearInterfaceSlots(mod)
  mod.iface.setInterfaceConfiguration(1)
  mod.iface.setInterfaceConfiguration(2)
  mod.iface.setInterfaceConfiguration(3)
end

local function loadConsumables(mod, job)
  local droneName  = config.drones[job.droneKey]
  local drillEntry = config.drills[job.drillKey]
  local parallels  = job.parallels or 1

  if not droneName  then return false, "bad droneKey: "  .. tostring(job.droneKey) end
  if not drillEntry then return false, "bad drillKey: "  .. tostring(job.drillKey) end

  local slotDrone, slotTip, slotRod = dbSlotsFor(mod.index)

  log("[LOAD] M" .. mod.index .. " clearing input bus")
  local busSize = mod.transposer.getInventorySize(mod.conf.inputBusSide) or 16
  for slot = 1, busSize do
    local size = mod.transposer.getSlotStackSize(mod.conf.inputBusSide, slot) or 0
    if size > 0 then
      mod.transposer.transferItem(mod.conf.inputBusSide, mod.conf.interfaceSide, size, slot)
    end
  end
  os.sleep(0.5)

  -- Step 1: Write item fingerprints into this module's reserved database slots.
  -- store() resolves the label against the live ME network and stores the result.
  -- Returns false if the item is not found in the network.
  if not mod.iface.store({label=droneName},      dbAddress, slotDrone) then
    return false, "drone not in ME network: " .. droneName
  end
  log("[LOAD] M" .. mod.index .. " stored drone: " .. droneName)
  os.sleep(STORE_DELAY)

  if not mod.iface.store({label=drillEntry.tip}, dbAddress, slotTip) then
    return false, "drill tip not in ME network: " .. drillEntry.tip
  end
  log("[LOAD] M" .. mod.index .. " stored drill tips: " .. drillEntry.tip)
  os.sleep(STORE_DELAY)

  if not mod.iface.store({label=drillEntry.rod}, dbAddress, slotRod) then
    return false, "drill rod not in ME network: " .. drillEntry.rod
  end
  log("[LOAD] M" .. mod.index .. " stored drill rods: " .. drillEntry.rod)
  os.sleep(STORE_DELAY)
  log("[LOAD] M" .. mod.index .. " all items confirmed in database")

  -- Step 2: Pull items from ME network in PARALLEL.
  -- Configure all 3 slots at once: drone + full stack of 64 tips + full stack of 64 rods
  -- This gives 4 runs per consumable load (4 tips/rods × 16 parallels = 64 each)

  local deadline = os.time() + LOAD_TIMEOUT

  log("[LOAD] M" .. mod.index .. " configuring parallel pulls: drone + 64 tips + 64 rods (4-run stack)")

  -- Configure all 3 slots at once for maximum parallelism
  -- Pull 1 drone, 64 tips, 64 rods (enough for 4 × 16-parallel runs)
  mod.iface.setInterfaceConfiguration(1, dbAddress, slotDrone, 1)
  mod.iface.setInterfaceConfiguration(2, dbAddress, slotTip, 64)
  mod.iface.setInterfaceConfiguration(3, dbAddress, slotRod, 64)

  os.sleep(0.1)  -- minimal pause for ME to start pulling

  -- Poll for all items to arrive in parallel
  local droneReady = false
  local tipReady = false
  local rodReady = false
  local pollStart = os.time()

  while os.time() < deadline do
    -- Check drone
    if not droneReady then
      if (mod.transposer.getSlotStackSize(mod.conf.interfaceSide, 1) or 0) >= 1 then
        droneReady = true
      end
    end

    -- Check tips (need 64 for 4-run buffer)
    if not tipReady then
      if (mod.transposer.getSlotStackSize(mod.conf.interfaceSide, 2) or 0) >= 64 then
        tipReady = true
      end
    end

    -- Check rods (need 64 for 4-run buffer)
    if not rodReady then
      if (mod.transposer.getSlotStackSize(mod.conf.interfaceSide, 3) or 0) >= 64 then
        rodReady = true
      end
    end

    -- If all items are ready, break early
    if droneReady and tipReady and rodReady then
      log("[LOAD] M" .. mod.index .. " all items arrived after " .. (os.time() - pollStart) .. "ms")
      break
    end

    os.sleep(LOAD_POLL)
  end

  -- Final check for any items that arrived after deadline
  if not droneReady then
    local stackSize = mod.transposer.getSlotStackSize(mod.conf.interfaceSide, 1) or 0
    if stackSize >= 1 then droneReady = true end
  end
  if not tipReady then
    local stackSize = mod.transposer.getSlotStackSize(mod.conf.interfaceSide, 2) or 0
    if stackSize >= 64 then tipReady = true end
  end
  if not rodReady then
    local stackSize = mod.transposer.getSlotStackSize(mod.conf.interfaceSide, 3) or 0
    if stackSize >= 64 then rodReady = true end
  end

  -- Check if any items failed to arrive
  if not droneReady then
    clearInterfaceSlots(mod)
    log("[LOAD] ✗ M" .. mod.index .. " timed out waiting for drone")
    return false, "timed out waiting for drone: " .. droneName
  end
  if not tipReady then
    clearInterfaceSlots(mod)
    log("[LOAD] ✗ M" .. mod.index .. " timed out waiting for tips (need 64)")
    return false, "timed out waiting for drill tips: " .. drillEntry.tip
  end
  if not rodReady then
    clearInterfaceSlots(mod)
    log("[LOAD] ✗ M" .. mod.index .. " timed out waiting for rods (need 64)")
    return false, "timed out waiting for drill rods: " .. drillEntry.rod
  end

  -- Transfer all items to input bus in one go
  log("[LOAD] M" .. mod.index .. " transferring drone + 64 tips + 64 rods to input bus")
  mod.transposer.transferItem(mod.conf.interfaceSide, mod.conf.inputBusSide, 1, 1, 1)
  mod.transposer.transferItem(mod.conf.interfaceSide, mod.conf.inputBusSide, 64, 2, 2)
  mod.transposer.transferItem(mod.conf.interfaceSide, mod.conf.inputBusSide, 64, 3, 3)

  -- Clear all interface configurations
  clearInterfaceSlots(mod)
  log("[LOAD] M" .. mod.index .. " all consumables ready, starting module")

  return true
end

-- After a job completes, return all items from the Input Bus back to the ME
-- Interface buffer (which returns them to the ME network). This recovers the
-- drone  - which is not consumed  - and any leftover drill bits.
local function returnItemsToME(mod)
  local busSize = mod.transposer.getInventorySize(mod.conf.inputBusSide) or 16
  for slot = 1, busSize do
    local size = mod.transposer.getSlotStackSize(mod.conf.inputBusSide, slot) or 0
    if size > 0 then
      mod.transposer.transferItem(mod.conf.inputBusSide, mod.conf.interfaceSide, size, slot)
    end
  end
end

-- =============================================================================
-- MODULE CONTROL & STATE MACHINE
-- =============================================================================

local STARTUP_GRACE = 10  -- seconds after start before polling isMachineActive (let module fully spin up)
local POLL_INTERVAL = 5 * 20   -- Minecraft seconds between active-status polls (0.25 real seconds for fast DONE detection)

local function startModule(mod, distance)
  -- GTNH 2.9: named-key API replaces positional setParameters.
  local ok, err = pcall(function()
    mod.adapter.setParameter("distance", distance)
    mod.adapter.setParameter("parallel", mod.job and mod.job.parallels or 1)
    mod.adapter.setParameter("cycle", false)
    mod.adapter.setWorkAllowed(true)
  end)
  if not ok then return false, tostring(err) end
  return true
end

-- LOADING: load consumables then start the module
local function stepLoading(mod)
  log("[LOAD] M" .. mod.index .. " starting consumable load")
  local loadStart = os.time()
  local ok, err = loadConsumables(mod, mod.job)
  local loadTime = os.time() - loadStart
  if not ok then
    log("FAIL M" .. mod.index .. ": " .. err)
    mod.status   = "ERROR"
    mod.errorMsg = err
    return
  end
  log("[LOAD] M" .. mod.index .. " consumables loaded in " .. loadTime .. "ms")

  local started
  started, err = startModule(mod, mod.job.distance)
  if not started then
    log("FAIL M" .. mod.index .. " start: " .. err)
    mod.status   = "ERROR"
    mod.errorMsg = err
    return
  end

  log("RUN  M" .. mod.index .. ": " .. mod.job.asteroid ..
      " dist=" .. tostring(mod.job.distance) ..
      " x"    .. tostring(mod.job.parallels))
  modLog(mod.index, "Running job...")
  mod.status    = "RUNNING"
  mod.startTime = os.time()
  mod.lastPoll  = os.time()
  sendJobAck(mod.job.jobId, "STARTED")  -- ACK: job actually started
end

-- RUNNING: poll the module until it reports inactive (job complete)
local function stepRunning(mod)
  local now = os.time()
  if now - mod.startTime < STARTUP_GRACE then return end  -- let it spin up
  if now - mod.lastPoll  < POLL_INTERVAL  then return end  -- throttle API calls
  mod.lastPoll = now

  local ok, isActive = pcall(mod.adapter.isMachineActive)
  if ok and not isActive then
    mod.status = "DONE"
  end
end

-- DONE: return items to ME, notify broker, reset to IDLE
local function stepDone(mod)
  os.sleep(1.0)  -- 1 Minecraft second (1/20 real second) for machine output phase
  returnItemsToME(mod)
  -- Clear module distance parameter to reset adapter state
  pcall(function()
    mod.adapter.setWorkAllowed(false)
    mod.adapter.setParameter("distance", 1)
  end)
  log("DONE M" .. mod.index .. ": " .. mod.job.asteroid)
  modLog(mod.index, "Job complete!")
  sendComplete(mod.job.jobId, true)
  mod.status = "IDLE"
  mod.job    = nil
  sendRegister()  -- notify broker immediately that module is back to IDLE
end

-- ERROR: report failure to broker, reset to IDLE
local function stepError(mod)
  log("ERR  M" .. mod.index .. ": " .. (mod.errorMsg or "unknown"))
  if mod.job then
    sendComplete(mod.job.jobId, false, mod.errorMsg)
    mod.job = nil
  end
  mod.status   = "IDLE"
  mod.errorMsg = nil
  sendRegister()  -- notify broker immediately that module is back to IDLE
end

local function stepModules()
  for _, mod in ipairs(modules) do
    if     mod.status == "LOADING" then stepLoading(mod)
    elseif mod.status == "RUNNING" then stepRunning(mod)
    elseif mod.status == "DONE"    then stepDone(mod)
    elseif mod.status == "ERROR"   then stepError(mod)
    end
  end
end

-- =============================================================================
-- MESSAGE HANDLING
-- =============================================================================

-- Select the best available drone for an asteroid (highest tier first)
local function selectDrone(asteroidData, asteroidName)
  if not asteroidData then
    log("[DRONE_SELECT] ERROR: asteroidData is nil for " .. tostring(asteroidName))
    return nil
  end
  log("[DRONE_SELECT] " .. asteroidName .. " requires tier " .. asteroidData.minDrone .. "-" .. asteroidData.maxDrone)
  log("[DRONE_SELECT] droneKeyOrder: " .. table.concat(config.droneKeyOrder, ", "))

  for _, droneKey in ipairs(config.droneKeyOrder) do
    local tier = config.droneTierKeys[droneKey]
    local inRange = tier >= asteroidData.minDrone and tier <= asteroidData.maxDrone
    log("[DRONE_SELECT]   " .. droneKey .. " tier=" .. tier .. " min=" .. asteroidData.minDrone .. " max=" .. asteroidData.maxDrone .. " -> " .. (inRange and "IN RANGE" or "OUT"))
    if inRange then
      log("[DRONE_SELECT] SELECTED: " .. droneKey .. " (tier " .. tier .. ")")
      return droneKey
    end
  end
  log("[DRONE_SELECT] ERROR: No viable drone found for " .. asteroidName)
  return nil
end

-- Get the optimal distance for a module+asteroid+drone combo
local function getOptimalDistance(moduleTier, asteroid, droneKey)
  if not config.optimizationMatrix then return 50 end
  local matrix = config.optimizationMatrix
  if matrix[moduleTier] and matrix[moduleTier][asteroid] and matrix[moduleTier][asteroid][droneKey] then
    return math.min(200, matrix[moduleTier][asteroid][droneKey])
  end
  return 50
end

local function validateJobAssign(data)
  -- Only validate asteroid exists; drone will be selected locally
  if not data.asteroid then
    return false, "missing asteroid"
  end

  local asteroidConfig = config.asteroids[data.asteroid]
  if not asteroidConfig then
    return false, "asteroid not in config: " .. data.asteroid
  end

  return true
end

local function handleJobAssign(data)
  if not data or not data.moduleIndex then return end
  local mod = modules[data.moduleIndex]
  if not mod then
    log("WARN: JOB_ASSIGN for unknown module index " .. tostring(data.moduleIndex))
    return
  end
  if mod.status ~= "IDLE" then
    log("WARN: JOB_ASSIGN for non-idle M" .. data.moduleIndex ..
        " (status=" .. mod.status .. ")")
    return
  end

  -- Validate asteroid exists
  local valid, err = validateJobAssign(data)
  if not valid then
    log("✗ JOB_ASSIGN error M" .. data.moduleIndex .. ": " .. err)
    mod.validationError = err
    return
  end

  -- Select drone and drill locally
  local asteroidData = config.asteroids[data.asteroid]
  local droneKey = selectDrone(asteroidData, data.asteroid)
  if not droneKey then
    log("✗ No viable drone for " .. data.asteroid .. " on M" .. data.moduleIndex)
    mod.validationError = "no viable drone"
    return
  end

  -- Get distance from optimization matrix
  local distance = getOptimalDistance(mod.tier, data.asteroid, droneKey)
  local drillKey = config.droneDrillMap[config.droneTierKeys[droneKey]]

  -- Build complete job locally
  local completeJob = {
    jobId = data.jobId,
    moduleIndex = data.moduleIndex,
    asteroid = data.asteroid,
    droneKey = droneKey,
    drillKey = drillKey,
    distance = distance,
    parallels = data.parallels
  }

  log("ASSIGN M" .. data.moduleIndex .. ": " .. data.asteroid ..
      " drone=" .. droneKey .. " dist=" .. distance)
  modLog(data.moduleIndex, "Assigned: " .. data.asteroid .. " (" .. droneKey .. ")")
  mod.status = "LOADING"
  mod.job = completeJob
  mod.validationError = nil
  sendJobAck(data.jobId, "RECEIVED")
  sendRegister()
end

local function processMessage(evType, _, _, port, _, rawMsg)
  if evType ~= "modem_message" or port ~= config.ports.command then return end
  log("[MSG] Received modem message on port " .. port)
  local ok, msg = pcall(serial.unserialize, rawMsg)
  if not ok or type(msg) ~= "table" then
    log("[MSG] ✗ Failed to deserialize message")
    return
  end
  if msg.protocol ~= "MEDINA_COMMAND" then
    log("[MSG] ✗ Wrong protocol: " .. (msg.protocol or "nil"))
    return
  end
  if msg.target ~= nodeId then
    log("[MSG] ✗ Not for us: target=" .. (msg.target or "nil") .. " nodeId=" .. nodeId)
    return
  end

  if msg.payloadType == "JOB_ASSIGN" and msg.data then
    log("[MSG] ✓ JOB_ASSIGN received for M" .. (msg.data.moduleIndex or "?") .. " asteroid=" .. (msg.data.asteroid or "?"))
    handleJobAssign(msg.data)
  else
    log("[MSG] ✗ Not a JOB_ASSIGN: " .. (msg.payloadType or "nil"))
  end
end

-- =============================================================================
-- STARTUP SPLASH SCREEN
-- =============================================================================

local function showSplash(status)
  if not gpu then return end
  clearScreen()
  term.setCursor(2, 6)
  gpu.setForeground(0xFFFFFF)
  io.write("MEDINA JOB NODE")
  term.setCursor(2, 8)
  gpu.setForeground(0xAAAAAA)
  io.write(status)
end

-- =============================================================================
-- MAIN LOOP
-- =============================================================================

showSplash("Initializing...")
local dbProxy = component.proxy(dbAddress)

showSplash("Clearing database...")
for slot = 1, 18 do
  dbProxy.clear(slot)
end

showSplash("Clearing interfaces...")
clearInterfaces()

showSplash("Clearing input buses...")
clearInputBuses()

showSplash("Registering with broker...")
sendRegister()

showSplash("Ready. Waiting for jobs...")

if gpu then
  clearScreen()
end

-- Initialize per-module log buffers
initModuleBuffers()

local lastRegister    = os.time()
local lastLoopTime    = os.time()
local REGISTER_INTERVAL = 30 * 20  -- Minecraft seconds (1.5 real seconds); status changes trigger immediate registration

while true do
  local loopStart = os.time()

  -- Check for incoming commands from the broker (0.5s timeout keeps the loop responsive)
  local ev = { event.pull(0.5, "modem_message") }
  if ev[1] == "modem_message" then
    processMessage(table.unpack(ev))
  end

  -- Check for Ctrl+C to drop to interactive shell for debugging
  local keyEv = { event.pull(0, "key_down") }
  if keyEv[1] == "key_down" and keyEv[3] == 3 then
    term.clear()
    print("Job node breakpoint triggered (Ctrl+C). Drop to shell for inspection.")
    print("Type 'exit' to resume or close terminal.")
    os.exit()
  end

  -- Advance each module's state machine one step
  stepModules()

  -- Periodically re-announce this node so a broker restart picks it up automatically
  local now = os.time()
  if now - lastRegister >= REGISTER_INTERVAL then
    sendRegister()
    lastRegister = now
  end

  drawModules()
end
