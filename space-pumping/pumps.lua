-- =============================================================================
-- pumps.lua — hardware, state and assignment for the space pumping array
--
-- Everything that touches a GT machine or the ME controller lives here. The main
-- loop (autoPump.lua) only ever calls into this file, and the UI (ui.lua) only
-- ever reads from it.
--
-- TWO IDEAS CARRIED OVER FROM THE MINER, AND WHY:
--
--  1. CONFIRM, DO NOT SLEEP.  Arming a pump used to be
--        setWorkAllowed(true); os.sleep(0.1); setWorkAllowed(false)
--     — a magic number that blocked the whole program, was too short on a laggy
--     server and wasted time on a fast one. With eight pumps that was 0.8s of
--     frozen UI on every pass. Now the arm runs as a scheduler task and waits on
--     isMachineActive() going true, up to armTimeout. Same as the miner's loader
--     waiting on db.get() instead of guessing (space-miner/loader.lua).
--
--  2. NO BARE HARDWARE CALLS.  Every component call goes through hw(), which
--     pcalls it. An adapter pulled out or a chunk unloading now puts ONE pump in
--     ERROR with a cooldown; it used to kill the program with the rest of the
--     array mid-cycle.
--
-- ONE CLOCK: computer.uptime(), real seconds. os.time() (world ticks) is not
-- used for timing anywhere in this program.
-- =============================================================================

local component = require("component")
local computer  = require("computer")

local pumps = {}

-- Injected by pumps.init so this file can be driven by a test harness.
local config, sched, log

-- Live pump records, sorted by capacity (largest first) so the biggest pump is
-- offered the biggest shortfall.
local list = {}

-- Runtime state. Deliberately NOT stored back into config.master: config stays
-- pure data, so it can be re-read without dragging stale amounts along.
pumps.state = {
  amounts        = {},        -- label -> litres currently in the network
  rates          = {},        -- label -> litres/second over the last window
  snapshot       = {},        -- label -> litres at the last snapshot
  -- nil until the first baseline is taken. Deliberately not 0: uptime() is 0 on
  -- the very first pass of a freshly booted computer, and a 0 sentinel would
  -- then read as "no baseline yet" forever, so no rate would ever be computed.
  lastSnapshotAt = nil,
  throughput     = 0,         -- summed positive rates, litres/second
  mode           = "Normal",  -- Normal | Stairstep | Waterfall
  meOk           = false,     -- did the last ME read succeed?
  meError        = nil,
  lastRescanAt   = 0,
}

local MODES = { Normal = true, Stairstep = true, Waterfall = true }

-- ---------------------------------------------------------------------------
-- SAFE HARDWARE CALLS
-- ---------------------------------------------------------------------------

-- Call `name` on a pump's proxy. Returns (true, results...) or (false, message).
-- Nothing in this file calls a proxy method any other way.
local function hw(p, name, ...)
  local fn = p.module and p.module[name]
  if type(fn) ~= "function" then
    return false, name .. ": not available on this component"
  end
  local r = table.pack(pcall(fn, ...))
  if not r[1] then return false, tostring(r[2]) end
  return true, table.unpack(r, 2, r.n)
end

-- Put a pump into ERROR with a cooldown. The rest of the array is untouched.
local function fail(p, msg)
  p.status   = "ERROR"
  p.lastError = msg
  p.task     = nil
  p.errUntil = computer.uptime() + config.tuning.errorCooldown
  log:error(string.format("[PUMP %s/%s] %s", p.short, p.tier, msg))
end

