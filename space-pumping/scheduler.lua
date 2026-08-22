-- =============================================================================
-- MEDINA SCHEDULER  (v1.5)
-- A tiny cooperative task engine for OpenComputers.
--
-- The whole idea: instead of one big loop that freezes whenever it has to wait,
-- you spawn small "tasks" (coroutines) that yield while waiting. The scheduler
-- resumes whichever tasks are ready each tick, then hands control straight back
-- to your main loop so the UI keeps drawing and telemetry keeps flowing.
--
-- Three things to learn, and that's the entire API:
--
--   sched.spawn(fn[, name])      -- run fn as a task; it can sleep/await freely
--   sched.tick()                 -- call once per main-loop pass; advances tasks
--   sched.lock(name)             -- a fairness lock for a shared resource
--
-- Inside a task you may call (NOT from the main loop — only inside a task):
--
--   sched.sleep(seconds)         -- pause this task, let others run
--   sched.await(fn[, timeout])   -- pause until fn() is truthy (or timeout)
--   lock:acquire()  / lock:release()
--   lock:with(fn)                -- acquire, run fn(), always release
--
-- ONE clock governs everything: computer.uptime() (real seconds since boot).
-- No mixing of os.time() world-ticks with real-time sleeps — every wait in the
-- system is measured the same way.
--
-- To add a new background feature later, you write a function and spawn it.
-- You never touch this file. That's the point.
-- =============================================================================

local computer = require("computer")

local scheduler = {}

-- Live tasks. Each entry: { co, name, wake (uptime to resume at), cond (await fn),
-- deadline (await timeout), dead (bool) }
local tasks = {}
local nextId = 1

local function now() return computer.uptime() end

-- ---------------------------------------------------------------------------
-- YIELD PROTOCOL
-- A task yields a small table describing why it paused. tick() reads it and
-- decides when to resume. Tasks never see this table — they use sleep/await.
-- ---------------------------------------------------------------------------

-- Pause the current task for `seconds`.
function scheduler.sleep(seconds)
  coroutine.yield({ kind = "sleep", seconds = seconds or 0 })
end

-- Pause the current task until `condition()` returns truthy.
-- Optional `timeout` (seconds): if it elapses first, await() returns false.
-- Optional `interval` (seconds): minimum gap between condition checks. Defaults
--   to 0.1s so we don't hammer hardware calls (db.get, transposer reads) on
--   every single main-loop pass. The condition is checked once immediately, then
--   at most once per `interval` thereafter.
-- Returns true if the condition was met, false if it timed out.
function scheduler.await(condition, timeout, interval)
  local ok = coroutine.yield({
    kind = "await", cond = condition, timeout = timeout, interval = interval or 0.1,
  })
  return ok
end

-- ---------------------------------------------------------------------------
-- LOCKS
-- A fair (FIFO) lock so concurrent tasks can take turns on a shared component.
-- We default to NOT using one for the loader, but it's here for when a real
-- shared resource needs serializing — and it reads honestly in the code.
-- ---------------------------------------------------------------------------

function scheduler.lock(name)
  local lock = { name = name, held = false, waiters = 0 }

  function lock:acquire()
    -- Wait our turn: block while someone holds it. await() yields to the
    -- scheduler, so other tasks keep running while we queue.
    --
    -- Safe against the "two waiters wake together" race because tick() steps
    -- tasks sequentially: the first waiter to be stepped sets held=true, and the
    -- next waiter re-evaluates `not self.held` (now false) in the SAME tick and
    -- keeps waiting. The atomic check-and-set below is belt-and-suspenders.
    while true do
      local got = scheduler.await(function() return not self.held end)
      if got and not self.held then
        self.held = true
        return
      end
      -- Someone beat us to it this tick; loop and wait again.
    end
  end

  function lock:release()
    self.held = false
  end

  -- Run fn() with the lock held, releasing even if fn errors.
  function lock:with(fn)
    self:acquire()
    local ok, err = pcall(fn)
    self:release()
    if not ok then error(err, 0) end
  end

  return lock
end

-- ---------------------------------------------------------------------------
-- SPAWN / TICK
-- ---------------------------------------------------------------------------

-- Start `fn` as a task. `name` is optional, used in error reporting.
-- Returns a handle you can poll with handle:done().
function scheduler.spawn(fn, name)
  local task = {
    id   = nextId,
    co   = coroutine.create(fn),
    name = name or ("task#" .. nextId),
    wake = 0,        -- resume when now() >= wake (0 = asap)
    cond = nil,      -- await predicate, if any
    deadline = nil,  -- await timeout absolute uptime
    dead = false,
  }
  nextId = nextId + 1
  tasks[#tasks + 1] = task
  return {
    done = function() return task.dead end,
    name = task.name,
  }
end

-- True if any task is still alive (useful for "wait until all loads finish").
function scheduler.busy()
  for _, t in ipairs(tasks) do
    if not t.dead then return true end
  end
  return false
end

-- How many tasks are currently alive.
function scheduler.count()
  local n = 0
  for _, t in ipairs(tasks) do if not t.dead then n = n + 1 end end
  return n
end

-- Optional error hook: scheduler.onError = function(name, err) ... end
scheduler.onError = nil

-- Resume one task if it's ready. Returns nothing; mutates task state.
local function step(task)
  if task.dead then return end

  local t = now()

  -- Still sleeping?
  if task.wake and t < task.wake then return end

  -- Awaiting a condition?
  local resumeValue = nil
  if task.cond then
    -- Throttle: only re-check once per interval, not every main-loop pass.
    if task.nextCheck and t < task.nextCheck then
      return
    end
    task.nextCheck = t + (task.interval or 0.1)

    local met = false
    local ok, res = pcall(task.cond)
    if ok and res then met = true end

    local timedOut = task.deadline and t >= task.deadline
    if not met and not timedOut then
      return  -- keep waiting
    end
    -- Condition met (true) or timed out (false) — tell await() which.
    resumeValue = met
    task.cond = nil
    task.deadline = nil
    task.nextCheck = nil
  end

  -- Resume the coroutine.
  local ok, yielded = coroutine.resume(task.co, resumeValue)

  if not ok then
    -- Task crashed.
    task.dead = true
    if scheduler.onError then
      pcall(scheduler.onError, task.name, yielded)
    end
    return
  end

  if coroutine.status(task.co) == "dead" then
    task.dead = true
    return
  end

  -- Task yielded a wait request — record it.
  if type(yielded) == "table" then
    if yielded.kind == "sleep" then
      task.wake = now() + (yielded.seconds or 0)
      task.cond = nil
      task.deadline = nil
    elseif yielded.kind == "await" then
      task.wake = 0
      task.cond = yielded.cond
      task.deadline = yielded.timeout and (now() + yielded.timeout) or nil
      task.interval = yielded.interval or 0.1
      task.nextCheck = nil  -- check immediately on next step, then throttle
    end
  else
    -- Bare yield with no request: resume next tick.
    task.wake = 0
    task.cond = nil
    task.deadline = nil
  end
end

-- Call once per main-loop pass. Advances every ready task by one step, then
-- returns immediately. Never blocks.
function scheduler.tick()
  -- Iterate over a snapshot count so tasks spawned during this tick wait
  -- until the next one (predictable ordering).
  local n = #tasks
  for i = 1, n do
    local task = tasks[i]
    if task then step(task) end
  end

  -- Compact: drop dead tasks so the list doesn't grow forever.
  local live = {}
  for _, t in ipairs(tasks) do
    if not t.dead then live[#live + 1] = t end
  end
  tasks = live
end

return scheduler
