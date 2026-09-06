-- =============================================================================
-- run_tests.lua -- desktop Lua tests for the parts of MEDINA that do not need
-- OpenComputers.
--
--   lua space-miner/test/run_tests.lua      (from the repo root)
--
-- WHAT CAN BE TESTED HERE, AND WHY THAT IS NOT EVERYTHING.
--
-- Most files in this repo talk to hardware the moment they load: broker-mk3
-- asserts a modem exists on line 60. What CAN run on a desktop is the code that
-- takes its hardware on a table instead of reaching for `component` -- which is
-- module_api.lua and loader.lua by construction, and settings.lua because it is
-- pure data and validation.
--
-- broker-mk3.lua's editor cannot be loaded, so the two editor checks below read
-- its SOURCE instead: one extracts a single self-contained function and runs it
-- against fakes, the other cross-checks two tables that have to agree. That is
-- less than loading the file, but it is exactly the drift the editor has
-- actually shipped -- a legend advertising a key nothing bound -- and it is
-- worth an assertion.
-- =============================================================================

local ROOT = (arg and arg[0] or ""):match("^(.*)/test/[^/]+$") or "space-miner"

local pass, fail = 0, 0
local function ck(name, got, want)
  if got == want then
    pass = pass + 1
  else
    fail = fail + 1
    print(string.format("FAIL  %-52s got %s  want %s", name, tostring(got), tostring(want)))
  end
end
local function section(s) print("\n-- " .. s) end
local function slurp(rel)
  local f = assert(io.open(ROOT .. "/" .. rel, "r"))
  local s = f:read("*a"); f:close(); return s
end

-- =============================================================================
section("module_api.lua -- the GTNH 2.8 / 2.9 dialect shim")
-- =============================================================================
local api = dofile(ROOT .. "/module_api.lua")

