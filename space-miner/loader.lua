-- =============================================================================
-- MEDINA LOADER  (v1.5)
-- Loads one mining module's consumables (drone + drill tip + drill rod) from the
-- ME network into its input bus. Designed to run as a scheduler TASK, so six of
-- these can be in flight at once without freezing the broker.
--
-- HARDWARE MODEL (this is why the code looks the way it does):
--   - Each module has its OWN ME interface adapter, transposer, and input bus.
--     Those steps are fully parallel-safe across modules.
--   - ONE shared database component holds item fingerprints, partitioned by slot:
--     M1 -> 1/2/3, M2 -> 4/5/6, ...  Slots never overlap between modules.
--
-- THE KEY INSIGHT (replaces the old magic-sleep guesswork):
--   The database is passive reference storage. iface.store() writes a fingerprint
--   into a slot, but the write may not be visible the instant store() returns.
--   So instead of sleeping a fixed guess and praying, we READ THE SLOT BACK with
--   db.get() and proceed the moment the fingerprint is confirmed. Self-pacing:
--   instant when the server is fast, patient when it lags.
--
-- DIAGNOSTICS:
--   Each load records how many poll iterations the read-back took. If it's almost
--   always 0-1, store() is reliable on this setup. If it's regularly higher,
--   store() returns early and the read-back is what's keeping us correct. Either
--   way the first in-world run tells us the truth.
-- =============================================================================

local component = require("component")
local sched     = dofile("/home/scheduler.lua")

local loader = {}

-- Tunables (all in real seconds, all honest — no tick/second mixing).
local CONFIRM_TIMEOUT   = 8    -- max wait for a fingerprint to appear in the db
local ARRIVE_TIMEOUT    = 15   -- max wait for the DRONE to reach the interface buffer
local POLL_INTERVAL     = 0.2  -- how often to re-check while awaiting
local TIPS_PER_DEFAULT  = 64   -- drill tips to stock (config.tipsPerLoad overrides)
local RODS_PER_DEFAULT  = 64   -- drill rods to stock (config.rodsPerLoad overrides)
local FILL_ROUNDS       = 10   -- re-request rounds per STACK before giving up
local STACK_DEFAULT     = 64   -- fallback when a stack does not report maxSize

-- Map a module index to its three dedicated database slots.
local function dbSlotsFor(modIndex)
  local base = (modIndex - 1) * 3
  return base + 1, base + 2, base + 3
end

-- Poll a predicate every POLL_INTERVAL until true or timeout. Returns
-- (ok, iterations). `iterations` is how many checks it took — our diagnostic.
-- Each iteration is ~POLL_INTERVAL apart, so iterations * POLL_INTERVAL is the
-- approximate wait time. Low counts => store()/ME are fast on this setup.
local function pollUntil(predicate, timeout)
  local iterations = 0
  local met = sched.await(function()
    iterations = iterations + 1
    return predicate()
  end, timeout, POLL_INTERVAL)
  return met, iterations
end

-- Confirm a fingerprint actually landed in a db slot by reading it back.
-- This is the spine of the v1.5 fix.
local function confirmFingerprint(db, slot, expectedLabel)
  return pollUntil(function()
    local stack = db.get(slot)
    return stack ~= nil and stack.label == expectedLabel
  end, CONFIRM_TIMEOUT)
end

-- Clear the input bus back into the ME interface buffer (recover stale items).
local function clearInputBus(mod)
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

