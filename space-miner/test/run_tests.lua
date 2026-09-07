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

-- resolve() no longer probes: there is no "auto" to resolve, because the drone
-- label half of this split has nothing to probe for. The setting IS the answer,
-- and it beats the hardware -- which detect() is now only allowed to warn about.
local d, how = api.resolve(fake29(), "2.9")
ck("resolve 2.9",          d .. "/" .. how, "2.9/configured")
d, how = api.resolve(fake28(), "2.8")
ck("resolve 2.8",          d .. "/" .. how, "2.8/configured")
d, how = api.resolve(fake29(), "2.8")
ck("setting beats probe",  d .. "/" .. how, "2.8/configured")
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

-- --- the drone tier marker -------------------------------------------------
-- The half of the 2.8/2.9 split that cannot be probed, which is why the version
-- is configured. See the module_api header.
ck("mark 2.8",              api.mark("2.8"), "MK")
ck("mark 2.9",              api.mark("2.9"), "Mk")
ck("mark unknown -> 2.9",   api.mark("2.7"), "Mk")

-- THE MIDDLE ROW. 2.9 before beta 3 speaks the 2.9 parameter API but still
-- names drones the 2.8 way, so version and dialect are genuinely two facts.
-- Every assertion in this block is one the old one-string model could not state.
ck("pre-b3 marker is 2.8's",  api.mark("2.9-pre-b3"), "MK")
ck("pre-b3 dialect is 2.9's", api.dialect("2.9-pre-b3"), "2.9")
ck("2.8 dialect",             api.dialect("2.8"), "2.8")
ck("2.9 dialect",             api.dialect("2.9"), "2.9")
ck("unknown has no dialect",  api.dialect("2.7"), nil)
ck("three versions offered",  #api.VERSIONS, 3)
ck("relabel to 2.9",        api.relabel("Mining Drone MK-IX (UHV)", "2.9"),
                            "Mining Drone Mk-IX (UHV)")
ck("relabel to 2.8",        api.relabel("Mining Drone Mk-IX (UHV)", "2.8"),
                            "Mining Drone MK-IX (UHV)")
-- Idempotence is load-bearing: config.lua relabels at load and the boot prompt
-- relabels again with the operator's answer, over the same table.
ck("relabel idempotent",    api.relabel(api.relabel("Mining Drone MK-I (LV)", "2.9"), "2.9"),
                            "Mining Drone Mk-I (LV)")
-- Anchored, so it cannot chew on a drill or an asteroid's module tier -- the
-- editor's asteroid rows print "MK-2" for a module and must not follow drones.
ck("relabel leaves others", api.relabel("MK-II", "2.9"), "MK-II")

-- resolve() takes the setting and nothing else now.
local resolved, how = api.resolve(fake29(), "2.8")
ck("resolve honours setting", resolved, "2.8")
ck("resolve says configured", how, "configured")
ck("resolve refuses unknown", (api.resolve(fake29(), "auto")), nil)
-- resolve TRANSLATES version -> dialect. Handing the setting back verbatim
-- would put "2.9-pre-b3" in mod.dialect, and configure() would refuse every job
-- on a pre-beta-3 fleet with "unknown module API dialect".
ck("resolve translates pre-b3", (api.resolve(fake29(), "2.9-pre-b3")), "2.9")
ck("pre-b3 configures as 2.9",
   api.configure({ adapter = fake29(), conf = {},
                   dialect = (api.resolve(fake29(), "2.9-pre-b3")) }, { distance = 7 }), true)

-- detect() no longer decides, but it still objects.
ck("check agrees",          api.check(fake29(), "2.9"), nil)
ck("check disagrees",       (api.check(fake29(), "2.8")):match("speaks 2%.9") ~= nil, true)
ck("check ignores non-module", api.check({}, "2.9"), nil)
-- The regression the middle row creates: a 2.9 adapter on a pre-beta-3 fleet is
-- CORRECT and must not warn. Comparing the probe against the setting string
-- rather than against the dialect it implies would warn on every module, every
-- boot, for a configuration that is right.
ck("pre-b3 does not warn",  api.check(fake29(), "2.9-pre-b3"), nil)
ck("pre-b3 warns on 2.8 hw",
   (api.check(fake28(), "2.9-pre-b3")):match("speaks 2%.8") ~= nil, true)
-- and says which parameter API it expected, since "2.9-pre-b3" alone would read
-- as nonsense next to "speaks 2.9".
ck("pre-b3 names the API",
   (api.check(fake28(), "2.9-pre-b3")):match("parameter API 2%.9") ~= nil, true)
ck("2.9 needs no API gloss",
   (api.check(fake28(), "2.9")):match("parameter API") == nil, true)

-- =============================================================================
section("config.lua / hw_telem.lua -- drone labels follow the pack version")
-- =============================================================================
-- config.lua cannot be dofile'd from here: it resolves settings.lua and
-- module_api.lua relative to the working directory, which is the repo root when
-- these tests run. So this reads its SOURCE, the same bargain the editor checks
-- below make, and drives the shipped table through the real relabel.
--
-- What this is actually guarding is the thing that let the bug ship: the drone
-- names are written down TWICE, in config.lua and again in hw_telem.lua, and
-- nothing made them agree.
local cfgSrc = slurp("config.lua")

local shipped = {}
for key, name in cfgSrc:match("config%.drones = {(.-)}"):gmatch('(%w+)%s*=%s*"([^"]+)"') do
  shipped[key] = name
end
local nShipped = 0
for _ in pairs(shipped) do nShipped = nShipped + 1 end
ck("config ships 14 drones", nShipped, 14)

-- Every tier converts, in both directions. A gsub anchored slightly wrong would
-- leave exactly one behind, and one missing tier is a silent 0-in-stock.
local bad29, bad28, badPre = 0, 0, 0
for _, name in pairs(shipped) do
  if not api.relabel(name, "2.9"):match("^Mining Drone Mk%-") then bad29 = bad29 + 1 end
  if not api.relabel(name, "2.8"):match("^Mining Drone MK%-") then bad28 = bad28 + 1 end
  if not api.relabel(name, "2.9-pre-b3"):match("^Mining Drone MK%-") then badPre = badPre + 1 end
end
ck("all 14 relabel to 2.9", bad29, 0)
ck("all 14 relabel to 2.8", bad28, 0)
ck("all 14 relabel pre-b3", badPre, 0)

-- config.lua must actually run the relabel, and must do it after the overlay --
-- gtVersion is a setting, so relabelling beside the table in section 1 would
-- read a default that user_config.lua is about to change.
ck("config relabels",        cfgSrc:find("moduleApi.relabel(name", 1, true) ~= nil, true)
ck("relabel after overlay",  cfgSrc:find("config.setGtVersion(config.gtVersion)", 1, true)
                             > cfgSrc:find("user.drillPar", 1, true), true)

-- The module tier is a different "MK" entirely -- MK-I/II/III are Mining Module
-- tiers, and the editor prints them for asteroid rows. Only drones were renamed.
ck("module tiers untouched",  cfgSrc:find('["MK-II"]', 1, true) ~= nil, true)
ck("relabel spares modules",  api.relabel("MK-II", "2.9"), "MK-II")

-- hw_telem holds the second copy. It cannot be loaded (it asserts a modem on
-- line 24), so check it builds its labels from the marker rather than hardcoding
-- a spelling, and that its 14 tiers still spell out what config.lua ships.
local hwSrc = slurp("hw_telem.lua")
ck("node builds from mark",
   hwSrc:find('droneMark .. "-" .. droneModels[key]', 1, true) ~= nil, true)
ck("node hardcodes no marker",
   hwSrc:find('"Mining Drone MK%-') == nil and hwSrc:find('"Mining Drone Mk%-') == nil, true)

local models = {}
for key, model in hwSrc:match("local droneModels = {(.-)}"):gmatch('(%w+)="([^"]+)"') do
  models[key] = model
end
local mismatched, nModels = 0, 0
for key, model in pairs(models) do
  nModels = nModels + 1
  if ("Mining Drone Mk-" .. model) ~= api.relabel(shipped[key] or "", "2.9") then
    mismatched = mismatched + 1
  end
end
ck("node lists 14 tiers",     nModels, 14)
ck("node agrees with config", mismatched, 0)

-- config.droneKeyByLabel is how the broker reads a drone back OUT of an input
-- bus at boot -- a module mining when the broker went down still holds one, and
-- the label is the only thing identifying it. It must be rebuilt by
-- setGtVersion, or a "MK-" key would silently fail to match a "Mk-" bus stack
-- and the drone would go unrecognised on exactly the packs this all exists for.
ck("config builds the inverse",
   cfgSrc:find("config.droneKeyByLabel[name] = key", 1, true) ~= nil, true)
ck("inverse is inside setGtVersion",
   cfgSrc:find("config.droneKeyByLabel = {}", 1, true)
   > cfgSrc:find("function config.setGtVersion", 1, true), true)

-- =============================================================================
section("settings.lua -- the tunable registry")
-- =============================================================================
local S = dofile(ROOT .. "/settings.lua")
local cfg = {}
local raw = S.defaults(cfg)

ck("gtVersion default",     cfg.gtVersion, "2.9")
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
ck("choice cycles",          S.cycle(S.byKey.gtVersion, "2.9"), "2.9-pre-b3")
ck("choice cycles again",    S.cycle(S.byKey.gtVersion, "2.9-pre-b3"), "2.8")
ck("choice wraps",           S.cycle(S.byKey.gtVersion, "2.8"), "2.9")
ck("pre-b3 is settable",     S.coerce(S.byKey.gtVersion, "2.9-pre-b3"), "2.9-pre-b3")
-- settings.lua's choice list and module_api's version list are two lists of the
-- same thing. They have to agree, or a legal setting resolves to no dialect.
local declared = {}
for _, v in ipairs(S.byKey.gtVersion.choices) do declared[v] = true end
local unmapped = 0
for _, v in ipairs(api.VERSIONS) do if not declared[v] then unmapped = unmapped + 1 end end
ck("every version offered",  unmapped, 0)
local undialected = 0
for _, v in ipairs(S.byKey.gtVersion.choices) do
  if not api.dialect(v) then undialected = undialected + 1 end
end
ck("every choice resolves",  undialected, 0)
-- "auto" is gone: an item label has nothing to probe, so the version is always
-- an explicit answer now. A saved user_config.lua from before this change still
-- carries it, and has to be refused rather than silently accepted.
ck("auto no longer legal",   (S.coerce(S.byKey.gtVersion, "auto")), nil)

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

local penv = { pairs = pairs, ipairs = ipairs, math = math, tostring = tostring,
               tonumber = tonumber }
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
-- `stock` is the DECLARED fleet (config.droneStock) -- drones no longer come
-- from telemetry. brokerState still carries the drill figures, which are
-- measured because tips and rods are actually consumed.
local function world(stock, mods, sweptAt, kits)
  penv.brokerState = { drones = {}, drills = kits or {}, lastHWSyncTime = sweptAt }
  penv.modules = mods
  penv.config = { fastReload = true, tipsPerLoad = 64, rodsPerLoad = 64,
                  droneStock = stock }
end
local function busy(droneKey, dispatchedAt, drillKey)
  return { status = "RUNNING",
           job = { droneKey = droneKey, drillKey = drillKey, dispatchedAt = dispatchedAt } }
end
local function holding(droneKey, drillKey)
  return { status = "IDLE", job = nil, holding = { droneKey = droneKey, drillKey = drillKey } }
end

-- THE LEDGER. free = declared - committed. No sweep, no timestamps, no windows.
--
-- This used to start from the ME figure and reconstruct reality with three
-- corrections: subtract commitments a sweep had not seen, add back holds, add
-- back drones in flight to the network. Every correction existed because
-- hw_telem can only see the NETWORK, and a drone in a bus, a buffer, or
-- mid-transfer is not in it. Four bugs came out of that seam. config.droneStock
-- is the fleet now, and the broker knows exactly what it has committed.
world({ luv = 10 }, {}, 0)
ck("nothing running: all free",   availableDrones(true).luv, 10)

world({ luv = 10 }, { busy("luv", 0), busy("luv", 0) }, 0)
ck("two busy: two charged",       availableDrones(true).luv, 8)

-- The dispatch timestamp is no longer part of the sum, so a job placed "after
-- the last sweep" is charged exactly like one placed before it. Both of the
-- cases these replace were about the sweep being ahead of or behind the ledger.
world({ luv = 10 }, { busy("luv", 999999) }, 0)
ck("dispatch time is irrelevant", availableDrones(true).luv, 9)

-- strict was reserveWhileMining's lever over how much to trust a stale sweep.
-- With no sweep in the sum there is nothing left for it to change, and the two
-- pools must agree -- dispatch and the reachability view can no longer disagree
-- about how many drones exist.
world({ luv = 10 }, { busy("luv", 0) }, 0)
ck("strict and non-strict agree",
   availableDrones(true).luv, availableDrones(false).luv)

-- A HELD DRONE IS FREE, and needs no credit to be so: fastReload leaves the
-- module IDLE with job = nil, so nothing charges it, and it never left the
-- declared total. The old version had to add it back to undo the ME calling it
-- missing.
world({ luv = 10 }, { holding("luv", "tungstensteel") }, 0)
ck("hold is free without a credit",  availableDrones(true).luv, 10)
ck("hold is not double counted",     availableDrones(false).luv, 10)

-- ...and that is true whether or not fastReload is on. The hold either exists
-- or it does not; the setting decides whether one is ever taken, not whether an
-- existing one is counted.
world({ luv = 10 }, { holding("luv", "tungstensteel") }, 0)
penv.config.fastReload = false
ck("hold count ignores fastReload",  availableDrones(true).luv, 10)
penv.config.fastReload = true

-- Declaring fewer drones than are already out must read as zero, not negative.
-- Editing the fleet down mid-run is the way to get here.
world({ uhv = 1 }, { busy("uhv", 0), busy("uhv", 0) }, 0)
ck("pool is floored at zero", availableDrones(true).uhv, 0)

-- An undeclared tier is simply not available, however many the network reports.
world({ luv = 0 }, {}, 0)
ck("undeclared tier is unavailable", availableDrones(true).luv, 0)

-- Kits move the same way, in units of a full load.
world({}, { busy("uhv", 900, "naquadah") }, 990, { naquadah = { kits = 64 } })
ck("pre-sweep kits not charged twice", availableKits(true).naquadah, 64)
world({}, { busy("uhv", 995, "naquadah") }, 990, { naquadah = { kits = 64 } })
ck("post-sweep kits charged",          availableKits(true).naquadah, 0)
world({}, { holding("uhv", "naquadah") }, 990, { naquadah = { kits = 0 } })
ck("held kits count as free",          availableKits(true).naquadah, 64)

-- =============================================================================
section("assignOne / boot -- the sensor machinery is gone, not dormant")
-- =============================================================================
-- Four bugs in this thread came from reconciling a broker ledger against a
-- sensor that can only see the ME network. The fix was to stop: config.droneStock
-- is the fleet, and everything that existed to paper over the sensor's blind
-- spots had to be REMOVED rather than left behind to rot.
local aSrc = broker:match("local function assignOne%(need%)(.-)\n  end\n")
ck("assignOne extracted", aSrc ~= nil, true)

ck("no in-flight guard left",   aSrc:find("inFlight", 1, true), nil)
ck("no return stamping left",   broker:find("mod.returned =", 1, true), nil)
ck("no boot sweep gate left",   broker:find("bootClearedAt", 1, true), nil)

-- The raw-ME second gate in tryDispatch is gone too: the pool no longer comes
-- from telemetry, so there is nothing for a second opinion to add.
ck("no raw-ME dispatch gate",
   broker:find("brokerState.drones[droneKey] or 0) <= 0", 1, true), nil)

-- availableDrones reads the declared fleet, not the sweep.
local pSrc = broker:match("local function availableDrones.-\nend")
ck("pool seeds from droneStock",
   pSrc:find("pairs(config.droneStock or {})", 1, true) ~= nil, true)
ck("pool does not read telemetry",
   pSrc:find("brokerState.drones", 1, true), nil)

-- usableDrillKeys loses the workaround that existed only because a drone in a
-- running module reported as zero. A declared drone is owned wherever it is.
local uSrc = broker:match("local function usableDrillKeys%(%)(.-)\nend")
ck("drill keys from declared fleet",
   uSrc:find("config.droneStock", 1, true) ~= nil, true)
ck("drill keys drop the busy-module loop",
   uSrc:find("mod.job.drillKey", 1, true), nil)

-- Kits still measure, because tips and rods are actually consumed. This is the
-- line between the two models and it should not blur.
local kSrc = broker:match("local function availableKits.-\nend")
ck("kits still read telemetry",
   kSrc:find("brokerState.drills", 1, true) ~= nil, true)
ck("kits still ask about the sweep",
   kSrc:find("telemetryHasSeen", 1, true) ~= nil, true)

-- Boot still empties the buses -- that is right on its own merits, and is what
-- puts a drone left over from a crash back where the loader can fetch it.
local initSrc = broker:match("(local function initModules.-\nend\n)")
ck("boot still empties the bus",
   initSrc:find("returnItemsToME(mod)", 1, true) ~= nil, true)
ck("boot warns on an empty fleet",
   initSrc:find("No drones declared", 1, true) ~= nil, true)

-- And dispatch says why it passed over a better drone. Without this the three
-- legitimate reasons -- asteroid tier range, drill kits, all committed -- are
-- indistinguishable from a bug, which is what made this thread long.
ck("dispatch explains a skip",
   aSrc:find("passed over %s: %s", 1, true) ~= nil, true)
for _, why in ipairs({ "takes tier", "none free", "kits %d < %d" }) do
  ck("skip reason: " .. why, aSrc:find(why, 1, true) ~= nil, true)
end

-- =============================================================================
section("applyHwStock -- a tier that hits zero has to come back")
-- =============================================================================
-- Lifted out of the broker source the same way availableDrones is above.
--
-- The bug: hw_telem sent only non-zero counts and the broker MERGED them, so a
-- tier that ran to zero simply stopped being mentioned and kept its last value
-- forever. tryDispatch's only guard against handing out a drone the network
-- does not hold is brokerState.drones[key] <= 0, so a frozen count meant a
-- surplus module was dispatched, timed out fetching a drone that was not there,
-- errored, recovered, and repeated -- which is exactly what was seen in world
-- with 10 LuV drones, 11 modules, and the panel insisting on 7.
local stockSrc = broker:match("(local function applyHwStock.-\n)end\n\n")
ck("applyHwStock extracted", stockSrc ~= nil, true)

local senv = {
  pairs = pairs, ipairs = ipairs, type = type, tonumber = tonumber,
  config = { droneKeyOrder = { "luv", "uhv", "zpm" } },
  drillKeyOrder = { "steel", "naquadah" },
}
local applyHwStock = assert(load(
  stockSrc .. "end\nreturn applyHwStock", "stock", "t", senv))()

local st = { drones = { luv = 7, uhv = 2, zpm = 0 },
             drills = { steel = { kits = 9, tips = 9, rods = 9 } } }

-- A payload naming luv sets it. Ordinary case, and the one that always worked.
applyHwStock(st, { drones = { luv = 3, uhv = 2 }, drills = {} })
ck("present tier takes value", st.drones.luv, 3)

-- THE BUG. luv is absent because the network holds none; it must read 0, not 3.
applyHwStock(st, { drones = { uhv = 2 }, drills = {} })
ck("absent tier reads zero",  st.drones.luv, 0)
ck("other tiers unharmed",    st.drones.uhv, 2)

-- Same for drills: a material that runs out must stop being counted.
applyHwStock(st, { drones = {}, drills = { naquadah = { kits = 4, tips = 5, rods = 4 } } })
ck("absent drill zeroes",     st.drills.steel.kits, 0)
ck("absent drill is a table", type(st.drills.steel), "table")
ck("present drill kits",      st.drills.naquadah.kits, 4)
ck("present drill tips",      st.drills.naquadah.tips, 5)

-- A node naming something we do not know must not get it into a table dispatch
-- reads, and must not stop the known keys being applied.
applyHwStock(st, { drones = { luv = 1, nosuchtier = 99 }, drills = {} })
ck("unknown key ignored",     st.drones.nosuchtier, nil)
ck("known key still applied", st.drones.luv, 1)

-- A malformed or absent section leaves that half alone rather than blanking it.
applyHwStock(st, { drills = {} })
ck("missing drones section",  st.drones.luv, 1)
applyHwStock(st, nil)
ck("nil payload survives",    st.drones.luv, 1)

-- And the other half of the fix: the node has to actually send its zeroes, or
-- an un-upgraded broker keeps freezing. Source-checked, since hw_telem cannot
-- be loaded here.
do
  local hw = slurp("hw_telem.lua")
  local body = hw:match("local function buildPayload%(assets%)(.-)\n  local crafting")
  ck("payload body found",   body ~= nil, true)
  ck("drones sent uncounted", body:find("if count > 0", 1, true), nil)
  ck("kits sent uncounted",   body:find("if kits > 0", 1, true), nil)
  ck("drones default to 0",
     body:find("payload.drones[key] = assets.drones[key] or 0", 1, true) ~= nil, true)
end

-- =============================================================================
section("loader.topUp -- component calls per restock pass")
-- =============================================================================
-- This is a PERFORMANCE test with teeth. The broker tops up every running module
-- every 3 seconds, forever on a pinned one, and the old restock path re-read the
-- same inventory four times per consumable to do it -- ~30 metered component
-- calls per module per pass, against the same per-tick budget six loaders are
-- queueing for. The counts asserted below are the whole point of the change, so
-- they are asserted exactly rather than as "fewer than before".
-- loader.lua is the one module here that reaches for OpenComputers at load:
-- `require("computer")` for its clock and `dofile("/home/scheduler.lua")` for
-- await/sleep. Rather than weaken the real file for the test's benefit, load it
-- in an environment where those two are answered by fakes. Everything below is
-- then the genuine function.
local clock = 0
local fakeSched = {
  sleep = function(t) clock = clock + (t or 0) end,
  -- Enough of await for topUp: poll until true or the timeout, advancing our
  -- own clock so nothing spins forever.
  await = function(pred, timeout, interval)
    local deadline = clock + (timeout or 5)
    repeat
      if pred() then return true end
      clock = clock + (interval or 0.1)
    until clock >= deadline
    return false
  end,
}
local loader
do
  local env = setmetatable({
    require = function(name)
      if name == "computer" then return { uptime = function() return clock end } end
      error("unexpected require: " .. tostring(name))
    end,
    dofile = function(path)
      if path:find("scheduler") then return fakeSched end
      error("unexpected dofile: " .. tostring(path))
    end,
  }, { __index = _G })
  loader = assert(load(slurp("loader.lua"), "loader.lua", "t", env))()
end
ck("loader loads in a sandbox", type(loader.topUp), "function")

-- A transposer that counts what it is asked. getAllStacks is the fast path
-- snapshotSide prefers; it returns the OpenComputers shape (0-based, empty slots
-- present as tables without a label).
local function fakeMod(bus, buf, opts)
  opts = opts or {}
  local calls = { getAllStacks = 0, getStackInSlot = 0, getInventorySize = 0,
                  transferItem = 0, setInterfaceConfiguration = 0 }
  local inv   = { [0] = bus, [1] = buf }     -- side 0 = bus, side 1 = interface
  -- Sizes are declared, not derived: `#t` on a table with nil holes is undefined
  -- in Lua, and a bus with an empty slot in the middle is the normal case here.
  local size  = { [0] = opts.busSize or 4, [1] = opts.bufSize or 4 }

  -- getAllStacks returns COPIES in OpenComputers -- the stacks come back across
  -- the Java boundary, so writing to a snapshot cannot write to the world. The
  -- first version of this fake handed out references, which made topUp's
  -- in-place snapshot update and the transfer below both land on the same table
  -- and every move count twice. Copying is what makes this fake honest.
  local function arr(side)
    calls.getAllStacks = calls.getAllStacks + 1
    local src, out = inv[side], {}
    for i = 1, size[side] do
      local st = src[i]
      out[i - 1] = st and { label = st.label, size = st.size, maxSize = st.maxSize } or {}
    end
    return { getAll = function() return out end }
  end
  local mod = {
    index = 1, status = "RUNNING",
    conf = { interfaceSide = 1, inputBusSide = 0 },
    calls = calls, inv = inv,
    transposer = {
      getAllStacks = arr,
      getInventorySize = function(side)
        calls.getInventorySize = calls.getInventorySize + 1
        return size[side]
      end,
      getStackInSlot = function(side, sl)
        calls.getStackInSlot = calls.getStackInSlot + 1
        return inv[side][sl]
      end,
      transferItem = function(from, to, howMany, src, dst)
        calls.transferItem = calls.transferItem + 1
        local sst = inv[from][src]
        if not sst then return 0 end
        local moved = math.min(howMany, sst.size, opts.throttle or math.huge)
        sst.size = sst.size - moved
        if sst.size <= 0 then inv[from][src] = nil end
        local into = inv[to][dst]
        if into then into.size = into.size + moved
        else inv[to][dst] = { label = sst.label, size = moved, maxSize = 64 } end
        return moved
      end,
    },
    iface = { setInterfaceConfiguration = function()
      calls.setInterfaceConfiguration = calls.setInterfaceConfiguration + 1
    end },
  }
  return mod
end
local function stack(label, qty) return { label = label, size = qty, maxSize = 64 } end
local TIP, ROD = "Steel Drill Tip", "Steel Drill Rod"

-- SETTLED: both consumables already at target. One read of the bus, and nothing
-- else -- no interface read, no transfer. The old path cost six.
local m = fakeMod({ stack("Drone", 1), stack(TIP, 64), stack(ROD, 64) }, {})
local res, totals = loader.topUp(m, {
  { label = TIP, target = 64, cfgSlot = 2, dbSlot = 2 },
  { label = ROD, target = 64, cfgSlot = 3, dbSlot = 3 },
}, "dbaddr")
ck("settled: tips done",        res[1], "done")
ck("settled: rods done",        res[2], "done")
ck("settled: totals reported",  totals[TIP], 64)
ck("settled: ONE inventory read", m.calls.getAllStacks, 1)
ck("settled: no transfers",     m.calls.transferItem, 0)
ck("settled: sizes read once",  m.calls.getInventorySize, 2)

-- Sizes are cached on the module: a second pass asks the hardware nothing new.
loader.topUp(m, { { label = TIP, target = 64, cfgSlot = 2, dbSlot = 2 } }, "dbaddr")
ck("sizes cached across passes", m.calls.getInventorySize, 2)

-- NEEDS BOTH: one bus read, one interface read, two transfers. The old path
-- took four bus reads and two interface reads PER CONSUMABLE.
m = fakeMod({ stack("Drone", 1), stack(TIP, 32), stack(ROD, 32) },
            { stack(TIP, 64), stack(ROD, 64) })
res = loader.topUp(m, {
  { label = TIP, target = 64, cfgSlot = 2, dbSlot = 2 },
  { label = ROD, target = 64, cfgSlot = 3, dbSlot = 3 },
}, "dbaddr")
ck("refill: TWO inventory reads", m.calls.getAllStacks, 2)
ck("refill: one move each",       m.calls.transferItem, 2)
ck("refill: tips landed",         m.inv[0][2].size, 64)
ck("refill: rods landed",         m.inv[0][3].size, 64)

-- A PASS THAT MOVED SOMETHING IS NEVER "done", even though the arithmetic says
-- it reached target. The module is RUNNING and has been consuming throughout the
-- pass, so have+got overstates the bus -- and "done" latches (restockRunning ->
-- settled -> mod.bufferFilled), which would freeze an unpinned module's buffer
-- below target for the rest of the run. Only a fresh read may settle it.
ck("a pass that moved is partial",  res[1], "partial")
ck("both consumables partial",      res[2], "partial")

-- The next pass reads fresh and settles it, for one inventory read.
m.calls.getAllStacks = 0
res = loader.topUp(m, {
  { label = TIP, target = 64, cfgSlot = 2, dbSlot = 2 },
  { label = ROD, target = 64, cfgSlot = 3, dbSlot = 3 },
}, "dbaddr")
ck("next pass settles it",          res[1], "done")
ck("next pass costs one read",      m.calls.getAllStacks, 1)

-- And if the module ate some while we were filling, the next pass tops up the
-- difference instead of declaring victory. This is the case the old code got
-- wrong too: it re-read the bus, but only before the items it had just ordered
-- could be consumed.
m.inv[0][2].size = 59            -- five tips burned since the pass above
res = loader.topUp(m, {
  { label = TIP, target = 64, cfgSlot = 2, dbSlot = 2 },
}, "dbaddr")
ck("consumption is noticed",        res[1], "partial")

-- IN-PLACE SNAPSHOT UPDATE. Both consumables are short, both have stock waiting,
-- and the bus is empty -- so without updating the snapshot after the first
-- transfer, destIn would hand the SAME empty slot to the second and one would
-- land on top of the other. This is the bug drain() guards at loader.lua:520,
-- and the assertion has to make both consumables actually compete for the slot:
-- an earlier version of this test gave the first one no source, so they never
-- did, and dropping the update passed it.
m = fakeMod({ stack("Drone", 1) }, { stack(TIP, 64), stack(ROD, 64) }, { busSize = 3 })
loader.topUp(m, {
  { label = TIP, target = 64, cfgSlot = 2, dbSlot = 2 },
  { label = ROD, target = 64, cfgSlot = 3, dbSlot = 3 },
}, "dbaddr")
ck("tips took the first empty slot", m.inv[0][2] and m.inv[0][2].label, TIP)
ck("rods took the NEXT empty slot",  m.inv[0][3] and m.inv[0][3].label, ROD)
ck("neither landed on the other",    m.inv[0][2] and m.inv[0][2].size, 64)

-- PREFERS A PARTLY FILLED STACK over an empty slot, so a buffer does not
-- fragment across the bus.
m = fakeMod({ stack("Drone", 1), nil, stack(TIP, 32) }, { stack(TIP, 64) })
loader.topUp(m, { { label = TIP, target = 64, cfgSlot = 2, dbSlot = 2 } }, "dbaddr")
ck("filled the partial stack", m.inv[0][3].size, 64)
ck("left the empty slot empty", m.inv[0][2], nil)

-- NOFIT: the bus is physically full, so this is not a failure to retry.
m = fakeMod({ stack("Drone", 1), stack("Junk", 64), stack("Junk", 64) },
            { stack(TIP, 64) }, { busSize = 3 })
res = loader.topUp(m, { { label = TIP, target = 64, cfgSlot = 2, dbSlot = 2 } }, "dbaddr")
ck("nofit when the bus is full", res[1], "nofit")
ck("nofit reads nothing further", m.calls.getAllStacks, 1)

-- PARTIAL leaves the standing order in place; done releases it. Clearing on a
-- partial threw away the network's progress every pass -- measured in world at
-- 3.6 refills to move a single stack.
m = fakeMod({ stack("Drone", 1), stack(TIP, 0) }, { stack(TIP, 8) }, { throttle = 8 })
res = loader.topUp(m, { { label = TIP, target = 64, cfgSlot = 2, dbSlot = 2 } }, "dbaddr")
ck("short delivery stays partial", res[1], "partial")
ck("order placed, not cleared",    m.calls.setInterfaceConfiguration, 1)

-- A module that stops mid-pass is not loaded into.
m = fakeMod({ stack("Drone", 1) }, { stack(TIP, 64) })
m.status = "DONE"
loader.topUp(m, { { label = TIP, target = 64, cfgSlot = 2, dbSlot = 2 } }, "dbaddr")
ck("stopped module gets no items", m.calls.transferItem, 0)

-- =============================================================================
section("logger.lua -- formatting happens after the level check")
-- =============================================================================
-- Call sites used to read logger:info(string.format(...)), so the string was
-- built whatever the level -- and logging is OFF by default. Several of those
-- sit in paths that run every three seconds per module.
local written = {}
do
  local env = setmetatable({
    require = function() return { uptime = function() return 0 end,
                                  isAvailable = function() return false end } end,
    io = { open = function()
      return { write = function(_, line) written[#written + 1] = line end,
               close = function() end, seek = function() return 0 end }
    end },
  }, { __index = _G })
  local logging = assert(load(slurp("logger.lua"), "logger.lua", "t", env))()
  local log = logging.createLogger("test")

  -- A value that records the moment anything tries to render it.
  local rendered = false
  local spy = setmetatable({}, { __tostring = function() rendered = true; return "spy" end })

  -- INFO is suppressed by default, so nothing should be formatted at all.
  log:info("%s", spy)
  ck("suppressed level formats nothing", rendered, false)

  -- WARN is always written, so it must format.
  written, rendered = {}, false
  log:warn("%s", spy)
  ck("emitted level does format", rendered, true)
  ck("the formatted text is written", (written[1] or ""):find("spy") ~= nil, true)

  -- Backward compatibility: a plain single-argument call must not be treated as
  -- a format string, or every message containing a stray % would start throwing.
  written = {}
  log:warn("100% done")
  ck("no varargs means no formatting", (written[1] or ""):find("100%% done") ~= nil, true)

  -- A genuinely bad format degrades rather than taking down the caller.
  written = {}
  local okCall = pcall(function() log:warn("%d", "not a number") end)
  ck("a bad format does not throw", okCall, true)
end

-- =============================================================================
print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
