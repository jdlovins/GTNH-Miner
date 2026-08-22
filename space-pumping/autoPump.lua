-- =============================================================================
-- autoPump.lua — GTNH Space Elevator pumping array controller
--
-- Keeps a set of Space Pumping Modules working through a prioritised list of
-- planetary fluids, filling each towards a target derived from your ME fluid
-- cell capacity.
--
--   config.lua     what to pump, how full, and every tunable
--   pumps.lua      hardware, per-pump state machine, assignment
--   ui.lua         the dashboard
--   scheduler.lua  cooperative tasks (shared verbatim with the miner)
--   logger.lua     logging          (shared verbatim with the miner)
--
-- THE SHAPE OF THIS LOOP, AND WHY:
--
--   Nothing here blocks. The old script slept 0.1s per pump inside its
--   assignment loop and then sat in event.pull(1) — with eight pumps the display
--   was frozen most of the time. Waiting now happens inside scheduler tasks,
--   which yield; the loop itself only ever polls and returns.
--
--   The redraw runs BEFORE the work, deliberately. OpenComputers meters direct
--   component calls per tick and serves callers in order, so drawing ahead of
--   the pump calls keeps the UI off the back of the queue. The cost is that a
--   frame shows state from just before this pass, which at four frames a second
--   is not observable. (Same reasoning as the miner's broker loop.)
--
--   Each part runs at its own cadence, from config.tuning: UI ~4x/second,
--   ME read and assignment once a second, hardware rescan every 30s.
--
-- Controls:  N normal   S stairstep   W waterfall   Q quit
-- =============================================================================

local computer = require("computer")
local event    = require("event")

-- Files live in /home on an OpenComputers install. SPACEPUMP_HOME exists so a
-- test harness (or a non-standard install) can point somewhere else.
local BASE = (os.getenv and os.getenv("SPACEPUMP_HOME")) or "/home"
local function load(name) return dofile(BASE .. "/" .. name) end

local config  = load("config.lua")
local sched   = load("scheduler.lua")
local logging = load("logger.lua")
local pumps   = load("pumps.lua")
local ui      = load("ui.lua")

assert(logging and logging.createLogger, "logger.lua not loaded")
local log = logging.createLogger("autopump")

log:info("========== AUTOPUMP STARTUP ==========")

pumps.init({ config = config, sched = sched, logger = log })
ui.init({ config = config, pumps = pumps })

-- A crashed task must not leave a pump stuck in ARMING forever.
sched.onError = function(name, err)
  log:error("[TASK] " .. tostring(name) .. " crashed: " .. tostring(err))
  for _, p in ipairs(pumps.list()) do
    if p.status == "ARMING" and not p.armResult then
      p.armResult = { ok = false, err = "task crashed: " .. tostring(err) }
    end
  end
end

-- ---------------------------------------------------------------------------
-- PRE-LAUNCH
--
-- Close every work gate and wait for the array to go quiet, so we start from a
-- known state. Two things the old preLaunch did that this does not: re-read the
-- entire ME network once a second for a value it discarded, and sleep a flat 5s
-- at the end whether or not anything needed it.
-- ---------------------------------------------------------------------------
local function preLaunch()
  local found = pumps.findPumps()
  if found == 0 then
    ui.shutdown(nil)
    print("No Space Pumping Modules found on the component network.")
    print("")
    print("Check that each module's controller has an Adapter touching it, and")
    print("that its getName() is one of the keys in config.tiers:")
    for name, t in pairs(config.tiers) do print("  " .. name .. "  (" .. t.label .. ")") end
    log:error("no pumps found; exiting")
    return false
  end
  log:info("found " .. found .. " pump(s)")

  pumps.stopAll()

  local deadline = computer.uptime() + config.tuning.quiesceTimeout
  while true do
    local idle = pumps.allIdle()
    local lines = { "Waiting for " .. found .. " module(s) to finish their current cycle...", "" }
    for _, p in ipairs(pumps.list()) do
      lines[#lines + 1] = string.format("  %-5s %-3s  %s", p.short, p.tier, p.bootStatus or "?")
    end
    ui.drawBoot(lines)
    if idle then break end
    if computer.uptime() >= deadline then
      log:warn("pre-launch timed out with modules still busy; starting anyway")
      break
    end
    os.sleep(0.5)   -- boot only; the main loop never sleeps like this
  end
  return true
end

if not preLaunch() then return end

-- ---------------------------------------------------------------------------
-- MAIN LOOP
-- ---------------------------------------------------------------------------

ui.drawStaticFrame()

local running     = true
local target      = pumps.getTarget()
local fluids      = pumps.refreshFluids(target)
local lastUIDraw  = 0
local lastPoll    = computer.uptime()
local lastAssign  = 0
local lastRescan  = computer.uptime()

-- n/N s/S w/W q/Q — the old script only accepted lowercase, so the mode keys
-- silently did nothing with caps lock on.
local KEYS = {
  [110] = "Normal",    [78] = "Normal",
  [115] = "Stairstep", [83] = "Stairstep",
  [119] = "Waterfall", [87] = "Waterfall",
  [113] = "quit",      [81] = "quit",
}

local function mainLoop()
  while running do
    -- 1. Service one event. The timeout is short so the loop keeps spinning;
    --    it is a yield, not a wait.
    local ev = { event.pull(0.05) }
    if ev[1] == "key_down" then
      local action = KEYS[ev[3]]
      if action == "quit" then
        running = false
      elseif action then
        if action ~= pumps.state.mode then
          pumps.setMode(action)
          log:info("mode -> " .. action)
          -- Re-sort and repaint at once rather than waiting out the cadence:
          -- a mode key that takes a second to visibly do anything feels broken.
          lastPoll, lastUIDraw = 0, 0
        end
      end
    end

    local now = computer.uptime()

    -- 2. Redraw first. See the header for why this comes before the work.
    if now - lastUIDraw >= config.tuning.uiInterval then
      ui.draw(fluids, target)
      lastUIDraw = now
    end

    -- 3. Advance in-flight arm tasks, then the pump state machines.
    sched.tick()
    pumps.step()

    -- 4. Re-read the ME network on its own cadence.
    if now - lastPoll >= config.tuning.pollInterval then
      target = pumps.getTarget()
      fluids = pumps.refreshFluids(target)
      lastPoll = now
    end

    -- 5. Hand idle pumps work.
    if now - lastAssign >= config.tuning.assignInterval then
      -- Only dispatch against figures we actually have. A failed ME read leaves
      -- every amount at zero, and assigning off that would point the whole array
      -- at whatever sorts first while the real stock is unknown.
      if pumps.state.meOk then pumps.assign(fluids, target) end
      lastAssign = now
    end

    -- 6. Pick up modules added (or chunks reloaded) since boot.
    if now - lastRescan >= config.tuning.rescanInterval then
      local _, added, removed = pumps.findPumps()
      if added > 0 or removed > 0 then ui.invalidate() end
      lastRescan = now
    end
  end
end

local ok, err = xpcall(mainLoop, debug.traceback)

-- Always leave the array gated off and the terminal usable, crash or clean quit.
pcall(pumps.stopAll)
if ok then
  log:info("clean shutdown")
  ui.shutdown("Pumping stopped. All modules gated off.")
else
  log:error("CRASH: " .. tostring(err))
  ui.shutdown("autoPump crashed - all modules gated off. Details:")
  print(tostring(err))
end
