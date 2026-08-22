-- =============================================================================
-- SPACE PUMPING — CONFIGURATION
--
-- Everything tunable lives here. The programs (autoPump / pumps / ui) read this
-- file and never hardcode a threshold, colour or interval of their own.
--
-- ONE CLOCK: every interval below is in REAL SECONDS, measured against
-- computer.uptime(). There are no tick-based values in this file. The old
-- script mixed os.time() world-ticks with os.sleep() real seconds, which is why
-- its "120 ticks = ~6s" comment could never have been right.
-- =============================================================================

local config = {}

-- ===================== CORE =================================================
-- currentCellType   : which CELL_CAPACITIES entry backs this fluid subnet.
-- safetyMargin      : fraction of capacity held back (0.20 = fill to 80%).
-- maxTargetOverride : 0 = derive the target from the cell type (normal).
--                     Non-zero forces a flat target, for testing at small
--                     scales. Ships at 0 on purpose — a shipped override is a
--                     footgun, because it silently ignores your cell choice.
config.currentCellType   = "16384k"
config.safetyMargin      = 0.20
config.maxTargetOverride = 0

-- ME Fluid Cell capacities, in litres.
config.CELL_CAPACITIES = {
  ["1k"]      = 2080000,      -- 2.08M L
  ["4k"]      = 8320000,      -- 8.32M L
  ["16k"]     = 33300000,     -- 33.3M L
  ["64k"]     = 133000000,    -- 133M L
  ["256k"]    = 533000000,    -- 533M L
  ["1024k"]   = 2130000000,   -- 2.13G L
  ["4096k"]   = 8520000000,   -- 8.52G L
  ["16384k"]  = 34100000000,  -- 34.1G L
  ["Quantum"] = 275000000000, -- 275G L
}

-- ===================== ME NETWORK SOURCE ====================================
-- Where stock figures come from. Each entry is an OpenComputers component type
-- exposing getFluidsInNetwork(); the first one present on the network wins.
--
-- The normal setup is an Adapter touching a DUAL ME INTERFACE on the fluid
-- subnet, which registers as `fluid_interface`. An ME Controller works too.
--
-- If none of these match, the program SCANS every component for one that has
-- getFluidsInNetwork() and uses it, logging what it found so you can add the
-- name here. This list is an optimisation, not a requirement — a name that is
-- merely wrong costs a scan, not a failure.
--
-- Whichever you use, it must belong to the network holding your fluid cells.
-- Point it at the main base network and every fill percentage will be wrong.
config.meComponents = { "fluid_interface", "me_interface", "me_controller" }

-- ===================== PUMP TIERS ===========================================
-- Keyed by the module's getName(). Add a row here to support a modded tier — an
-- unrecognised gt_machine is ignored rather than guessed at.
--
--   threads : parallel extraction threads, i.e. how many {planet,slot} pairs the
--             module accepts. Drives the setParameters writes.
--   mult    : throughput multiplier. Used for the estimated-rate readout beside
--             a working pump, and to rank pumps by capacity so the biggest one
--             gets the biggest shortfall.
config.tiers = {
  ["projectmodulepumpt1"] = { label = "T1", threads = 1, mult = 4   },
  ["projectmodulepumpt2"] = { label = "T2", threads = 4, mult = 16  },
  ["projectmodulepumpt3"] = { label = "T3", threads = 4, mult = 256 },
}

-- ===================== MODULE PARAMETER KEYS ================================
-- How to address a pumping module's settings. Read off a live T1 with
-- getParameters(), which returned exactly:
--
--   batch                1
--   recipe0.gasType      1
--   recipe0.parallel     4
--   recipe0.planetType   1
--
-- `recipe` is a format string taking the zero-based slot index. A T1 has one
-- slot, higher tiers have more; the real count is read from the machine at
-- discovery rather than assumed from the tier.
--
-- These exist as config because GTNH has already renamed this API once: the
-- indexed setParameters(i, j, value) the original script used is simply gone.
-- If it is renamed again, this table is the only thing that needs to change.
config.paramKeys = {
  recipe   = "recipe%d",
  planet   = ".planetType",
  gas      = ".gasType",
  parallel = ".parallel",
  batch    = "batch",
}