-- ---------------------------------------------------------------------------
-- DISCOVERY
--
-- Re-runnable. Pumps are matched by address, so a rescan keeps the state of a
-- pump that is already working: a module added mid-run joins the array, one that
-- vanished is dropped, and nothing in flight is disturbed.
-- ---------------------------------------------------------------------------
function pumps.findPumps()
  local seen, added, removed = {}, 0, 0

  local byAddr = {}
  for _, p in ipairs(list) do byAddr[p.addr] = p end

  local ok, iter = pcall(component.list, "gt_machine")
  if not ok then
    log:error("component.list failed: " .. tostring(iter))
    return #list, 0, 0
  end

  for address in iter do
    local okProxy, module = pcall(component.proxy, address)
    if okProxy and module then
      local okName, name = pcall(function() return module.getName() end)
      local tier = okName and name and config.tiers[name]
      if tier then
        seen[address] = true
        local p = byAddr[address]
        if not p then
          p = {
            addr   = address,
            short  = address:sub(1, 4),
            module = module,
            status = "IDLE",
            task   = nil,
            inactiveStreak = 0,
            lastRunPollAt  = 0,
          }
          list[#list + 1] = p
          added = added + 1
          log:info(string.format("[PUMP %s] found, tier %s", p.short, tier.label))
        end
        -- Refresh the proxy and tier data every scan: a chunk reload can hand
        -- back a new proxy object for the same address.
        p.module   = module
        p.tier     = tier.label
        p.threads  = tier.threads
        p.mult     = tier.mult
        p.capacity = tier.mult * tier.threads
      end
    end
  end

  local kept = {}
  for _, p in ipairs(list) do
    if seen[p.addr] then
      kept[#kept + 1] = p
    else
      removed = removed + 1
      log:warn(string.format("[PUMP %s] disappeared from the component network", p.short))
    end
  end
  list = kept

  table.sort(list, function(a, b)
    if a.capacity ~= b.capacity then return a.capacity > b.capacity end
    return a.addr < b.addr
  end)

  pumps.state.lastRescanAt = computer.uptime()
  return #list, added, removed
end

function pumps.list() return list end

function pumps.count() return #list end

-- ---------------------------------------------------------------------------
-- ME NETWORK
--
-- The proxy is fetched lazily and dropped on the first failing call, so a
-- controller that goes away (chunk unload, adapter removed) is picked back up
-- on its own once it returns, without a restart.
-- ---------------------------------------------------------------------------
local me = nil

-- Walk config.meComponents in order and take the first type present that
-- actually answers getFluidsInNetwork(). Presence is not enough: an Adapter can
-- expose a component whose network has no fluid storage behind it, and finding
-- that out here beats discovering it as a permanently empty dashboard.
local function meProxy()
  if me then return me end
  for _, kind in ipairs(config.meComponents or { "me_interface", "me_controller" }) do
    if component.isAvailable(kind) then
      local ok, proxy = pcall(function() return component[kind] end)
      if ok and proxy and type(proxy.getFluidsInNetwork) == "function" then
        me = proxy
        pumps.state.meKind = kind
        return me
      end
    end
  end
  return nil
end

-- The GLOBAL storage ceiling, in litres. Used for any fluid without an amount
-- of its own, and shown in the dashboard header as the default.
function pumps.getTarget()
  if config.maxTargetOverride and config.maxTargetOverride > 0 then
    return config.maxTargetOverride
  end
  local cap = config.CELL_CAPACITIES[config.currentCellType] or 0
  return cap * (1 - config.safetyMargin)
end

-- True when the user has chosen an explicit set of fluids to stock.
--
-- An empty config.wanted in the SHIPPED file means "all of them", which is how
-- this program behaved before per-fluid amounts existed, so an untouched install
-- is unaffected. But once the editor has saved, an empty list is a deliberate
-- "stock nothing" — config.wantedExplicit is what tells the two apart. Without
-- it, unticking the last fluid would silently re-enable all forty.
function pumps.hasWantedList()
  if config.wantedExplicit then return true end
  for _ in pairs(config.wanted or {}) do return true end
  return false
end

-- Is this fluid one we are stocking at all?
function pumps.isWanted(label)
  if not pumps.hasWantedList() then return true end
  return (config.wanted or {})[label] ~= nil
end

-- How much of `label` to maintain. A number in config.wanted is that fluid's own
-- ceiling; `true` (or no list at all) means follow the global one.
function pumps.targetFor(label, globalTarget)
  local w = (config.wanted or {})[label]
  if type(w) == "number" and w > 0 then return w end
  return globalTarget
end

-- Re-read the ME network and rebuild the demand list.
--
-- Returns the list sorted for the current mode. Every entry:
--   { label, amount, perc, priority, setting, deficit, rate }
function pumps.refreshFluids(target)
  local st = pumps.state
  local amounts = {}
  for label in pairs(config.master) do amounts[label] = 0 end

  local proxy = meProxy()
  if not proxy then
    st.meOk, st.meError = false, "no me_controller on the component network"
  else
    local ok, fluids = pcall(function() return proxy.getFluidsInNetwork() end)
    if not ok then
      -- Drop the proxy so the next pass re-acquires it.
      me, st.meOk, st.meError = nil, false, tostring(fluids)
      log:warn("ME read failed: " .. tostring(fluids))
    else
      for _, f in ipairs(fluids or {}) do
        if f.label and amounts[f.label] ~= nil then amounts[f.label] = f.amount or 0 end
      end
      st.meOk, st.meError = true, nil
    end
  end
  st.amounts = amounts

  -- Snapshot window. Rates are litres per SECOND over the measured elapsed time,
  -- not a percentage.
  --
  -- The old percent-change formula divided by the previous amount, so anything
  -- that started empty was pinned at 0% growth forever — exactly the fluids you
  -- most want to watch climb. An absolute rate has no such blind spot, and it is
  -- the number you actually compare against a pump's throughput.
  local now = computer.uptime()
  if not st.lastSnapshotAt then
    for label, amount in pairs(amounts) do st.snapshot[label] = amount end
    st.lastSnapshotAt = now
  else
    local elapsed = now - st.lastSnapshotAt
    if elapsed >= config.tuning.snapshotInterval then
      local rates, gained = {}, 0
      for label, amount in pairs(amounts) do
        local old = st.snapshot[label] or amount
        local r = (amount - old) / elapsed
        rates[label] = r
        if r > 0 then gained = gained + r end
        st.snapshot[label] = amount
      end
      st.rates          = rates
      st.throughput     = gained
      st.lastSnapshotAt = now
    end
  end

  -- Each fluid is measured against ITS OWN ceiling, so `perc` stays comparable
  -- across fluids you want very different amounts of — which is the whole point
  -- of per-fluid amounts, and what the sort below then orders by.
  local frac = config.tuning.minDeficitFraction or 0
  local out  = {}
  for label, data in pairs(config.master) do
    if pumps.isWanted(label) then
      local amount = amounts[label] or 0
      local cap    = pumps.targetFor(label, target)
      out[#out + 1] = {
        label    = label,
        amount   = amount,
        priority = data.priority or 0,
        setting  = data.setting,
        rate     = st.rates[label] or 0,
        target   = cap,
        perc     = (cap > 0) and (amount / cap) * 100 or 0,
        deficit  = math.max(0, cap - amount),
        floor    = cap * frac,
      }
    end
  end

  -- Sorting is by mode. Every comparator ends in a label tie-break: pairs()
  -- yields config.master in an arbitrary order, so without a total ordering the
  -- queue would reshuffle between frames even when nothing changed — which both
  -- flickers the display and churns pump assignments.
  local mode = st.mode
  if mode == "Stairstep" then
    -- Aggressive tiers: everything under 10% first, then under 50%, then the rest.
    local function step(f)
      if f.perc < 10 then return 1 elseif f.perc < 50 then return 2 else return 3 end
    end
    table.sort(out, function(a, b)
      local sa, sb = step(a), step(b)
      if sa ~= sb then return sa < sb end
      if a.priority ~= b.priority then return a.priority > b.priority end
      if a.perc ~= b.perc then return a.perc < b.perc end
      return a.label < b.label
    end)
  else
    -- Normal and Waterfall share the queue; they differ only in how many pumps
    -- get pointed at the head of it.
    table.sort(out, function(a, b)
      local an = (a.perc < 100) and 1 or 0
      local bn = (b.perc < 100) and 1 or 0
      if an ~= bn then return an > bn end
      if a.priority ~= b.priority then return a.priority > b.priority end
      if a.amount ~= b.amount then return a.amount < b.amount end
      return a.label < b.label
    end)
  end

  return out
end

-- ---------------------------------------------------------------------------
-- PUMP STATE MACHINE
--
--   IDLE   -> ARMING   (assign)
--   ARMING -> RUNNING  (isMachineActive confirmed)  | ERROR (timeout / call failed)
--   RUNNING-> IDLE     (inactive for runInactiveConfirm polls)
--   ERROR  -> IDLE     (after errorCooldown)
--
-- step() is called once per main-loop pass and never blocks. The only thing that
-- yields is the arm task, and it yields to the scheduler, not to the world.
-- ---------------------------------------------------------------------------

-- The arm sequence, run as a scheduler task so the UI keeps painting while the
-- module spins up.
local function armTask(p, fluid)
  return function()
    local t = config.tuning

    for i = 1, (p.threads or 1) do
      local base = 2 * (i - 1)
      local ok, err = hw(p, "setParameters", base, 0, fluid.setting[1])
      if not ok then p.armResult = { ok = false, err = "setParameters planet: " .. err }; return end
      ok, err = hw(p, "setParameters", base, 1, fluid.setting[2])
      if not ok then p.armResult = { ok = false, err = "setParameters slot: " .. err }; return end
    end

    local ok, err = hw(p, "setParameters", 9, 1, t.cycleCount)
    if not ok then p.armResult = { ok = false, err = "setParameters cycles: " .. err }; return end

    ok, err = hw(p, "setWorkAllowed", true)
    if not ok then p.armResult = { ok = false, err = "setWorkAllowed(true): " .. err }; return end

    -- Confirm the cycle actually started rather than sleeping a guess. See the
    -- header. On a fast server this returns on the first check.
    local started = sched.await(function()
      local o, active = hw(p, "isMachineActive")
      return o and active == true
    end, t.armTimeout, t.armPollInterval)

    -- Re-gate either way: the work gate is a one-shot trigger, and leaving it
    -- open lets the module keep cycling on a target we no longer control.
    hw(p, "setWorkAllowed", false)

    if started then
      p.armResult = { ok = true }
    else
      -- Also reachable if the whole cycle completed inside armTimeout, which a
      -- cycleCount this large should not manage. Treated as a fault so the pump
      -- retries after the cooldown rather than being silently marked RUNNING.
      p.armResult = { ok = false,
                      err = string.format("did not start within %.1fs", t.armTimeout) }
    end
  end
end

-- Hand a pump a fluid. Returns true if the arm task was spawned.
local function arm(p, fluid)
  p.task      = fluid.label
  p.armResult = nil
  p.status    = "ARMING"
  p.armedAt   = computer.uptime()
  sched.spawn(armTask(p, fluid), "arm-" .. p.short)
  return true
end

local function stepPump(p, now)
  if p.status == "ARMING" then
    if not p.armResult then return end
    local r = p.armResult
    p.armResult = nil
    if r.ok then
      p.status         = "RUNNING"
      p.runStartedAt   = now
      p.lastRunPollAt  = now
      p.inactiveStreak = 0
      p.lastError      = nil
      log:info(string.format("[PUMP %s/%s] running %s (armed in %.2fs)",
        p.short, p.tier, tostring(p.task), now - (p.armedAt or now)))
    else
      fail(p, "arm failed on " .. tostring(p.task) .. ": " .. tostring(r.err))
    end

  elseif p.status == "RUNNING" then
    if now - (p.lastRunPollAt or 0) < config.tuning.runPollInterval then return end
    p.lastRunPollAt = now
    local ok, active = hw(p, "isMachineActive")
    if not ok then
      fail(p, "isMachineActive: " .. tostring(active))
      return
    end
    if active then
      p.inactiveStreak = 0
    else
      p.inactiveStreak = (p.inactiveStreak or 0) + 1
      if p.inactiveStreak >= config.tuning.runInactiveConfirm then
        log:info(string.format("[PUMP %s/%s] finished %s after %.1fs",
          p.short, p.tier, tostring(p.task), now - (p.runStartedAt or now)))
        p.status         = "IDLE"
        p.task           = nil
        p.inactiveStreak = 0
      end
    end

  elseif p.status == "ERROR" then
    if now >= (p.errUntil or 0) then
      p.status   = "IDLE"
      p.errUntil = nil
      -- lastError is kept for the display until the pump does something else.
    end
  end
end

function pumps.step()
  local now = computer.uptime()
  for i = 1, #list do stepPump(list[i], now) end
end

-- ---------------------------------------------------------------------------
-- ASSIGNMENT
--
-- The old code gave idle pump i whatever sat at needs[i]. Two problems: the
-- queue re-sorts every second so a pump's target churned for no reason, and the
-- index took no account of what the RUNNING pumps were already on — so two
-- pumps could land on the same fluid while a third sat starved.
--
-- Now: fluids held by ARMING/RUNNING pumps are claimed and skipped, and idle
-- pumps are walked biggest-capacity-first (the list is already sorted that way)
-- against the need queue, so the T3 gets the deepest shortfall.
--
-- Waterfall keeps its deliberate override: every idle pump goes on the head of
-- the queue. Focusing the whole array on one fluid is the entire point of it.
-- ---------------------------------------------------------------------------
function pumps.assign(needs, target)
  local st    = pumps.state
  local armed = 0

  local claimed = {}
  local idle    = {}
  for _, p in ipairs(list) do
    if p.status == "RUNNING" or p.status == "ARMING" then
      if p.task then claimed[p.task] = true end
    elseif p.status == "IDLE" then
      idle[#idle + 1] = p
    end
  end
  if #idle == 0 then return 0 end

  if st.mode == "Waterfall" then
    local head
    for _, f in ipairs(needs) do
      if f.deficit > (f.floor or 0) then head = f; break end
    end
    if not head then return 0 end
    for _, p in ipairs(idle) do
      if arm(p, head) then armed = armed + 1 end
    end
    return armed
  end

  local n = 1
  for _, p in ipairs(idle) do
    local picked
    while n <= #needs do
      local f = needs[n]
      n = n + 1
      if f.deficit > (f.floor or 0) and not claimed[f.label] then picked = f; break end
    end
    if not picked then break end
    claimed[picked.label] = true
    if arm(p, picked) then armed = armed + 1 end
  end
  return armed
end

-- ---------------------------------------------------------------------------
-- BOOT / SHUTDOWN
-- ---------------------------------------------------------------------------

-- Close every work gate. Used at boot before the first assignment, and on quit.
function pumps.stopAll()
  for _, p in ipairs(list) do
    local ok, err = hw(p, "setWorkAllowed", false)
    if not ok then log:warn(string.format("[PUMP %s] stop failed: %s", p.short, err)) end
  end
end

-- True once no pump reports active. Called in a loop at boot so the array starts
-- from a known state; unlike the old preLaunch it does not re-read the ME
-- network for a value it then throws away, and it does not sleep a flat 5s.
function pumps.allIdle()
  local allIdle = true
  for _, p in ipairs(list) do
    local ok, active = hw(p, "isMachineActive")
    if not ok then
      -- Keep the REASON, not just the fact. A boot screen that says "ERR" and
      -- nothing else tells you a module is unhappy and gives you no way to find
      -- out why -- which is exactly the situation you are in when you read it.
      p.bootStatus = "ERR"
      p.bootError  = tostring(active)
      allIdle = false
    elseif active then
      p.bootStatus = "BUSY"
      p.bootError  = nil
      allIdle = false
    else
      p.bootStatus = "CLEARED"
      p.bootError  = nil
    end
  end
  return allIdle
end

function pumps.setMode(mode)
  if MODES[mode] then pumps.state.mode = mode end
  return pumps.state.mode
end

function pumps.init(deps)
  config = deps.config
  sched  = deps.sched
  log    = deps.logger
  list   = {}
  me     = nil
  -- Reset runtime state too. Otherwise a second init inherits the previous
  -- run's snapshot timestamp, and the first delta window is measured against a
  -- baseline that belongs to a different session.
  local st = pumps.state
  st.amounts, st.rates, st.snapshot = {}, {}, {}
  st.lastSnapshotAt, st.throughput  = nil, 0
  st.meOk, st.meError               = false, nil
  st.lastRescanAt, st.meKind        = 0, nil
  return pumps
end

return pumps