local function fake29()
  local calls = {}
  return { calls = calls, setParameter = function(k, v) calls[#calls+1] = {k, v} end }
end
local function fake28()
  local calls = {}
  return { calls = calls, setParameters = function(i, j, v) calls[#calls+1] = {i, j, v} end }
end

ck("detect 2.9",           api.detect(fake29()), "2.9")
ck("detect 2.8",           api.detect(fake28()), "2.8")
ck("detect neither",       api.detect({}), nil)
ck("detect nil adapter",   api.detect(nil), nil)

local d, how = api.resolve(fake29(), "auto")
ck("resolve auto -> 2.9",  d .. "/" .. how, "2.9/probed")
d, how = api.resolve(fake28(), "auto")
ck("resolve auto -> 2.8",  d .. "/" .. how, "2.8/probed")
d, how = api.resolve(fake29(), "2.8")
ck("override beats probe", d .. "/" .. how, "2.8/forced")
ck("resolve unknown",      (api.resolve({}, "auto")), nil)

-- 2.9 writes three named parameters, in this order. This is the regression
-- guard on the live path: it must keep making exactly the calls it made before
-- module_api.lua existed.
local a = fake29()
local mod29 = { adapter = a, conf = { distanceParam = 0 }, dialect = "2.9" }
ck("2.9 configure ok",     (api.configure(mod29, { distance = 140, parallels = 4 })), true)
ck("2.9 call count",       #a.calls, 3)
ck("2.9 distance",         a.calls[1][1] .. "=" .. tostring(a.calls[1][2]), "distance=140")
ck("2.9 parallel",         a.calls[2][1] .. "=" .. tostring(a.calls[2][2]), "parallel=4")
ck("2.9 cycle",            a.calls[3][1] .. "=" .. tostring(a.calls[3][2]), "cycle=false")

-- 2.8 writes distance only: parallel and cycle live in the module GUI there.
local b = fake28()
ck("2.8 configure ok",     (api.configure({ adapter = b, conf = { distanceParam = 0 }, dialect = "2.8" },
                                          { distance = 140, parallels = 4 })), true)
ck("2.8 call count",       #b.calls, 1)
ck("2.8 args",             table.concat(b.calls[1], ","), "0,0,140")

local c = fake28()
api.configure({ adapter = c, conf = { distanceParam = 3 }, dialect = "2.8" }, { distance = 90 })
ck("2.8 honours the index", c.calls[1][1], 3)

local ok, err = api.configure({ adapter = fake28(), conf = {}, dialect = "2.8" }, { distance = 90 })
ck("2.8 missing index ok",  ok, false)
ck("2.8 missing index says so", err:find("distanceParam") ~= nil, true)

-- A throwing adapter must come back as (false, err), never propagate: this runs
-- inside pollLoad, where a throw takes down every other module.
ok, err = api.configure(
  { adapter = { setParameter = function() error("component is not available") end },
    conf = {}, dialect = "2.9" }, { distance = 1 })
ck("throwing adapter ok",   ok, false)
ck("throwing adapter err",  err:find("setParameter:") ~= nil, true)

ck("nil dialect refused",   (api.configure({ adapter = fake29(), conf = {} }, { distance = 1 })), false)
ck("no distance refused",   (api.configure(mod29, {})), false)

local r28 = fake28()
api.resetDistance({ adapter = r28, conf = { distanceParam = 0 }, dialect = "2.8" })
ck("2.8 reset args",        table.concat(r28.calls[1], ","), "0,0,1")
local r29 = fake29()
api.resetDistance({ adapter = r29, conf = {}, dialect = "2.9" })
ck("2.9 reset args",        r29.calls[1][1] .. "=" .. tostring(r29.calls[1][2]), "distance=1")

ck("describe",              api.describe({ dialect = "2.8", dialectHow = "probed" }), "GTNH 2.8 (probed)")

-- =============================================================================
section("settings.lua -- the tunable registry")
-- =============================================================================
local S = dofile(ROOT .. "/settings.lua")
local cfg = {}
local raw = S.defaults(cfg)

ck("gtVersion default",     cfg.gtVersion, "auto")
ck("nested default",        cfg.logging.file, "/tmp/spacemining.log")
ck("apply maps auto->nil",  cfg.asteroidCap, nil)

ck("merge accepts",         (S.merge(cfg, raw, { gtVersion = "2.8" })).gtVersion, nil)
ck("merge applied",         cfg.gtVersion, "2.8")
ck("merge rejects value",   (S.merge(cfg, raw, { gtVersion = "2.7" })).gtVersion ~= nil, true)
ck("merge rejects key",     (S.merge(cfg, raw, { nosuchknob = 1 })).nosuchknob, "unknown setting")
ck("bad value not applied", cfg.gtVersion, "2.8")

ck("gtVersion is not a node setting", S.nodePayload(raw).gtVersion, nil)
ck("dustScanInterval is",             S.nodePayload(raw).dustScanInterval, 10)

ck("int bounds refuse low",  (S.coerce(S.byKey.tipsPerLoad, 0)), nil)
ck("int bounds refuse high", (S.coerce(S.byKey.tipsPerLoad, 99999)), nil)
ck("bool from string",       S.coerce(S.byKey.fastReload, "true"), true)
ck("choice cycles",          S.cycle(S.byKey.gtVersion, "auto"), "2.9")
ck("choice wraps",           S.cycle(S.byKey.gtVersion, "2.8"), "auto")

-- Every declared setting must survive a defaults -> coerce round trip. A knob
-- whose own default is out of its own bounds ships broken and nothing else here
-- would notice.
local badDefault
for key, spec in pairs(S.byKey) do
  if S.coerce(spec, spec.default) == nil then badDefault = key break end
end
ck("every default is legal", badDefault, nil)

-- =============================================================================
section("editor.lua -- bindings and the unsaved-change count")
-- =============================================================================
-- This section used to scrape functions out of broker-mk3.lua with regexes,
-- because that file asserts a modem on line 60 and cannot be loaded on a
-- desktop. The editor is its own module now and takes its dependencies through
-- init(), so the tests load the REAL thing and call the REAL functions.
local editor = dofile(ROOT .. "/editor.lua")

-- Nothing here touches hardware; gpu is nil and the paint functions are simply
-- never called. W >= 90 so the drills page believes it has a wide screen.
local gen = 0
local edcfg = {
  settingsSpec = S,
  conditions  = {}, dustTargets = {}, drillPar = {}, settings = {},
  drones = {}, drills = {}, asteroids = {},
}
editor.init{
  config = edcfg, gpu = nil, W = 120, H = 50,
  brokerState = { dust = {}, drones = {}, drills = {} },
  drillKeyOrder = {}, usableDrillKeys = function() return {} end,
  formatQty = tostring, drawStaticFrame = function() end,
  resetDustScroll = function() end,
  edTouch = function() gen = gen + 1 end,
  edGen = function() return gen end,
}
ck("editor loads without hardware", type(editor.init), "function")
ck("editor exposes isOpen",         type(editor.isOpen), "function")
ck("editor starts closed",          editor.isOpen(), false)

local E = editor._internal

-- THE ASSERTION THAT WOULD HAVE CAUGHT THE ESCAPE BUG.
--
-- The legend is generated from EDKEYS and EDKEYS dispatches into edAction, so
-- every action named in the table has to be one edAction actually handles.
-- Before EDKEYS existed the legend was three hand-written strings, they drifted
-- from the dispatch ladder, and the editor spent a long release telling people
-- to press a key Minecraft never delivers.
--
-- EDKEYS is a real table here; the set of handled actions still comes from the
-- source, because edAction is an if/elseif chain with no else and an unknown
-- action is silently a no-op rather than an error.
local edsrc = slurp("editor.lua")
local handled = {}
for name in edsrc:gmatch('a == "([a-z_]+)"') do handled[name] = true end

local unhandled, advertised, tabBound, tabHinted, escAlias, escHinted = nil, 0, false, false, false, false
for _, bind in ipairs(E.EDKEYS) do
  if bind.action and not handled[bind.action] then unhandled = bind.action end
  if bind.hint then
    advertised = advertised + 1
    if bind.hint == "tab=back" then tabHinted = true end
    if bind.hint:find("esc") then escHinted = true end
  end
  if bind.code == E.K.TAB then tabBound = true end
  if bind.code == E.K.ESC then escAlias = true end
end
ck("every bound action is handled", unhandled, nil)
ck("the legend is not empty",       advertised > 8, true)

-- Tab must be bound as a cancel, and it must be the one the legend names --
-- q and backspace cannot do this job in a text field.
ck("tab is bound",          tabBound, true)
ck("tab is advertised",     tabHinted, true)
ck("escape kept as alias",  escAlias, true)
ck("no esc= in the legend", escHinted, false)

-- isCancelKey is what the broker's quiesce countdown asks, so the two cannot
-- drift. Every alias must answer yes; an ordinary key must not.
ck("tab cancels",       editor.isCancelKey(nil, E.K.TAB), true)
ck("escape cancels",    editor.isCancelKey(nil, E.K.ESC), true)
ck("backspace cancels", editor.isCancelKey(nil, E.K.BACKSPACE), true)
ck("q cancels",         editor.isCancelKey(113, nil), true)
ck("s does not cancel", editor.isCancelKey(115, nil), false)

-- Requests are drained, not merely read: the broker broadcasts on them, so a
-- read that left the flag set would rebroadcast every pass.
local w, pr, n = editor.takeRequests()
ck("no requests pending at rest", (w or pr or n) and true or false, false)

-- edDirtyCount against the module's own working copies.
local ed = E.ed
local function reset()
  gen = gen + 1
  edcfg.conditions  = { { itemName = "Infinity", amountToMaintain = 1000 },
                        { itemName = "Naquadah", amountToMaintain = 2000 } }
  edcfg.dustTargets = { Infinity = { asteroid = "Infinity Catalyst", priority = 1 } }
  edcfg.drillPar    = { steel = { tips = 64, rods = 64, batch = 64 } }
  edcfg.settings    = { tipsPerLoad = 128, fastReload = false }
  ed.enabled   = { Infinity = true, Naquadah = true }
  ed.threshold = { Infinity = 1000, Naquadah = 2000 }
  ed.targets   = { Infinity = { asteroid = "Infinity Catalyst", priority = 1 } }
  ed.par       = { steel = { tips = 64, rods = 64, batch = 64 } }
  ed.settings  = { tipsPerLoad = 128, fastReload = false }
end
local function count() gen = gen + 1 return E.dirtyCount() end

reset() ck("clean editor owes nothing",   count(), 0)
reset() ed.settings.tipsPerLoad = 256
        ck("changed setting counts",       count(), 1)
        ed.settings.tipsPerLoad = 128
        ck("changed back is clean again",  count(), 0)
reset() ed.settings.fastReload = true
        ck("a false->true bool counts",    count(), 1)
reset() ed.threshold.Infinity = 9999
        ck("changed threshold counts",     count(), 1)
reset() ed.enabled.Naquadah = nil
        ck("untracking an item counts",    count(), 1)
reset() ed.enabled.Tengam = true; ed.threshold.Tengam = 500
        ck("tracking a new item counts",   count(), 1)
reset() ed.targets.Infinity.asteroid = "Somewhere Else"
        ck("remapped dust counts",         count(), 1)
reset() ed.par.steel.tips = 32
        ck("changed drill par counts",     count(), 1)
reset() ed.par.steel = nil
        ck("dropped drill par counts",     count(), 1)
reset() ed.par.titanium = { tips = 64, rods = 64, batch = 64 }
        ck("added drill par counts",       count(), 1)
reset() ed.settings.tipsPerLoad = 256; ed.threshold.Infinity = 1
        ck("changes add up",               count(), 2)

-- =============================================================================
section("broker-mk3.lua -- the drone / kit availability pool")
-- =============================================================================
-- availableDrones and availableKits read only brokerState, modules and config,
-- so they lift out the same way edDirtyCount does. These are the regression
-- guards on the reserveWhileMining double-charge: with reserveWhileMining on,
-- a busy module used to be charged even when the ME sweep had ALREADY stopped
-- counting its drone, so the pool went negative and a genuinely free drone
-- would not dispatch.
-- availableDrones/availableKits stayed in the broker -- they are dispatch, not
-- editing -- so these still come out of its source.
local broker = slurp("broker-mk3.lua")
local poolSrc = broker:match("(local HW_STALE = .-\nlocal function availableKits.-\n  return avail\nend)")
ck("pool functions extracted", poolSrc ~= nil, true)

local penv = { pairs = pairs, ipairs = ipairs, math = math, tostring = tostring }
local pchunk = assert(load(
  poolSrc .. "\nreturn availableDrones, availableKits", "pool", "t", penv))
local availableDrones, availableKits = pchunk()

local NOW = 1000
penv.computer = { uptime = function() return NOW end }

-- `sweptAt` is when the last hw sweep landed; a job dispatched at or before it
-- has already been excluded from the reported stock. Keep sweptAt within
-- HW_STALE (30) of NOW for the cases that mean "telemetry is current" -- past
-- that, strict mode deliberately stops trusting the figure and charges
-- everything, which is its own test below.
local function world(stock, mods, sweptAt, kits)
  penv.brokerState = { drones = stock, drills = kits or {}, lastHWSyncTime = sweptAt }
  penv.modules = mods
  penv.config = { fastReload = true, tipsPerLoad = 64, rodsPerLoad = 64 }
end
local function busy(droneKey, dispatchedAt, drillKey)
  return { status = "RUNNING",
           job = { droneKey = droneKey, drillKey = drillKey, dispatchedAt = dispatchedAt } }
end
local function holding(droneKey, drillKey)
  return { status = "IDLE", job = nil, holding = { droneKey = droneKey, drillKey = drillKey } }
end

-- THE REPORTED BUG. One UHV owned, one module running it, dispatched before the
-- last sweep -- so stock already reads 0. Charging it again gave -1.
world({ uhv = 0 }, { busy("uhv", 900) }, 990)
ck("pre-sweep job is not charged twice", availableDrones(true).uhv, 0)

-- Dispatched AFTER the sweep: stock still lists it, so it must be charged.
world({ uhv = 1 }, { busy("uhv", 995) }, 990)
ck("post-sweep job is charged",          availableDrones(true).uhv, 0)

-- THE CASE FLOORING ALONE CANNOT FIX. Two LuV busy and pre-sweep, then a third
-- lands from crafting so stock reads 1. Double-charging gave 1-2 = -1 and the
-- free drone would not dispatch; flooring turns that into 0, still wrong.
world({ luv = 1 }, { busy("luv", 900), busy("luv", 910) }, 990)
ck("restocked drone stays dispatchable", availableDrones(true).luv, 1)

-- The user's exact fleet: 2 LuV + 1 UHV, one of each mining, sweep has landed.
world({ luv = 1, uhv = 0 }, { busy("luv", 900), busy("uhv", 900) }, 990)
local free = availableDrones(true)
ck("reported fleet: luv free", free.luv, 1)
ck("reported fleet: uhv free", free.uhv, 0)

-- A held drone is owned: invisible to the ME (it is in the bus) and to the busy
-- scan (job is nil, status IDLE), so without the credit it vanished entirely.
world({ uhv = 0 }, { holding("uhv", "naquadah") }, 990)
ck("held drone counts as free",  availableDrones(true).uhv, 1)
ck("held drone counted ONCE",    availableDrones(false).uhv, 1)

-- Holds are only real when fastReload is on; otherwise stepDone returned it.
world({ uhv = 0 }, { holding("uhv", "naquadah") }, 990)
penv.config.fastReload = false
ck("no hold credit without fastReload", availableDrones(true).uhv, 0)
penv.config.fastReload = true

-- The pool never goes negative, whatever the arithmetic upstream said.
world({ uhv = 0 }, { busy("uhv", 995), busy("uhv", 996) }, 990)
ck("pool is floored at zero", availableDrones(true).uhv, 0)

-- What strict still buys. If the hw node goes quiet the FIGURE is stale, so no
-- commitment counts as seen and every one is charged again -- the conservative
-- direction. Non-strict keeps trusting the timestamp.
world({ uhv = 1 }, { busy("uhv", 900) }, 900)      -- swept 100s ago, HW_STALE is 30
ck("strict charges when telemetry is stale",   availableDrones(true).uhv,  0)
ck("non-strict trusts the sweep",              availableDrones(false).uhv, 1)

-- Kits move the same way, in units of a full load.
world({}, { busy("uhv", 900, "naquadah") }, 990, { naquadah = { kits = 64 } })
ck("pre-sweep kits not charged twice", availableKits(true).naquadah, 64)
world({}, { busy("uhv", 995, "naquadah") }, 990, { naquadah = { kits = 64 } })
ck("post-sweep kits charged",          availableKits(true).naquadah, 0)
world({}, { holding("uhv", "naquadah") }, 990, { naquadah = { kits = 0 } })
ck("held kits count as free",          availableKits(true).naquadah, 64)

-- =============================================================================
print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