-- ---------------------------------------------------------------------------
-- THE LOAD SEQUENCE  (runs inside a task; yields freely)
--
-- Arguments:
--   mod    : the module table (index, conf, iface, transposer, adapter, ...)
--   job    : { droneKey, drillKey, parallels, ... }
--   deps   : { config = <config.lua>, logger = <logger>, db = <database proxy>,
--              dbAddr = <database address string> }
--
-- Returns (ok, errOrStats):
--   ok=true  -> stats table { confirmPolls = {drone,tip,rod}, arrivePolls = N }
--   ok=false -> error string
-- ---------------------------------------------------------------------------
function loader.run(mod, job, deps)
  local config = deps.config
  local logger = deps.logger
  local db     = deps.db
  local dbAddr = deps.dbAddr

  local TIPS_PER = config.tipsPerLoad or TIPS_PER_DEFAULT
  local RODS_PER = config.rodsPerLoad or RODS_PER_DEFAULT

  local droneName  = config.drones[job.droneKey]
  local drillEntry = config.drills[job.drillKey]

  if not droneName  then return false, "bad droneKey: " .. tostring(job.droneKey) end
  if not drillEntry then return false, "bad drillKey: " .. tostring(job.drillKey) end

  local slotDrone, slotTip, slotRod = dbSlotsFor(mod.index)
  local stats = { confirmPolls = {}, arrivePolls = 0 }

  -- 1. Start clean: empty the input bus and wipe our db slots so we can't
  --    accidentally read a previous job's fingerprint.
  clearInputBus(mod)
  db.clear(slotDrone)
  db.clear(slotTip)
  db.clear(slotRod)

  -- Wait for the interface buffer slots we're about to use to actually drain
  -- back into the ME network. If a leftover item (e.g. a drill tip from the
  -- previous job, just pushed in by clearInputBus) is still sitting in slot 1,
  -- the fresh drone could end up in the wrong slot and a tip gets transferred
  -- as the "drone". Confirm slots 1-3 are empty before stocking fresh items.
  local drained = pollUntil(function()
    for s = 1, 3 do
      if (mod.transposer.getSlotStackSize(mod.conf.interfaceSide, s) or 0) > 0 then
        return false
      end
    end
    return true
  end, ARRIVE_TIMEOUT)
  if not drained then
    return false, "interface buffer did not drain before load (stale items stuck)"
  end

  -- 2. Write fingerprints, confirming each by read-back before moving on.
  local items = {
    { slot = slotDrone, label = droneName,       tag = "drone" },
    { slot = slotTip,   label = drillEntry.tip,  tag = "tip"   },
    { slot = slotRod,   label = drillEntry.rod,  tag = "rod"   },
  }

  for _, it in ipairs(items) do
    local ok = mod.iface.store({ label = it.label }, dbAddr, it.slot)
    -- store()'s return is treated as a hint; the read-back is the truth.
    local confirmed, polls = confirmFingerprint(db, it.slot, it.label)
    stats.confirmPolls[it.tag] = polls
    if not confirmed then
      return false, "fingerprint never confirmed for " .. it.tag ..
                    " (" .. it.label .. ") in slot " .. it.slot ..
                    "; store() returned " .. tostring(ok)
    end
  end

  -- 3. Tell the interface to stock items matching those fingerprints.
  mod.iface.setInterfaceConfiguration(1, dbAddr, slotDrone, 1)
  mod.iface.setInterfaceConfiguration(2, dbAddr, slotTip, TIPS_PER)
  mod.iface.setInterfaceConfiguration(3, dbAddr, slotRod, RODS_PER)

  -- 4. The DRONE is the load gate: wait only for it. Tips and rods are handled
  --    by the patient fill in step 6 rather than being demanded up front.
  --    Under ME contention (several modules loading at once) tips and rods
  --    trickle in, and blocking here on the full 64 of each was the cause of the
  --    recurring "items did not arrive" failures.
  --
  --    Identity, not position: the interface may place items in slots other than
  --    1/2/3, so search the whole buffer by label.
  local ibufSize = mod.transposer.getInventorySize(mod.conf.interfaceSide) or 9
  local function bufferHas(label, minSize)
    for s = 1, ibufSize do
      local stack = mod.transposer.getStackInSlot(mod.conf.interfaceSide, s)
      if stack and stack.label == label and (stack.size or 0) >= minSize then
        return true
      end
    end
    return false
  end

  local droneArrived, polls = pollUntil(function()
    return bufferHas(droneName, 1)
  end, ARRIVE_TIMEOUT)
  stats.arrivePolls = polls

  if not droneArrived then
    clearInterfaceSlots(mod)
    return false, "drone did not arrive: " .. droneName
  end

  -- 5. Move items into the input bus by IDENTITY, not by slot position.
  --    Root cause of the recurring "tip in the drone slot" error: we trusted
  --    that interface slot 1 held the drone and blindly transferred slot 1 -> bus
  --    slot 1. But the ME interface actively re-stocks its slots, and can shuffle
  --    what's in which buffer slot between our check and the transfer. So instead
  --    of trusting positions, we SCAN the buffer for the slot that actually holds
  --    each item and move that one. This is correct regardless of how the
  --    interface reorders slots or whether clearing drains them.
  local busSize = mod.transposer.getInventorySize(mod.conf.interfaceSide) or 9

  -- Find the buffer slot whose item matches `label` with at least `minSize`.
  local function findSlot(label, minSize)
    for s = 1, busSize do
      local stack = mod.transposer.getStackInSlot(mod.conf.interfaceSide, s)
      if stack and stack.label == label and (stack.size or 0) >= minSize then
        return s
      end
    end
    return nil
  end

  -- Move the drone (exactly 1) into bus slot 1. It is not consumed on arrival,
  -- so once it lands it stays put while tips and rods fill in around it.
  local droneSrc = findSlot(droneName, 1)
  if not droneSrc then
    clearInterfaceSlots(mod)
    return false, "drone not found in interface buffer (" .. droneName .. ")"
  end
  local movedDrone = mod.transposer.transferItem(
    mod.conf.interfaceSide, mod.conf.inputBusSide, 1, droneSrc, 1)
  if (movedDrone or 0) < 1 then
    clearInterfaceSlots(mod)
    return false, "drone transfer failed"
  end

  -- 6. Fill tips (bus slot 2) and rods (bus slot 3) from the interface buffer,
  --    which the ME keeps restocked against the fingerprint we wrote in step 2.
  --
  --    Patient by design. The old code demanded all 64 in one transfer and
  --    failed the whole load if the ME had only trickled in 40. This re-requests
  --    and moves the deficit, up to FILL_ROUNDS times, so a slow or contended ME
  --    still completes the load instead of erroring out.
  -- Consumables are counted and placed across the WHOLE bus, not one fixed slot.
  --
  -- An inventory slot holds a single stack, so a target above the stack size
  -- cannot land in one slot: the old code drove bus slot 2 towards `target` and,
  -- asked for more than 64, would spin FILL_ROUNDS times and fail with
  -- "tip shortfall: got 64/128". Spreading across slots is what lets the module
  -- carry more than one stack of buffer and idle less between reloads.
  --
  -- Slot 1 is reserved for the drone, which is not consumed, so scanning starts
  -- at 2.
  local busSlots = mod.transposer.getInventorySize(mod.conf.inputBusSide) or 16

  local function busTotal(label)
    local total = 0
    for s = 2, busSlots do
      local st = mod.transposer.getStackInSlot(mod.conf.inputBusSide, s)
      if st and st.label == label then total = total + (st.size or 0) end
    end
    return total
  end

  -- Where should the next transfer land? Prefer a partly filled stack of this
  -- item, otherwise the first empty slot. Returns the slot and the room in it.
  local function destFor(label)
    local firstEmpty
    for s = 2, busSlots do
      local st = mod.transposer.getStackInSlot(mod.conf.inputBusSide, s)
      if not st or (st.size or 0) == 0 then
        firstEmpty = firstEmpty or s
      elseif st.label == label then
        local cap  = st.maxSize or STACK_DEFAULT
        local room = cap - (st.size or 0)
        if room > 0 then return s, room end
      end
    end
    if firstEmpty then return firstEmpty, STACK_DEFAULT end
    return nil, 0
  end

  -- How big is a stack of this item, per the game rather than an assumption?
  local function stackCap(label)
    local s = findSlot(label, 1)
    if s then
      local st = mod.transposer.getStackInSlot(mod.conf.interfaceSide, s)
      if st and st.maxSize then return st.maxSize end
    end
    return STACK_DEFAULT
  end

  local function fill(label, target, cfgSlot, dbSlot)
    -- More stacks legitimately need more rounds; a fixed budget would fail a
    -- healthy multi-stack load on a contended ME.
    local rounds = FILL_ROUNDS * math.max(1, math.ceil(target / STACK_DEFAULT))
    for _ = 1, rounds do
      local have    = busTotal(label)
      local deficit = target - have
      if deficit <= 0 then return true end

      -- Ask the ME for at most one stack at a time: that is all the interface
      -- buffer will hold in a slot anyway.
      local cap = stackCap(label)
      mod.iface.setInterfaceConfiguration(cfgSlot, dbAddr, dbSlot, math.min(deficit, cap))
      sched.await(function() return findSlot(label, 1) ~= nil end, 3, POLL_INTERVAL)

      local src = findSlot(label, 1)
      if src then
        local dst, room = destFor(label)
        if not dst then
          -- Bus is full of other things; nothing more we can do.
          return busTotal(label) >= target
        end
        mod.transposer.transferItem(
          mod.conf.interfaceSide, mod.conf.inputBusSide,
          math.min(deficit, room), src, dst)
      end
      sched.sleep(POLL_INTERVAL)
    end
    return busTotal(label) >= target
  end

  -- Verify the right drone landed before committing tips and rods (catches a
  -- cross-up before we spend ME throughput filling around a wrong drone).
  local droneStack = mod.transposer.getStackInSlot(mod.conf.inputBusSide, 1)
  if not droneStack or droneStack.label ~= droneName then
    clearInterfaceSlots(mod)
    return false, "drone mismatch in bus: expected " .. droneName ..
                  ", got " .. (droneStack and droneStack.label or "empty")
  end
  if not fill(drillEntry.tip, TIPS_PER, 2, slotTip) then
    clearInterfaceSlots(mod)
    return false, "tip shortfall: got " .. busTotal(drillEntry.tip) .. "/" .. TIPS_PER
  end
  if not fill(drillEntry.rod, RODS_PER, 3, slotRod) then
    clearInterfaceSlots(mod)
    return false, "rod shortfall: got " .. busTotal(drillEntry.rod) .. "/" .. RODS_PER
  end

  clearInterfaceSlots(mod)
  return true, stats
end

loader.dbSlotsFor = dbSlotsFor  -- exported for the broker's UI/return logic

return loader
