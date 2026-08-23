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
local computer  = require("computer")   -- drain() times out against uptime()
local sched     = dofile("/home/scheduler.lua")

local loader = {}

-- Tunables (all in real seconds, all honest — no tick/second mixing).
local CONFIRM_TIMEOUT   = 8    -- max wait for a fingerprint to appear in the db
local ARRIVE_TIMEOUT    = 15   -- max wait for the DRONE to reach the interface buffer
-- How often to re-check while awaiting. Straight latency: every wait that misses
-- its first check costs at least this long, and a load contains several.
--
-- Measured against a simulated ME, per load: 0.2 cost 0.55s of pure polling with
-- an instant network, 0.1 cost 0.40s, 0.05 cost 0.35s. Calls rise with the rate,
-- and they are metered per tick, so 0.05 gave back nearly everything the
-- snapshot scanning saved for very little extra speed. 0.1 is the knee.
local POLL_INTERVAL     = 0.1
local TIPS_PER_DEFAULT  = 64   -- drill tips to stock (config.tipsPerLoad overrides)
local RODS_PER_DEFAULT  = 64   -- drill rods to stock (config.rodsPerLoad overrides)
local FILL_TIMEOUT      = 30   -- total seconds to get every consumable into the bus
local STACK_DEFAULT     = 64   -- fallback when a stack does not report maxSize
local MAX_CFG_SLOTS     = 8    -- ME Interface configuration slots we may use

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
  -- Clear every slot we might have configured, not just the original three:
  -- a multi-stack load spreads its requests across more of them, and a slot
  -- left configured keeps the ME stocking items we no longer want.
  for slot = 1, MAX_CFG_SLOTS do
    mod.iface.setInterfaceConfiguration(slot)
  end
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

  -- HOW MUCH IS ENOUGH TO START.
  --
  -- The load used to block until the FULL buffer was in the bus. At the shipped
  -- 128 tips and 128 rods that is 256 items through the ME per module, with six
  -- modules pulling at once -- seconds of a drill sitting fully stocked enough to
  -- work while it waits for stock it will not touch for minutes.
  --
  -- A module needs a working buffer, not a full one. Drain to the start amount,
  -- start mining, and let the broker's top-up task carry it the rest of the way
  -- while it runs -- the same mechanism pinned modules have always used.
  --
  -- Defaults to one stack, which is one interface configuration slot and so the
  -- fastest thing the ME can deliver. Set tipsToStart = tipsPerLoad to get the
  -- old fill-completely-then-start behaviour back.
  local TIPS_START = math.min(config.tipsToStart or STACK_DEFAULT, TIPS_PER)
  local RODS_START = math.min(config.rodsToStart or STACK_DEFAULT, RODS_PER)

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
  local preDrainAt = computer.uptime()
  local drained = pollUntil(function()
    for s = 1, 3 do
      if (mod.transposer.getSlotStackSize(mod.conf.interfaceSide, s) or 0) > 0 then
        return false
      end
    end
    return true
  end, ARRIVE_TIMEOUT)
  stats.preDrainSecs = computer.uptime() - preDrainAt
  if not drained then
    return false, "interface buffer did not drain before load (stale items stuck)"
  end

  -- 2. Write fingerprints, confirming each by read-back before moving on.
  local items = {
    { slot = slotDrone, label = droneName,       tag = "drone" },
    { slot = slotTip,   label = drillEntry.tip,  tag = "tip"   },
    { slot = slotRod,   label = drillEntry.rod,  tag = "rod"   },
  }

  -- Issue all three writes first, then wait for them together.
  --
  -- Confirming each before starting the next served the three waits back to
  -- back, so the load paid three round-trips where the writes could have been
  -- settling concurrently. store()'s return is a hint; the read-back is truth.
  local storeOk = {}
  for _, it in ipairs(items) do
    storeOk[it.tag] = mod.iface.store({ label = it.label }, dbAddr, it.slot)
  end

  for _, it in ipairs(items) do
    local confirmed, polls = confirmFingerprint(db, it.slot, it.label)
    stats.confirmPolls[it.tag] = polls
    if not confirmed then
      return false, "fingerprint never confirmed for " .. it.tag ..
                    " (" .. it.label .. ") in slot " .. it.slot ..
                    "; store() returned " .. tostring(storeOk[it.tag])
    end
  end

  -- 3. Tell the interface to stock items matching those fingerprints.
  --
  -- One configuration slot stocks at most a stack, so a 128-item target needs
  -- two of them. Allocating a slot per stack lets the ME deliver them
  -- CONCURRENTLY; with a single slot per consumable the load waits out one
  -- delivery, drains it, waits out the next, and so on.
  --
  -- A configured slot is also self-refilling: the interface maintains that
  -- stock, so draining the buffer is itself the request for more. The old fill
  -- loop re-issued setInterfaceConfiguration every round, which was churn.
  local cfgSlots = { tip = {}, rod = {} }
  do
    local next_ = 2   -- slot 1 is the drone
    local function alloc(kind, dbSlot, total)
      local stacks = math.max(1, math.ceil(total / STACK_DEFAULT))
      for _ = 1, stacks do
        if next_ > MAX_CFG_SLOTS then break end
        cfgSlots[kind][#cfgSlots[kind] + 1] = next_
        next_ = next_ + 1
      end
      -- Spread the target evenly over however many slots we got, so a short
      -- allocation still asks for everything rather than silently under-ordering.
      local n = #cfgSlots[kind]
      local per = math.min(STACK_DEFAULT, math.ceil(total / math.max(1, n)))
      for _, slot in ipairs(cfgSlots[kind]) do
        mod.iface.setInterfaceConfiguration(slot, dbAddr, dbSlot, per)
      end
    end
    mod.iface.setInterfaceConfiguration(1, dbAddr, slotDrone, 1)
    alloc("tip", slotTip, TIPS_PER)
    alloc("rod", slotRod, RODS_PER)
  end

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

  -- One read of each inventory per pass, then every decision comes off the
  -- snapshot.
  --
  -- busTotal, destFor and findSlot each used to rescan on their own, so a single
  -- drain pass over two consumables cost about 78 getStackInSlot calls. Those
  -- are metered per tick in OpenComputers, so the scanning was itself part of
  -- what made loading slow -- and it capped how tight the poll interval could
  -- sensibly be.
  local function scanSide(side, from, count)
    local snap = {}
    for s = from, count do
      snap[s] = mod.transposer.getStackInSlot(side, s)
    end
    return snap
  end

  local function totalIn(snap, from, to, label)
    local total = 0
    for s = from, to do
      local st = snap[s]
      if st and st.label == label then total = total + (st.size or 0) end
    end
    return total
  end

  -- Where should the next transfer land? Prefer a partly filled stack of this
  -- item, otherwise the first empty slot. Returns the slot and the room in it.
  local function destIn(snap, label)
    local firstEmpty
    for s = 2, busSlots do
      local st = snap[s]
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

  local function srcIn(snap, label)
    for s = 1, ibufSize do
      local st = snap[s]
      if st and st.label == label and (st.size or 0) >= 1 then return s end
    end
    return nil
  end

  -- Kept for the failure messages, which run once and are not hot.
  local function busTotal(label)
    return totalIn(scanSide(mod.conf.inputBusSide, 2, busSlots), 2, busSlots, label)
  end

  -- Drain both consumables together until each reaches its target.
  --
  -- Two changes from filling them one after another. Tips and rods are now in
  -- flight at the same time, so their ME latencies overlap instead of adding
  -- up. And a pass that actually moved something loops straight round again
  -- rather than sleeping -- the old code paid a fixed POLL_INTERVAL after every
  -- transfer, productive or not, which on a multi-stack load is most of the
  -- wall time.
  --
  -- Returns true when everything landed, or false plus the label that fell
  -- short.
  local function drain(wanted)
    local deadline = computer.uptime() + FILL_TIMEOUT
    while true do
      local outstanding, moved = false, false
      stats.fillPasses = (stats.fillPasses or 0) + 1

      -- Two reads for the whole pass, however many consumables are outstanding.
      local busSnap = scanSide(mod.conf.inputBusSide, 2, busSlots)
      local bufSnap = scanSide(mod.conf.interfaceSide, 1, ibufSize)

      for _, w in ipairs(wanted) do
        local have = totalIn(busSnap, 2, busSlots, w.label)
        if have < w.target then
          outstanding = true
          local src = srcIn(bufSnap, w.label)
          if src then
            local dst, room = destIn(busSnap, w.label)
            if dst then
              local n = math.min(w.target - have, room)
              local got = mod.transposer.transferItem(
                mod.conf.interfaceSide, mod.conf.inputBusSide, n, src, dst)
              if (got or 0) > 0 then
                moved = true
                -- Keep the snapshot honest so a second consumable in this same
                -- pass does not pick the slot we just filled.
                local d = busSnap[dst]
                if d then d.size = (d.size or 0) + got
                else busSnap[dst] = { label = w.label, size = got, maxSize = STACK_DEFAULT } end
                local sst = bufSnap[src]
                if sst then
                  sst.size = (sst.size or 0) - got
                  if sst.size <= 0 then bufSnap[src] = nil end
                end
              end
            else
              -- No room anywhere on the bus; more waiting will not help.
              return false, w.label
            end
          end
        end
      end

      if not outstanding then return true end
      if computer.uptime() >= deadline then
        for _, w in ipairs(wanted) do
          if busTotal(w.label) < w.target then return false, w.label end
        end
        return true
      end
      -- Only yield when nothing could be moved: otherwise keep draining. A pass
      -- that moves nothing is a pass spent waiting on the ME to restock the
      -- interface buffer, so counting them separates "the transposer is slow"
      -- from "the network is not delivering".
      if not moved then
        stats.fillWaits = (stats.fillWaits or 0) + 1
        sched.sleep(POLL_INTERVAL)
      end
    end
  end

  -- Verify the right drone landed before committing tips and rods (catches a
  -- cross-up before we spend ME throughput filling around a wrong drone).
  local droneStack = mod.transposer.getStackInSlot(mod.conf.inputBusSide, 1)
  if not droneStack or droneStack.label ~= droneName then
    clearInterfaceSlots(mod)
    return false, "drone mismatch in bus: expected " .. droneName ..
                  ", got " .. (droneStack and droneStack.label or "empty")
  end
  local fillAt = computer.uptime()
  local ok, shortLabel = drain({
    { label = drillEntry.tip, target = TIPS_START },
    { label = drillEntry.rod, target = RODS_START },
  })
  stats.fillSecs = computer.uptime() - fillAt
  if not ok then
    local target = (shortLabel == drillEntry.tip) and TIPS_START or RODS_START
    local kind   = (shortLabel == drillEntry.tip) and "tip" or "rod"
    clearInterfaceSlots(mod)
    return false, kind .. " shortfall: got " .. busTotal(shortLabel) .. "/" .. target
  end

  clearInterfaceSlots(mod)
  -- Tell the caller what is still owed, so it knows to keep topping up.
  stats.startedWith = { tips = TIPS_START, rods = RODS_START }
  stats.bufferTarget = { tips = TIPS_PER, rods = RODS_PER }
  return true, stats
end

loader.dbSlotsFor = dbSlotsFor  -- exported for the broker's UI/return logic

return loader