-- ===================== TUNING (all real seconds) ============================
config.tuning = {
  -- How often the ME network is re-read and the fluid list re-sorted.
  pollInterval       = 1.0,

  -- How often idle pumps are handed new work.
  assignInterval     = 1.0,

  -- How often the dashboard repaints. The row cache means an unchanged row
  -- costs nothing, so this can be brisk without burning GPU calls.
  uiInterval         = 0.25,

  -- Growth and throughput are measured over this window. Longer is smoother and
  -- less noisy; shorter is twitchier but more responsive.
  snapshotInterval   = 6.0,

  -- Arming a pump: enable work, wait for isMachineActive() to confirm the cycle
  -- actually started, then disable again. Confirm-by-readback rather than a
  -- fixed sleep — instant on a fast server, patient on a laggy one.
  armTimeout         = 5.0,
  armPollInterval    = 0.1,

  -- RUNNING watchdog. A pump must read inactive this many consecutive polls
  -- before the job is called finished, so one unlucky poll cannot bounce a pump
  -- that is working fine.
  runPollInterval    = 0.5,
  runInactiveConfirm = 3,

  -- After an ERROR, wait this long before the pump is offered work again.
  errorCooldown      = 10.0,

  -- Re-scan the component network for pumps on this cadence, so a module added
  -- (or a chunk reloaded) is picked up without a restart.
  rescanInterval     = 30.0,

  -- Written to the module's `batch` parameter on each arm. The original script
  -- pushed 30 through the old indexed API; `batch` is the only non-recipe
  -- parameter the machine exposes, so this is its successor. Set to 0 to leave
  -- whatever the module already has.
  batch              = 30,

  -- Written to every recipe slot's `parallel`. Modules ship with a sensible
  -- value already (a T1 reads 4), so the default is 0 = do not touch it.
  parallel           = 0,

  -- A fluid short by less than this fraction of the target is not worth
  -- occupying a pump with; a genuinely empty one gets the pump instead.
  minDeficitFraction = 0.002,   -- 0.2% of target

  -- Boot: how long to wait for every pump to report idle before starting.
  quiesceTimeout     = 30.0,
}

-- ===================== UI ===================================================
config.ui = {
  -- Fill-percentage colour bands, checked in order; the first band whose `under`
  -- exceeds the fill % wins. The last entry is the catch-all.
  fillColors = {
    { under = 50,        color = 0xFF6666 },  -- critical shortage
    { under = 95,        color = 0xFFCC33 },  -- ramping
    { under = 110,       color = 0x00FF00 },  -- at target
    { under = math.huge, color = 0xCC00FF },  -- over target (headroom, harmless)
  },
  fluidColumns = 3,     -- demand-queue column count
  maxFluidRows = 40,    -- most fluid rows to draw at all
  deltaRows    = 3,     -- entries shown under TOP GROWTH / TOP REDUCTIONS
}

-- ===================== LOGGING ==============================================
-- Read by logger.lua. With enabled=false it still records ERROR and WARN to the
-- file, so a fresh install leaves a trail when something breaks.
config.logging = {
  enabled      = false,
  backend      = "file",            -- "file" | "console" | "loki"
  file         = "/tmp/spacepump.log",
  maxFileBytes = 65536,
  lokiHost     = "127.0.0.1",
  lokiPort     = 3100,
  bootUnixTime = 0,
}

