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
section("broker-mk3.lua editor -- bindings and the unsaved-change count")
-- =============================================================================
local broker = slurp("broker-mk3.lua")

-- THE ASSERTION THAT WOULD HAVE CAUGHT THE ESCAPE BUG.
--
-- The legend is generated from EDKEYS and EDKEYS dispatches into edAction, so
-- every action named in the table has to be one edAction actually handles.
-- Before EDKEYS existed the legend was three hand-written strings, they drifted
-- from the dispatch ladder, and the editor spent a long release telling people
-- to press a key Minecraft never delivers.
local edkeys = broker:match("local EDKEYS = %{.-\n%}")
ck("EDKEYS table found", edkeys ~= nil, true)

local handled = {}
for name in broker:gmatch('a == "([a-z_]+)"') do handled[name] = true end

-- Strip the outer braces before iterating: %b{} on the whole declaration
-- matches the table itself as one balanced pair, not its rows.
local body = edkeys:match("^local EDKEYS = %{(.*)%}$")

local unhandled, advertised = nil, 0
for entry in body:gmatch("%b{}") do
  local action = entry:match('action = "([a-z_]+)"')
  if action and not handled[action] then unhandled = action end
  if entry:find("hint =") then advertised = advertised + 1 end
end
ck("every bound action is handled", unhandled, nil)
ck("the legend is not empty",       advertised > 8, true)

-- Tab must be bound as a cancel, and it must be the one the legend names --
-- q and backspace cannot do this job in a text field.
ck("tab is bound",        edkeys:find("K%.TAB") ~= nil, true)
ck("tab is advertised",   edkeys:find('hint = "tab=back"') ~= nil, true)
ck("escape kept as alias", edkeys:find("K%.ESC") ~= nil, true)
ck("no esc= in the legend", edkeys:find('hint = "[^"]*esc') , nil)

-- edDirtyCount is self-contained: it reads `ed`, `config`, `edGen` and
-- DEFAULT_TARGET and calls nothing. Lift it out and run it against fakes.
local src = broker:match("(local function edDirtyCount%(%).-\n  return n\nend)")
ck("edDirtyCount extracted", src ~= nil, true)

local env = { pairs = pairs, ipairs = ipairs, type = type, DEFAULT_TARGET = 5000000,
              edGen = 0, edDirtyGen = -1, edDirtyCached = 0 }
env.ed, env.config = {}, {}
local chunk = assert(load(src .. "\nreturn edDirtyCount", "edDirtyCount", "t", env))
local dirty = chunk()

-- A freshly loaded editor mirrors config exactly and owes nothing.
local function reset()
  env.edGen = env.edGen + 1
  env.config = {
    conditions  = { { itemName = "Infinity", amountToMaintain = 1000 },
                    { itemName = "Naquadah", amountToMaintain = 2000 } },
    dustTargets = { Infinity = { asteroid = "Infinity Catalyst", priority = 1 } },
    drillPar    = { steel = { tips = 64, rods = 64, batch = 64 } },
    settings    = { tipsPerLoad = 128, fastReload = false },
  }
  env.ed = {
    enabled   = { Infinity = true, Naquadah = true },
    threshold = { Infinity = 1000, Naquadah = 2000 },
    targets   = { Infinity = { asteroid = "Infinity Catalyst", priority = 1 } },
    par       = { steel = { tips = 64, rods = 64, batch = 64 } },
    settings  = { tipsPerLoad = 128, fastReload = false },
  }
end
local function count() env.edGen = env.edGen + 1 return dirty() end

reset() ck("clean editor owes nothing",   count(), 0)
reset() env.ed.settings.tipsPerLoad = 256
        ck("changed setting counts",       count(), 1)
        env.ed.settings.tipsPerLoad = 128
        ck("changed back is clean again",  count(), 0)
reset() env.ed.settings.fastReload = true
        ck("a false->true bool counts",    count(), 1)
reset() env.ed.threshold.Infinity = 9999
        ck("changed threshold counts",     count(), 1)
reset() env.ed.enabled.Naquadah = nil
        ck("untracking an item counts",    count(), 1)
reset() env.ed.enabled.Tengam = true; env.ed.threshold.Tengam = 500
        ck("tracking a new item counts",   count(), 1)
reset() env.ed.targets.Infinity.asteroid = "Somewhere Else"
        ck("remapped dust counts",         count(), 1)
reset() env.ed.par.steel.tips = 32
        ck("changed drill par counts",     count(), 1)
reset() env.ed.par.steel = nil
        ck("dropped drill par counts",     count(), 1)
reset() env.ed.par.titanium = { tips = 64, rods = 64, batch = 64 }
        ck("added drill par counts",       count(), 1)
reset() env.ed.settings.tipsPerLoad = 256; env.ed.threshold.Infinity = 1
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