-- ===================== FLUID MASTER LIST ====================================
-- One row per fluid this station can pump.
--
--   priority : 0-5. Higher is pumped sooner among fluids that are below target.
--   setting  : {planetType, gasType} — the two values written to the module's
--              recipe slot. Both are the indices the module itself uses, and
--              they MUST match your station: a wrong pair means the module runs
--              happily and nothing arrives. Read the current pair off a module
--              you have set by hand with `diag pumps`.
--   rate     : throughput estimate, used ONLY for the "/t" figure shown beside a
--              working pump. It does not affect what gets pumped or how fast.
--              Sourced from the GTNH wiki; treat it as indicative, not exact.
--
-- Current stock is NOT stored here. Runtime state lives in pumps.lua, so this
-- file stays pure data and can be re-read without carrying stale amounts.
config.master = {
  -- Planet 2
  ['Chlorobenzene']     = {priority=0, setting={2,1},  rate=44800},
  -- Planet 3
  ['Ender Goo']         = {priority=0, setting={3,1},  rate=1600},
  ['Very Heavy Oil']    = {priority=0, setting={3,2},  rate=70000},
  ['Lava']              = {priority=0, setting={3,3},  rate=90000},
  ['Natural Gas']       = {priority=0, setting={3,4},  rate=70000},
  -- Planet 4
  ['Sulfuric Acid']     = {priority=5, setting={4,1},  rate=39200},
  ['Molten Iron']       = {priority=0, setting={4,2},  rate=44800},
  ['Oil']               = {priority=4, setting={4,3},  rate=70000},
  ['Heavy Oil']         = {priority=0, setting={4,4},  rate=89600},
  ['Molten Lead']       = {priority=0, setting={4,5},  rate=44800},
  ['Raw Oil']           = {priority=0, setting={4,6},  rate=70000},
  ['Light Oil']         = {priority=0, setting={4,7},  rate=39000},
  ['Carbon Dioxide']    = {priority=0, setting={4,8},  rate=84000},
  -- Planet 5
  ['Carbon Monoxide']   = {priority=0, setting={5,1},  rate=224000},
  ['Helium-3']          = {priority=4, setting={5,2},  rate=140000},
  ['Salt Water']        = {priority=0, setting={5,3},  rate=140000},
  ['Helium']            = {priority=5, setting={5,4},  rate=70000},
  ['Liquid Oxygen']     = {priority=0, setting={5,5},  rate=44800},
  ['Neon']              = {priority=0, setting={5,6},  rate=1600},
  ['Argon']             = {priority=0, setting={5,7},  rate=1600},
  ['Krypton']           = {priority=0, setting={5,8},  rate=400},
  ['Methane']           = {priority=2, setting={5,9},  rate=89600},
  ['Hydrogen Sulfide']  = {priority=0, setting={5,10}, rate=19600},
  ['Ethane']            = {priority=0, setting={5,11}, rate=59700},
  -- Planet 6
  ['Deuterium']         = {priority=5, setting={6,1},  rate=78400},
  ['Tritium']           = {priority=5, setting={6,2},  rate=12000},
  ['Ammonia']           = {priority=4, setting={6,3},  rate=12000},
  ['Xenon']             = {priority=5, setting={6,4},  rate=800},
  ['Ethylene']          = {priority=2, setting={6,5},  rate=89600},
  -- Planet 7
  ['Hydrofluoric Acid'] = {priority=4, setting={7,1},  rate=33600},
  ['Fluorine']          = {priority=4, setting={7,2},  rate=89600},
  ['Nitrogen']          = {priority=2, setting={7,3},  rate=89600},
  ['Oxygen']            = {priority=2, setting={7,4},  rate=86450},
  -- Planet 8
  ['Hydrogen']          = {priority=5, setting={8,1},  rate=78400},
  ['Liquid Air']        = {priority=0, setting={8,2},  rate=43750},
  ['Molten Copper']     = {priority=0, setting={8,3},  rate=33600},
  ['Unknown Liquid']    = {priority=4, setting={8,4},  rate=33600},
  ['Distilled Water']   = {priority=5, setting={8,5},  rate=896000},
  ['Radon']             = {priority=5, setting={8,6},  rate=3200},
  ['Molten Tin']        = {priority=0, setting={8,7},  rate=33600},
}

-- ===================== WHAT TO KEEP STOCKED =================================
-- config.master above is the MAPPING: where each fluid comes from. This is the
-- PREFERENCE: which of them you actually want, and how much of each.
--
-- Same split as the miner's dustTargets/conditions, and for the same reason —
-- "Hydrogen comes from planet 8 slot 1" stays true whether or not you currently
-- want Hydrogen right now.
--
--   key   : a label from config.master
--   value : litres to maintain, or `true` to use the global cell-derived target
--
-- AN EMPTY TABLE MEANS "everything in config.master, at the global target" —
-- what this program did before per-fluid amounts existed. So a fresh install
-- behaves exactly as it always has until you choose otherwise.
--
-- Edit this in game: press E on the dashboard. That writes /home/user_config.lua
-- rather than this file, so your choices survive re-running install-pump.
config.wanted = {}
config.wantedExplicit = false

--------------------------------------------------------------------------------
-- USER OVERLAY
--
-- Everything above this line is SHIPPED data and gets refreshed wholesale by
-- install-pump, so nothing you change in game may live here.
--
-- Your choices live in /home/user_config.lua, which only the in-game editor ever
-- writes. One writer per file, so the two can never clobber each other. The
-- overlay is optional — with no user_config.lua the shipped defaults are used.
--
--   wanted  REPLACED by yours if present. What you stock is entirely your call.
--   master  MERGED per fluid, so a {planet, slot} you corrected in game wins
--           while every fluid you have not touched keeps following this file.
--------------------------------------------------------------------------------
do
  local ok, user = pcall(dofile, "/home/user_config.lua")
  if ok and type(user) == "table" then
    if type(user.master) == "table" then
      for label, m in pairs(user.master) do
        if type(m) == "table" then
          local base = config.master[label] or {}
          config.master[label] = {
            priority = m.priority or base.priority or 0,
            setting  = m.setting  or base.setting,
            rate     = m.rate     or base.rate or 0,
          }
        end
      end
    end
    if type(user.wanted) == "table" then
      config.wanted = user.wanted
      -- The presence of the file is the choice, not the size of the table. An
      -- empty list here means "stock nothing"; the empty default above means
      -- "stock everything". See pumps.hasWantedList().
      config.wantedExplicit = true
    end
  end
end

return config
