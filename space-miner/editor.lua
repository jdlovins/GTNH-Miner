-- =============================================================================
-- editor.lua -- the MEDINA condition editor, lifted out of broker-mk3.lua
--
-- WHY THIS IS ITS OWN FILE. Lua compiles a file as one function, every
-- column-0 `local` is a local of that function, and the limit is 200. broker-mk3
-- reached 196 -- 100 of them `local function` -- and the last two features had to
-- collapse constants into tables (see K here, POOL there) purely to fit. This
-- section was 1,774 of those lines and 63 of those locals, and it is the most
-- separable thing in the file: an input mode with its own state, its own painter
-- and its own file format, which the broker only ever asks "are you open?" and
-- "here is an event".
--
-- space-pumping did this first and this file follows its shape exactly:
-- dependencies arrive through init(deps) into forward-declared upvalues, nothing
-- touches hardware at load, and the module hands back a small surface. Compare
-- space-pumping/editor.lua and autoPump.lua:53-55.
--
-- That it loads with no hardware is also what lets test/run_tests.lua dofile it
-- and drive the real functions, instead of scraping them out of a file that
-- asserts a modem on line 60.
--
-- CONDITION EDITOR  (press E on the dashboard)
--
-- Asteroid-first. Pick an asteroid, see what it yields, choose what to stock.
--
-- WHY IT IS SHAPED THIS WAY:
--   config.conditions says WHAT to maintain. config.dustTargets says WHICH
--   asteroid yields it. An entry only ever dispatches if both exist and the
--   item label matches the ME label exactly; otherwise it fails silently as a
--   permanent 0%, which reads as "we have none of this, mine it urgently".
--
--   config.asteroidOutputs holds each asteroid's DIRECT yield, extracted from
--   the installed jar, so those are exact. Everything downstream of ore
--   processing -- Invar, Graphene, Cerium, the rare-earth line -- lives in
--   thousands of runtime recipe registrations and cannot be derived here. So
--   downstream items are TYPED IN by hand. That is not a shortcut; it is the
--   only correct option, and the editor's job is to make it quick and to keep
--   the two config tables consistent with each other.
--
-- SEMANTICS:
--   dustTargets is a MAPPING (where an item comes from). Toggling something off
--   never deletes it -- "Invar comes from the Nickel asteroid" stays true
--   whether or not you currently want Invar. Turning something ON writes the
--   mapping if it is missing, because at that point the asteroid is known.
--   conditions is the PREFERENCE (what to actually stock).
--
-- RUNS AS A UI MODE, NOT A MODAL DIALOG:
--   The main loop keeps calling sched.tick() and stepModules() the whole time
--   this is open, so loads in flight keep progressing. That rules out
--   term.read(): a blocking prompt could stall a load past ARRIVE_TIMEOUT and
--   fail it. All text entry is incremental instead -- every keystroke arrives
--   as an ordinary event through the same loop.
--
-- FOUR PAGES, NOT ONE:
--   asteroids/detail/items   what to mine and how much of it to keep.
--   drills                   the consumables that make mining possible at all --
--                            how many tips and rods go into a module, and what
--                            stock level triggers a craft. Same reason it lives
--                            here: those numbers used to mean closing the broker
--                            and editing Lua, and they are exactly the numbers
--                            you want to move while watching a module stall.
--   settings                 every other tunable in the system, built from the
--                            declarations in settings.lua. Booleans flip in
--                            place, choices cycle, numbers are typed and checked
--                            against their own bounds. Nothing on this page is
--                            named in this file, so declaring a knob over there
--                            is the entire job of adding one here.
--
-- The point of the last two is that there is now no reason to leave the program.
-- Every value that used to mean stopping the broker, editing Lua and restarting
-- is reachable from here, applies live on save, and is written to a file updates
-- never overwrite.
--
-- KEYS: up/down/pgup/pgdn/home/end move   enter drill in / commit
--       space toggle or cycle   t type a value   T step the ladder
--       r reset to shipped      a add downstream item   c changed only
--       i items   d drills   g settings   / filter   s save
--       TAB cancel a prompt, or go back -- and q or backspace in a list
--
-- NOT escape. Minecraft closes the screen GUI on escape, so the keypress never
-- reaches this program; the editor advertised it for a long time regardless.
-- The bindings are declared once in EDKEYS and the on-screen legend is built
-- from that table, so this class of drift cannot recur silently.
--
-- Closing with unsaved edits is refused once and says how many; a second CLOSE
-- discards them. Nothing here is applied or written until you press s.
-- =============================================================================

local editor = {}

-- ---------------------------------------------------------------------------
-- DEPENDENCIES
--
-- Filled by editor.init and nowhere else. Declared as upvalues rather than
-- required here so this file can be loaded with no OpenComputers present, which
-- is what the test suite relies on.
--
-- edTouch and edGen are the BROKER's generation counter, not ours. It means
-- "editor-owned data changed, dependent caches must recompute", and the
-- dashboard's dust list reads it too -- so the broker owns it and we call in.
-- edGen is a function here for that reason; it was a plain number when this
-- lived in the same chunk.
-- ---------------------------------------------------------------------------
local config, gpu
local W, H
local brokerState, drillKeyOrder, usableDrillKeys
local formatQty, drawStaticFrame, resetDustScroll
local edTouch, edGen


local USER_CONFIG_PATH   = "/home/user_config.lua"
local QUOTE              = string.char(34)
local TARGET_LADDER      = { 1000000, 2000000, 5000000, 10000000, 25000000, 50000000, 100000000 }
local DEFAULT_TARGET     = 5000000

local edRequestWatchlist = false   -- set on save; main loop re-broadcasts
local edRequestPar       = false   -- ditto, for DRILL_PAR
local edRequestNodes     = false   -- ditto, for NODE_SETTINGS

-- THE DRILL PAGE, IN ONE TABLE.
--
-- Everything else in this file is a plain top-level local, and this would be
-- too if there were room: the main chunk sits within a handful of Lua's
-- 200-local limit, and a dozen more would not fit. Namespacing one feature is
-- the cheap way out, and it happens to read well -- every drill-page constant
-- and helper is reachable from one name.
local DRILL = {}

-- The load-buffer settings shown on the drills page. They are ordinary entries
-- in the settings registry, named here only to say WHICH ones belong beside the
-- par table -- because that is where you are standing when you want to move
-- them. Editing one here and editing it on the settings page are the same edit
-- against the same working copy.
DRILL.fields = {
  "tipsPerLoad", "rodsPerLoad", "tipsToStart", "rodsToStart", "drillCraftSlots",
}

-- THE SETTINGS PAGE, IN ONE TABLE -- same reason DRILL is one table: the main
-- chunk is close enough to Lua's 200-local limit that a dozen more top-level
-- locals would not fit.
--
-- The page is BUILT FROM THE REGISTRY, not written out here. Declaring a knob
-- in settings.lua is the whole job: it appears in its group, with its help
-- line, editable in the way its type implies, validated against its own bounds,
-- and saved to user_config.lua. Nothing in this file names it.
local SET = {}   -- .spec is filled by editor.init: config arrives there

-- Fallback for a material with no shipped par at all (the top three tiers ship
-- with one, but a hand-trimmed config.lua may not). Deliberately small: turning
-- a material on should not commit the base to an expensive unattended craft.
DRILL.fallback = { tips = 256, rods = 256, batch = 256 }

-- ---------------------------------------------------------------------------
-- KEYS THAT ACTUALLY REACH US
--
-- Escape does not, and that is the whole reason this section exists. In
-- Minecraft, pressing Escape closes the screen GUI itself: the client eats the
-- keypress and no key_down event is ever delivered to the program. Every
-- `code == 1` branch in this editor was unreachable, and three legend strings
-- advertised it -- so the only way out of a text prompt was to commit a value.
--
-- TAB is the universal cancel now, because it is the one key that works in a
-- text field too: q is something you might legitimately type, and backspace
-- already means delete-a-character. In list mode q and backspace also go back,
-- since both are free there and closer to the hand.
--
-- Escape stays bound below as an alias. It costs one table entry, and it is
-- what everyone tries first.
-- ---------------------------------------------------------------------------
-- One table, not eleven locals: the main chunk is near Lua's 200-local ceiling
-- and this file is the reason. Scancodes as OpenComputers delivers them in
-- ev[4] of a key_down.
local K = {
  ESC = 1, BACKSPACE = 14, TAB = 15, ENTER = 28, DELETE = 211,
  UP = 200, DOWN = 208, PGUP = 201, PGDN = 209, HOME = 199, END_ = 207,
}

local ed = {
  open = false,
  mode = "asteroids",          -- asteroids | detail | items | drills | settings
  asteroid = nil,              -- selected asteroid while in detail mode
  rows = {},                   -- row model for the current mode
  sel = 1, scroll = 0,
  filter = nil, filtering = false,
  changedOnly = false,         -- settings page: show only knobs that differ from shipped
  input = nil,                 -- { label, buffer, onCommit }
  enabled = {}, threshold = {},-- working copy of config.conditions
  targets = {},                -- working copy of config.dustTargets
  par = {},                    -- working copy of config.drillPar (nil = not ordered)
  settings = {},               -- working copy of config.settings (every knob)
  added = {},                  -- items newly mapped this session
  msg = "", msgColor = 0x888888,
  dirty = true,                -- REPAINT flag. Unsaved edits are edDirtyCount().
  closeArmed = false,          -- a CLOSE was refused for unsaved changes; a second one discards
}

local function edSay(m, c) ed.msg = m; ed.msgColor = c or 0x888888 end

-- ---------------------------------------------------------------------------
-- BINDINGS, DECLARED ONCE
--
-- edHandle dispatches from this table and the legend at the top of the editor
-- is BUILT from it, so a binding cannot exist without being advertised, or be
-- advertised without existing. That is not tidiness for its own sake: the key
-- dispatch used to be an if/elseif ladder of raw scancodes and the legend three
-- hand-written strings, they drifted, and the UI ended up telling everyone to
-- press a key the game never delivers.
--
--   char / code  one or the other. `char` is the printable character (ev[3]),
--                `code` the scancode (ev[4]), matching what edHandle receives.
--   action       must be a case edAction handles. The test asserts this.
--   hint         how it appears in the legend. Omit to bind without listing --
--                that is what the cancel aliases do.
--   modes        space-separated pages, or "*" for every page.
--
-- Navigation (arrows, page up/down, home/end, enter) is deliberately NOT here.
-- Those are not actions, they have nothing to advertise, and they stay in the
-- ladder in edHandle.
-- ---------------------------------------------------------------------------
local EDKEYS = {
  { char = 32,  action = "activate", hint = "space=toggle",       modes = "asteroids detail items" },
  { char = 32,  action = "activate", hint = "space=on/off",       modes = "drills" },
  { char = 32,  action = "activate", hint = "space=toggle/cycle", modes = "settings" },
  { char = 116, action = "type",     hint = "t=type amount",      modes = "asteroids detail items" },
  { char = 116, action = "type",     hint = "t=edit",             modes = "drills" },
  { char = 116, action = "type",     hint = "t=type",             modes = "settings" },
  { char = 84,  action = "step",     hint = "T=step",             modes = "asteroids detail items" },
  { char = 97,  action = "add",      hint = "a=add",              modes = "detail" },
  { char = 114, action = "reset",    hint = "r=reset",            modes = "settings" },
  { char = 82,  action = "reset" },
  { char = 99,  action = "changed",  hint = "c=changed only",     modes = "settings" },
  { char = 105, action = "items",    hint = "i=items",            modes = "asteroids detail" },
  { char = 100, action = "drills",   hint = "d=drills",           modes = "asteroids detail items" },
  { char = 103, action = "settings", hint = "g=settings",         modes = "drills" },
  { char = 47,  action = "find",     hint = "/=find",             modes = "*" },
  { char = 115, action = "save",     hint = "s=save",             modes = "*" },
  -- Cancel. Tab is the one that is listed; the rest are aliases people try.
  { code = K.TAB,       action = "back", hint = "tab=back", modes = "*" },
  { code = K.BACKSPACE, action = "back" },
  { code = K.ESC,       action = "back" },
  { char = 113,         action = "back" },   -- q
  { char = 81,          action = "back" },   -- Q
}

local function edBindingFor(ch, code)
  for _, b in ipairs(EDKEYS) do
    if (b.char and ch == b.char) or (b.code and code == b.code) then
      if b.modes == nil or b.modes == "*" or b.modes:find(ed.mode, 1, true) then
        return b
      end
    end
  end
  return nil
end

-- The legend, assembled from the same table the dispatch reads.
local function edLegend()
  local parts = {}
  for _, b in ipairs(EDKEYS) do
    if b.hint and (b.modes == "*" or (b.modes and b.modes:find(ed.mode, 1, true))) then
      parts[#parts + 1] = b.hint
    end
  end
  return table.concat(parts, "  ")
end

local function edRows()  return H - 6 end   -- rows 5 .. H-2 hold the list
local function edFirst() return 5 end

-- ---------------------------------------------------------------------------
-- MODEL
-- ---------------------------------------------------------------------------

local function edLoad()
  ed.enabled, ed.threshold, ed.targets, ed.added = {}, {}, {}, {}
  for _, cond in ipairs(config.conditions) do
    ed.enabled[cond.itemName]   = true
    ed.threshold[cond.itemName] = cond.amountToMaintain
  end
  for item, t in pairs(config.dustTargets) do
    ed.targets[item] = { asteroid = t.asteroid, priority = t.priority or 99 }
  end

  -- A material ABSENT from config.drillPar is not an error, it is the "never
  -- order this" state -- so absence is carried through as nil rather than
  -- filled in with a default, and the page draws it unchecked.
  ed.par = {}
  for key, p in pairs(config.drillPar or {}) do
    if type(p) == "table" then
      ed.par[key] = { tips = p.tips or 0, rods = p.rods or 0,
                      batch = p.batch or p.tips or 0 }
    end
  end

  -- The whole registry, in stored form. One working copy behind both the
  -- settings page and the drills page, so the same knob cannot hold two
  -- different pending values depending on where you looked at it.
  ed.settings = {}
  for key, value in pairs(config.settings) do ed.settings[key] = value end
end

-- ---------------------------------------------------------------------------
-- HOW MUCH WOULD CLOSING THROW AWAY?
--
-- Every edit in this editor lands in a working copy above and NOWHERE ELSE
-- until edSave runs -- edSave is what writes user_config.lua and what applies
-- the values live, in that order. So closing without saving silently discards
-- the session, which is what this exists to stop.
--
-- Compared against `config` rather than against a snapshot taken at open,
-- because config IS the last-saved state: edSave updates it in the same pass
-- that writes the file. That also means a save mid-session correctly drops the
-- count back to zero without anything having to reset a baseline.
--
-- Counts entries, not keystrokes: flipping a setting and flipping it back is
-- zero changes, which is the honest answer to "would I lose anything".
-- ---------------------------------------------------------------------------
-- Memoised against edGen, the same way dustList is at the dust panel: this is
-- read on every repaint for the legend, and every mutation in the editor goes
-- through edTouch or edRebuild (which calls it), so a stale answer is not
-- reachable. edGen also ticks for reasons outside the editor, which costs a
-- recount and never correctness.
local edDirtyGen, edDirtyCached = -1, 0

local function edDirtyCount()
  if edDirtyGen == edGen() then return edDirtyCached end
  local n = 0

  -- Conditions: the tracked set and each threshold. Walk both directions so a
  -- removal counts as loudly as an addition.
  local liveCond = {}
  for _, cond in ipairs(config.conditions) do
    liveCond[cond.itemName] = cond.amountToMaintain
  end
  for item in pairs(ed.enabled) do
    if liveCond[item] == nil then n = n + 1
    elseif (ed.threshold[item] or DEFAULT_TARGET) ~= liveCond[item] then n = n + 1 end
  end
  for item in pairs(liveCond) do
    if not ed.enabled[item] then n = n + 1 end
  end

  -- Dust mappings: asteroid or priority moved.
  for item, t in pairs(ed.targets) do
    local live = config.dustTargets[item]
    if not live or live.asteroid ~= t.asteroid or (live.priority or 99) ~= t.priority then
      n = n + 1
    end
  end

  -- Drill par. Absence is a real state here ("never order this"), so a material
  -- present on one side and nil on the other is a change.
  local livePar = config.drillPar or {}
  for key, p in pairs(ed.par) do
    local live = livePar[key]
    if type(live) ~= "table" then n = n + 1
    elseif live.tips ~= p.tips or live.rods ~= p.rods
        or (live.batch or live.tips) ~= p.batch then n = n + 1 end
  end
  for key, live in pairs(livePar) do
    if type(live) == "table" and not ed.par[key] then n = n + 1 end
  end

  -- Settings, in stored form on both sides -- config.settings is the raw table
  -- the overlay and the editor share, not the applied runtime values.
  for key, value in pairs(ed.settings) do
    if config.settings[key] ~= value then n = n + 1 end
  end

  edDirtyGen, edDirtyCached = edGen(), n
  return n
end

-- "naquadahAlloy" -> "Naquadah Alloy". The tip label is the only place the
-- printable name exists; the key is camelCase and config.drills has no name
-- field of its own.
function DRILL.name(key)
  local d = config.drills[key]
  if d and d.tip then return (d.tip:gsub(" Drill Tip$", "")) end
  return key
end

-- The kit floor tryDispatch() actually enforces. Derived, never stored, so the
-- page shows it rather than letting you discover it as a module that refuses to
-- go out with plenty of kits on the shelf.
function DRILL.floor()
  return math.max(ed.settings.tipsPerLoad or 64, ed.settings.rodsPerLoad or 64)
end

local function outputsFor(name)
  return (config.asteroidOutputs or {})[name]
end

-- Items mapped to this asteroid that are NOT one of its direct yields.
-- Items already covered by the asteroid's derived main/processed lists.
local function derivedFor(name)
  local o = outputsFor(name)
  local set = {}
  if not o then return set end
  for _, e in ipairs(o.main or {})      do set[e.item] = true end
  for _, e in ipairs(o.processed or {}) do set[e.item] = true end
  return set
end

-- dustTargets entries pointing at this asteroid that the dump did NOT derive.
-- These are the hand-typed ones: alloys, chemical lines, anything past the
-- ore-processing graph the mod walks.
local function manualFor(name)
  local derived = derivedFor(name)
  local list = {}
  for item, t in pairs(ed.targets) do
    if t.asteroid == name and not derived[item] then list[#list + 1] = item end
  end
  table.sort(list)
  return list
end

local function trackedCount(name)
  local n = 0
  for item, t in pairs(ed.targets) do
    if t.asteroid == name and ed.enabled[item] then n = n + 1 end
  end
  return n
end

local function nextPriority(name)
  local p = 0
  for _, t in pairs(ed.targets) do
    if t.asteroid == name and t.priority and t.priority < 90 and t.priority > p then
      p = t.priority
    end
  end
  return p + 1
end

local function matchesFilter(s)
  if not ed.filter or ed.filter == "" then return true end
  return s:lower():find(ed.filter, 1, true) ~= nil
end

local function buildAsteroids()
  local rows = {}
  local names = {}
  for name in pairs(config.asteroids) do names[#names + 1] = name end
  table.sort(names)
  for _, name in ipairs(names) do
    if matchesFilter(name) then
      local a = config.asteroids[name]
      rows[#rows + 1] = {
        kind = "asteroid", name = name,
        tier = a.minModule or 1,
        drones = string.format("%d-%d", a.minDrone or 0, a.maxDrone or 0),
        tracked = trackedCount(name),
        direct = outputsFor(name) ~= nil,
      }
    end
  end
  return rows
end

-- Three sections, as the data itself divides:
--   MAIN       processing the drop -- macerator, washer, thermal centrifuge,
--              sifter, chemical bath, EM separator. hops=0 means the module
--              drops it finished.
--   PROCESSED  breaking those down further in a centrifuge or electrolyzer.
--   MANUAL     typed in by hand. Everything past the ore-processing graph --
--              alloys, chemical lines -- which no dump can reach.
local function buildDetail(name)
  local rows = {}
  local o = outputsFor(name)

  -- The raw drops are context, not choices: they are ore, processing eats them
  -- on arrival, and their stock never accumulates. Shown for the item filter.
  if o and o.drops then
    local parts = {}
    for _, dr in ipairs(o.drops) do
      parts[#parts + 1] = string.format("%s (%.0f%%)", dr.item, (dr.chance or 0) / 100)
    end
    rows[#rows + 1] = { kind = "header", text = "DROPS  (for the module item filter -- do not track)" }
    rows[#rows + 1] = { kind = "note", text = table.concat(parts, "   ") }
  end

  rows[#rows + 1] = { kind = "header",
    text = o and "MAIN  (from macerating / washing / centrifuging the drop)"
             or  "MAIN  -- nothing derived for this asteroid" }
  if o then
    for _, e in ipairs(o.main or {}) do
      if matchesFilter(e.item) then
        rows[#rows + 1] = { kind = "item", item = e.item, source = e.via, direct = true }
      end
    end
    if #(o.main or {}) == 0 then
      rows[#rows + 1] = { kind = "note", text = "none" }
    end
  end

  rows[#rows + 1] = { kind = "header", text = "PROCESSED  (electrolyzing / centrifuging the above)" }
  if o and #(o.processed or {}) > 0 then
    for _, e in ipairs(o.processed) do
      if matchesFilter(e.item) then
        rows[#rows + 1] = { kind = "item", item = e.item, source = e.via, direct = true }
      end
    end
  else
    rows[#rows + 1] = { kind = "note", text = "none" }
  end

  rows[#rows + 1] = { kind = "header", text = "MANUAL  (typed in -- alloys, chemical lines)" }
  local man = manualFor(name)
  if #man == 0 then
    rows[#rows + 1] = { kind = "note", text = "none yet -- press A to add one" }
  end
  for _, item in ipairs(man) do
    if matchesFilter(item) then
      rows[#rows + 1] = { kind = "item", item = item, direct = false }
    end
  end
  return rows
end

local function buildItems()
  local seen, list = {}, {}
  for item in pairs(ed.targets)  do if not seen[item] then seen[item] = true; list[#list+1] = item end end
  for item in pairs(ed.enabled)  do if not seen[item] then seen[item] = true; list[#list+1] = item end end
  table.sort(list)
  local rows = {}
  for _, item in ipairs(list) do
    if matchesFilter(item) then
      local t = ed.targets[item]
      rows[#rows + 1] = { kind = "item", item = item, direct = false,
                          asteroid = t and t.asteroid or nil, showAsteroid = true }
    end
  end
  return rows
end

-- DRILL CONSUMABLES PAGE
--
-- Two sections, because they answer two different questions and get tuned at
-- different times:
--
--   LOAD BUFFER   how much a module is given, and how little it will settle for
--                 before starting. Tuned when loads feel slow or modules stall
--                 mid-run.
--   RESTOCK PAR   when the hw node auto-crafts more, and how many it asks for.
--                 Tuned when a material keeps running dry, or when an expensive
--                 tier is crafting more eagerly than you want.
--
-- The two are coupled through the dispatch floor, which is why that derived
-- number is spelled out between them rather than left to be rediscovered.
function DRILL.build()
  local rows = {}

  rows[#rows + 1] = { kind = "header",
    text = "LOAD BUFFER  (what a module load puts in the input bus)" }
  for _, key in ipairs(DRILL.fields) do
    local spec = SET.spec.byKey[key]
    if spec and (matchesFilter(spec.label) or matchesFilter(key)) then
      rows[#rows + 1] = { kind = "opt", spec = spec }
    end
  end

  local usable = usableDrillKeys()
  local floor  = DRILL.floor()
  rows[#rows + 1] = { kind = "note", text = string.format(
    "a module will not be dispatched unless %d kits of its material are in stock" ..
    "  (the larger of the two per-load figures)", floor) }

  rows[#rows + 1] = { kind = "header",
    text = "RESTOCK PAR  (fall below the floor and a whole batch is crafted)" }

  -- The master switch sits at the top of the section it governs, not away on
  -- the settings page. Someone looking at a par table that is not ordering is
  -- standing right here, and "is this even switched on" should be answerable
  -- without leaving the page.
  local restockOn = ed.settings.drillRestock ~= false
  local switch = SET.spec.byKey["drillRestock"]
  if switch then
    rows[#rows + 1] = { kind = "opt", spec = switch }
  end
  if not restockOn then
    rows[#rows + 1] = { kind = "note", text =
      "auto-crafting is OFF -- the figures below are kept but nothing is ordered" }
  end

  for _, key in ipairs(drillKeyOrder) do
    local name = DRILL.name(key)
    if matchesFilter(name) then
      -- `usable` stays truthful (do we own a drone for it) and `restockOn` is
      -- carried separately, so the row can name the ACTUAL reason it is not
      -- being published. Folding the two together made every row claim "no
      -- drone" the moment auto-crafting was switched off.
      rows[#rows + 1] = { kind = "par", key = key, name = name,
                          usable = usable[key], restockOn = restockOn }
    end
  end

  return rows
end

local function edRebuild()
  edTouch()
  if ed.mode == "asteroids" then
    ed.rows = buildAsteroids()
  elseif ed.mode == "detail" then
    ed.rows = buildDetail(ed.asteroid)
  elseif ed.mode == "drills" then
    ed.rows = DRILL.build()
  elseif ed.mode == "settings" then
    ed.rows = SET.build()
  else
    ed.rows = buildItems()
  end
  if ed.sel > #ed.rows then ed.sel = #ed.rows end
  if ed.sel < 1 then ed.sel = 1 end
  local maxScroll = math.max(0, #ed.rows - edRows())
  if ed.scroll > maxScroll then ed.scroll = maxScroll end
  if ed.scroll < 0 then ed.scroll = 0 end
end

local function edFollow()
  if ed.sel < ed.scroll + 1 then ed.scroll = ed.sel - 1 end
  if ed.sel > ed.scroll + edRows() then ed.scroll = ed.sel - edRows() end
  if ed.scroll < 0 then ed.scroll = 0 end
end

-- Headers and notes are not selectable; step over them.
local function edMoveSel(delta)
  local n = #ed.rows
  if n == 0 then return end
  local i = ed.sel
  for _ = 1, n do
    i = i + delta
    if i < 1 then i = 1 break end
    if i > n then i = n break end
    local k = ed.rows[i] and ed.rows[i].kind
    if k ~= "header" and k ~= "note" then break end
  end
  ed.sel = i
  edFollow()
end

local function selectedRow()
  local r = ed.rows[ed.sel]
  if r and (r.kind == "header" or r.kind == "note") then return nil end
  return r
end

-- Entry point used by the main loop when E is pressed.
local function edBuild()
  edLoad()
  ed.mode, ed.asteroid = "asteroids", nil
  ed.sel, ed.scroll, ed.filter, ed.filtering, ed.input = 1, 0, nil, false, nil
  edRebuild()
end

-- ---------------------------------------------------------------------------
-- MUTATIONS
-- ---------------------------------------------------------------------------

local function edToggle(item, asteroid)
  edTouch()
  if ed.enabled[item] then
    ed.enabled[item] = nil
    edSay("stopped tracking " .. item)
    return
  end
  ed.enabled[item]   = true
  ed.threshold[item] = ed.threshold[item] or DEFAULT_TARGET
  -- Turning something on is the moment the mapping has to exist, and here the
  -- asteroid is known, so write it rather than leaving a condition that can
  -- never dispatch.
  if asteroid and not ed.targets[item] then
    ed.targets[item] = { asteroid = asteroid, priority = nextPriority(asteroid) }
    ed.added[item] = true
    edSay("tracking " .. item .. " at " .. formatQty(ed.threshold[item]) ..
          "  (mapped to " .. asteroid .. ")", 0x00FF00)
  elseif not ed.targets[item] then
    edSay("tracking " .. item .. " -- but it has no asteroid, so it cannot mine", 0xFF4444)
  else
    edSay("tracking " .. item .. " at " .. formatQty(ed.threshold[item]), 0x00FF00)
  end
end

local function edCycleTarget(item)
  edTouch()
  local cur = ed.threshold[item] or 0
  local nxt = TARGET_LADDER[1]
  for _, v in ipairs(TARGET_LADDER) do
    if v > cur then nxt = v break end
  end
  ed.threshold[item] = nxt
  ed.enabled[item]   = true
  edSay(item .. " target " .. formatQty(nxt), 0x00FF00)
end

-- Incremental text entry. Never blocks: each keystroke is just another event.
local function edPrompt(label, onCommit, initial)
  ed.input = { label = label, buffer = initial or "", onCommit = onCommit }
end

-- "50m" / "2.5m" / "500k" / "1b" / "250000". g is accepted as a synonym for b,
-- and t for trillion, so muscle memory from either convention works.
local function parseQty(s)
  if not s then return nil end
  local num, suffix = s:lower():gsub("%s", ""):match("^(%d+%.?%d*)([kmgbt]?)$")
  if not num then return nil end
  num = tonumber(num)
  local mult = ({ k = 1e3, m = 1e6, g = 1e9, b = 1e9, t = 1e12 })[suffix] or 1
  return math.floor(num * mult)
end

local function edAddDownstream()
  local asteroid = ed.asteroid
  if not asteroid then return end
  edPrompt("item label yielded by " .. asteroid .. " (exact ME name):", function(name)
    if not name or name == "" then edSay("cancelled") return end
    if ed.targets[name] then
      edSay(name .. " is already mapped to " .. ed.targets[name].asteroid, 0xFFAA00)
      return
    end
    ed.targets[name] = { asteroid = asteroid, priority = nextPriority(asteroid) }
    ed.added[name]   = true
    edPrompt("amount to maintain for " .. name .. " (5m, 500k, 250000):", function(q)
      local n = parseQty(q)
      if not n or n <= 0 then
        ed.threshold[name] = DEFAULT_TARGET
        edSay("bad amount, defaulted " .. name .. " to " .. formatQty(DEFAULT_TARGET), 0xFFAA00)
      else
        ed.threshold[name] = n
        edSay("added " .. name .. " -> " .. asteroid .. " at " .. formatQty(n), 0x00FF00)
      end
      ed.enabled[name] = true
      edRebuild()
    end, "5m")
    edRebuild()
  end)
end

-- ---------------------------------------------------------------------------
-- SAVE
-- ---------------------------------------------------------------------------

local function fmtQtyLiteral(n)
  if n >= 1000000 and n % 1000000 == 0 then return string.format("%dm", n / 1000000) end
  if n >= 1000    and n % 1000    == 0 then return string.format("%dk", n / 1000) end
  return tostring(n)
end

-- Type an amount rather than cycling to it.
--
-- The ladder is fine for a rough choice and useless for a specific one: getting
-- to 37m meant pressing t past every rung and settling for whichever was
-- closest. The current value is pre-filled in the same shorthand it prints in,
-- so editing 50m to 37m is three keystrokes.
--
-- Entry is incremental, like every other prompt here -- the main loop keeps
-- running while you type, so a load in flight is not stalled by a text field.
local function edTypeTarget(item)
  local cur = ed.threshold[item]
  -- The current value goes in the LABEL, not the buffer. Pre-filling the buffer
  -- would mean backspacing it away before typing, which is the opposite of the
  -- point -- you would be editing a field instead of just stating a number.
  edPrompt("keep how much " .. item .. "?" ..
           (cur and ("  (now " .. fmtQtyLiteral(cur) .. ")") or "") ..
           "  e.g. 50m, 2.5m, 500k",
    function(txt)
      if not txt or txt == "" then edSay("unchanged") return end
      local n = parseQty(txt)
      if not n or n <= 0 then
        edSay("did not understand '" .. tostring(txt) .. "' -- unchanged", 0xFF4444)
        return
      end
      edTouch()
      ed.threshold[item] = n
      ed.enabled[item]   = true
      edSay(item .. " -> " .. formatQty(n), 0x00FF00)
      edRebuild()
    end)
end

-- ---------------------------------------------------------------------------
-- DRILL MUTATIONS
-- ---------------------------------------------------------------------------

-- Warnings, not refusals. Every value these complain about is legal and there
-- are reasons to want each of them; what is not acceptable is setting one by
-- accident and finding out days later from a module that will not dispatch.
function DRILL.warn(key)
  local floor = DRILL.floor()
  if key == "tipsToStart" and (ed.settings.tipsToStart or 0) > (ed.settings.tipsPerLoad or 0) then
    edSay("tips to start is above tips per load -- the loader clamps it down", 0xFFAA00)
    return
  end
  if key == "rodsToStart" and (ed.settings.rodsToStart or 0) > (ed.settings.rodsPerLoad or 0) then
    edSay("rods to start is above rods per load -- the loader clamps it down", 0xFFAA00)
    return
  end
  if key == "tipsPerLoad" or key == "rodsPerLoad" then
    -- Raising a per-load figure raises the dispatch floor with it, which can
    -- strand a material that was previously fine.
    local under = {}
    for k, par in pairs(ed.par) do
      if math.min(par.tips or 0, par.rods or 0) < floor then under[#under + 1] = DRILL.name(k) end
    end
    if #under > 0 then
      table.sort(under)
      edSay("dispatch floor is now " .. floor .. " kits -- par is below that for " ..
            table.concat(under, ", "), 0xFFAA00)
    end
  end
end

-- ---------------------------------------------------------------------------
-- SETTINGS: EDIT, TOGGLE, RESET
--
-- Everything here is driven by the declaration, never by the key. A bool flips,
-- a choice cycles, a number is typed and checked against its own bounds -- and
-- the type-specific part of that is exactly three branches, in SET.activate.
-- ---------------------------------------------------------------------------

function SET.shipped(key) return (config.shippedSettings or {})[key] end

function SET.changed(key)
  local shipped = SET.shipped(key)
  return shipped ~= nil and ed.settings[key] ~= shipped
end

-- Type a value. Numbers accept the same k/m suffixes as everything else in the
-- editor; text is taken as typed. Out-of-range input is REFUSED with the bound
-- that rejected it, rather than clamped -- a clamp hides a typo.
function SET.prompt(spec)
  -- A bool has nothing to type. Reaching the prompt for one -- via `t`, which
  -- means "edit this" everywhere else in the editor -- should still do the
  -- obvious thing rather than asking you to spell out "false".
  if spec.type == "bool" then SET.activate(spec) return end

  local cur = ed.settings[spec.key]
  local hint = ""
  if spec.type == "choice" then
    hint = "  [" .. table.concat(spec.choices, " ") .. "]"
  elseif spec.min or spec.max then
    hint = string.format("  [%s..%s]", tostring(spec.min or "-"), tostring(spec.max or "-"))
  end
  edPrompt(spec.label .. "?  (now " .. SET.spec.display(spec, cur) .. ")" .. hint ..
           "  -- " .. spec.help,
    function(txt)
      if not txt or txt == "" then edSay("unchanged") return end
      -- parseQty understands "4k", which is how every other number in this
      -- editor is typed -- but it FLOORS, so a fractional setting like
      -- runPollIdle would silently become an integer if it went through there.
      -- Fractions first for those, suffixes first for the rest, and text
      -- settings never go near it: "4k" is a perfectly good string.
      local candidate = txt
      if spec.type == "number" then
        candidate = tonumber(txt) or parseQty(txt) or txt
      elseif spec.type == "int" then
        candidate = parseQty(txt) or tonumber(txt) or txt
      end
      local value, why = SET.spec.coerce(spec, candidate)
      if value == nil then
        edSay(spec.label .. ": " .. tostring(why) .. " -- unchanged", 0xFF4444)
        return
      end
      SET.commit(spec, value)
    end)
end

function SET.commit(spec, value)
  edTouch()
  ed.settings[spec.key] = value
  edSay(spec.label .. " -> " .. SET.spec.display(spec, value), 0x00FF00)
  DRILL.warn(spec.key)
  edRebuild()
end

-- What space and enter do to a row, decided by the declaration. A bool or a
-- choice moves in place -- no prompt, no typing, which is the whole point of
-- being able to flip a setting from here.
function SET.activate(spec)
  if spec.type == "bool" or spec.type == "choice" then
    SET.commit(spec, SET.spec.cycle(spec, ed.settings[spec.key]))
  else
    SET.prompt(spec)
  end
end

function SET.reset(spec)
  local shipped = SET.shipped(spec.key)
  if shipped == nil then edSay("no shipped default for " .. spec.key, 0xFFAA00) return end
  if ed.settings[spec.key] == shipped then edSay(spec.label .. " is already the default") return end
  SET.commit(spec, shipped)
  edSay(spec.label .. " reset to the shipped default: " ..
        SET.spec.display(spec, shipped), 0x00FF00)
end

-- The page. Groups in declaration order, settings within a group in the order
-- they are declared, so settings.lua reads the way the screen looks.
function SET.build()
  local rows = {}
  for _, group in ipairs(SET.spec.groups) do
    local body = {}
    for _, spec in ipairs(SET.spec.list) do
      if (spec.group or "other") == group.id then
        if spec.type == "note" then
          body[#body + 1] = { kind = "note", text = spec.text }
        elseif (matchesFilter(spec.label) or matchesFilter(spec.key))
           and (not ed.changedOnly or SET.changed(spec.key)) then
          -- changedOnly composes with the / filter rather than replacing it,
          -- so "what did I touch in logging" is one search and one toggle.
          body[#body + 1] = { kind = "opt", spec = spec }
        end
      end
    end
    -- A group whose settings were all filtered out contributes nothing, not an
    -- empty heading. Notes go with them: a note about rows you cannot see is
    -- just clutter.
    local hasOpt = false
    for _, r in ipairs(body) do if r.kind == "opt" then hasOpt = true break end end
    if hasOpt then
      rows[#rows + 1] = { kind = "header", text = group.label }
      for _, r in ipairs(body) do rows[#rows + 1] = r end
    end
  end
  return rows
end

function DRILL.toggle(key)
  edTouch()
  if ed.par[key] then
    ed.par[key] = nil
    edSay(DRILL.name(key) .. " will no longer be auto-crafted", 0xFFAA00)
  else
    -- Restore what this material shipped with rather than inventing a number.
    -- The shipped pars are scaled to what each material costs to make, and that
    -- scaling is the whole reason they are not all the same.
    local sh = (config.shippedDrillPar or {})[key] or DRILL.fallback
    ed.par[key] = { tips = sh.tips or 0, rods = sh.rods or 0,
                    batch = sh.batch or sh.tips or 0 }
    edSay(string.format("%s par %d/%d, batch %d", DRILL.name(key),
      ed.par[key].tips, ed.par[key].rods, ed.par[key].batch), 0x00FF00)
  end
  edRebuild()
end

-- Set one field of one material's par.
--
-- Editing a material that is switched off switches it on: you cannot have meant
-- "set the floor to 4096 and keep not ordering it".
function DRILL.editField(key, field, andThen)
  local par = ed.par[key]
  local cur = par and par[field] or nil
  local what = ({ tips = "drill tip floor", rods = "drill rod floor",
                  batch = "craft batch size" })[field]
  edPrompt(what .. " for " .. DRILL.name(key) .. "?" ..
           (cur and ("  (now " .. cur .. ")") or "") .. "  e.g. 4096, 2k",
    function(txt)
      local n = parseQty(txt or "")
      -- Empty means keep, which is what makes walking all three fields cheap:
      -- enter, enter, type the one you came for.
      if not txt or txt == "" then
        edSay("unchanged")
        if andThen then andThen() end
        return
      end
      if not n or n < 0 then
        edSay("did not understand '" .. tostring(txt) .. "' -- unchanged", 0xFF4444)
        if andThen then andThen() end
        return
      end
      edTouch()
      if not ed.par[key] then
        local sh = (config.shippedDrillPar or {})[key] or DRILL.fallback
        ed.par[key] = { tips = sh.tips or 0, rods = sh.rods or 0,
                        batch = sh.batch or sh.tips or 0 }
      end
      ed.par[key][field] = n
      edSay(DRILL.name(key) .. " " .. what .. " -> " .. n, 0x00FF00)

      local p, floor = ed.par[key], DRILL.floor()
      if (field == "tips" or field == "rods") and n < floor then
        -- The exact stall this feature exists to remove: stock sits at par, so
        -- nothing is ever crafted, and dispatch still refuses the material.
        edSay(string.format("%s: %d is below the %d-kit dispatch floor -- it can " ..
          "sit at par and still never dispatch", DRILL.name(key), n, floor), 0xFF4444)
      elseif p.batch < math.max(p.tips or 0, p.rods or 0) then
        edSay(DRILL.name(key) .. ": batch is smaller than the floor -- restocking " ..
              "will take several crafts", 0xFFAA00)
      end
      edRebuild()
      if andThen then andThen() end
    end)
end

-- Enter on a par row walks all three fields in turn -- chained prompts, the same
-- shape edAddDownstream uses. Each link is still one non-blocking field, so a
-- load in flight keeps progressing between keystrokes, and tab drops out of the
-- chain wherever you are in it.
function DRILL.editAll(key)
  DRILL.editField(key, "tips", function()
    DRILL.editField(key, "rods", function()
      DRILL.editField(key, "batch")
    end)
  end)
end

-- ---------------------------------------------------------------------------
-- SAVE
--
-- Writes ONLY /home/user_config.lua. config.lua is shipped data -- hand-kept
-- tables plus the generated asteroidOutputs block -- and gets regenerated
-- wholesale, so anything written there would be destroyed on the next update.
-- One writer per file: this editor owns user_config.lua and nothing else, and
-- nothing else ever writes it.
--
-- Only mappings that are genuinely yours are persisted, worked out against
-- config.shippedDustTargets, the snapshot config.lua takes before applying the
-- overlay. Writing all of them back would freeze the shipped table and mask
-- every future label correction. The same diff is applied to drillPar and to
-- the load scalars, against their own snapshots, for the same reason.
--
-- Every table the overlay reads has to be emitted here, because the file is
-- rewritten whole. Before the drill page existed this function wrote only
-- conditions and dustTargets, which meant a hand-written drillPar block was
-- destroyed by the next save -- silently, since nothing reads that file back.
-- ---------------------------------------------------------------------------

local function edSave()
  local shipped = config.shippedDustTargets or {}

  local mine = {}
  local mineCount = 0
  for item, t in pairs(ed.targets) do
    local sh = shipped[item]
    if not sh or sh.asteroid ~= t.asteroid or sh.priority ~= t.priority then
      mine[item] = t
      mineCount = mineCount + 1
    end
  end

  local conds = {}
  for item in pairs(ed.enabled) do conds[#conds + 1] = item end
  table.sort(conds)

  local out = {}
  out[#out + 1] = "-- user_config.lua"
  out[#out + 1] = "--"
  out[#out + 1] = "-- Written by the broker condition editor (press E). Safe to hand-edit."
  out[#out + 1] = "-- Nothing else writes this file, and config.lua updates never touch it."
  out[#out + 1] = "--"
  out[#out + 1] = "--   conditions   what to keep in stock. Replaces the shipped list."
  out[#out + 1] = "--   dustTargets  mappings you added or corrected. Merged over the"
  out[#out + 1] = "--                shipped table, so untouched entries still follow"
  out[#out + 1] = "--                config.lua."
  out[#out + 1] = "--   drillPar     restock floors you changed. Merged per material;"
  out[#out + 1] = "--                false means stop auto-crafting that material."
  out[#out + 1] = "--   settings     tunables you changed, validated against settings.lua."
  out[#out + 1] = "--                Anything not listed follows the shipped default."
  out[#out + 1] = ""
  out[#out + 1] = "return {"

  out[#out + 1] = "  conditions = {"
  for _, item in ipairs(conds) do
    local t = ed.targets[item]
    local ast = t and t.asteroid or nil
    out[#out + 1] = string.format("    { itemName = %-38s amountToMaintain = %-10d },%s",
      QUOTE .. item .. QUOTE .. ",", ed.threshold[item] or DEFAULT_TARGET,
      ast and ("   -- " .. ast) or "   -- NO ASTEROID: cannot dispatch")
  end
  out[#out + 1] = "  },"

  out[#out + 1] = "  dustTargets = {"
  local names = {}
  for item in pairs(mine) do names[#names + 1] = item end
  table.sort(names)
  for _, item in ipairs(names) do
    local t = mine[item]
    out[#out + 1] = string.format("    [%s%s%s] = { asteroid = %s%s%s, priority = %d },",
      QUOTE, item, QUOTE, QUOTE, t.asteroid, QUOTE, t.priority or 99)
  end
  out[#out + 1] = "  },"

  -- drillPar: only what differs from the shipped table. A material you switched
  -- OFF that ships ON has to be written as `false` -- omitting it would just let
  -- the shipped default come back on the next boot.
  local shippedPar = config.shippedDrillPar or {}
  local parOut, parCount = {}, 0
  for _, key in ipairs(drillKeyOrder) do
    local sh, cur = shippedPar[key], ed.par[key]
    if cur == nil then
      if sh then parOut[key] = false; parCount = parCount + 1 end
    elseif not sh or sh.tips ~= cur.tips or sh.rods ~= cur.rods or sh.batch ~= cur.batch then
      parOut[key] = cur; parCount = parCount + 1
    end
  end

  out[#out + 1] = "  drillPar = {"
  for _, key in ipairs(drillKeyOrder) do
    local v = parOut[key]
    if v == false then
      out[#out + 1] = string.format("    %-18s = false,   -- do not auto-craft", key)
    elseif v then
      out[#out + 1] = string.format("    %-18s = { tips = %d, rods = %d, batch = %d },",
        key, v.tips or 0, v.rods or 0, v.batch or 0)
    end
  end
  out[#out + 1] = "  },"

  -- Settings: only what differs from the shipped default, for the same reason
  -- as the two tables above. Written in DECLARATION order rather than pairs()
  -- order so the file is stable across saves and a diff of it is readable.
  --
  -- No drillLoad block any more. Its five fields are ordinary settings now, and
  -- writing both would leave two places claiming to hold tipsPerLoad. config.lua
  -- still READS a legacy drillLoad, so an upgrade does not lose tuning -- but
  -- the first save from here rewrites it into `settings` and it never comes back.
  local setCount = 0
  out[#out + 1] = "  settings = {"
  for _, spec in ipairs(SET.spec.list) do
    if spec.key and SET.changed(spec.key) then
      local v = ed.settings[spec.key]
      local lit
      if type(v) == "string"  then lit = QUOTE .. v .. QUOTE
      elseif type(v) == "boolean" then lit = v and "true" or "false"
      else lit = tostring(v) end
      -- A dotted key is a path into a nested table (logging.enabled), and
      -- `logging.enabled = true` inside a table constructor is a syntax error,
      -- not a nested write. Bracket it. The overlay reads these back with
      -- pairs() and looks each one up in the registry by its full dotted name,
      -- so the string form is what it wants.
      local name = spec.key:find(".", 1, true)
        and string.format("[%s%s%s]", QUOTE, spec.key, QUOTE)
        or spec.key
      out[#out + 1] = string.format("    %-24s = %s,   -- default %s", name, lit,
        SET.spec.display(spec, SET.shipped(spec.key)))
      setCount = setCount + 1
    end
  end
  out[#out + 1] = "  },"

  out[#out + 1] = "}"

  local w = io.open(USER_CONFIG_PATH, "w")
  if not w then edSay("cannot write " .. USER_CONFIG_PATH, 0xFF4444) return end
  w:write(table.concat(out, "\n") .. "\n")
  w:close()

  -- Apply live. Rebuilding in memory beats re-reading, which every other
  -- subsystem already holds references into.
  local fresh = {}
  for _, item in ipairs(conds) do
    fresh[#fresh + 1] = { itemName = item, amountToMaintain = ed.threshold[item] or DEFAULT_TARGET }
  end
  config.conditions = fresh

  for item, t in pairs(ed.targets) do
    config.dustTargets[item] = { asteroid = t.asteroid, priority = t.priority }
  end

  local newDust = {}
  for _, cond in ipairs(config.conditions) do
    local prev = brokerState.dust[cond.itemName]
    newDust[cond.itemName] = { stock = prev and prev.stock or 0,
                               threshold = cond.amountToMaintain }
  end
  brokerState.dust   = newDust
  resetDustScroll()
  edRequestWatchlist = true

  -- Apply the settings live, through the SAME mapping config.lua used at boot,
  -- so a knob cannot behave one way after a reboot and another after an edit.
  -- The loader and the dispatch loop read config on every pass, so nothing here
  -- needs a restart.
  for key, value in pairs(ed.settings) do
    config.settings[key] = value
    SET.spec.applyOne(config, key, value)
  end
  -- Anything with scope="node" has to reach the nodes, which is what this asks
  -- the main loop to do rather than waiting out the broadcast cadence.
  edRequestNodes = true

  local newPar = {}
  for key, p in pairs(ed.par) do
    newPar[key] = { tips = p.tips, rods = p.rods, batch = p.batch }
  end
  config.drillPar = newPar
  edRequestPar    = true
  -- The dust panel caches its sorted list against edGen, and a save can change
  -- which items exist and what their thresholds are, not just their stock.
  edTouch()

  edSay(string.format(
    "saved %d tracked, %d own mappings, %d drill par, %d setting(s) -> applied live",
    #conds, mineCount, parCount, setCount), 0x00FF00)
end

local edButtons = {}
local function edLayoutButtons()
  local defs
  -- A PROMPT OWNS THE BUTTON ROW.
  --
  -- The row keeps painting underneath an open prompt, and its buttons kept
  -- firing mode actions -- clicking SAVE while typing a number ran a save with
  -- the prompt still up. Swapping the set means the mouse does the two things
  -- that make sense here and nothing else, and it gives the cancel a target for
  -- anyone who has not found Tab yet.
  if ed.input or ed.filtering then
    defs = { { "OK", "input_ok" }, { "CANCEL", "input_cancel" } }
  elseif ed.mode == "asteroids" then
    defs = { { "ITEMS", "items" }, { "DRILLS", "drills" }, { "SETTINGS", "settings" },
             { "FIND", "find" }, { "SAVE", "save" }, { "CLOSE", "close" } }
  elseif ed.mode == "detail" then
    defs = { { "BACK", "back" }, { "ADD", "add" }, { "FIND", "find" },
             { "SAVE", "save" }, { "CLOSE", "close" } }
  elseif ed.mode == "drills" then
    defs = { { "ASTEROIDS", "asteroids" }, { "SETTINGS", "settings" }, { "FIND", "find" },
             { "SAVE", "save" }, { "CLOSE", "close" } }
  elseif ed.mode == "settings" then
    defs = { { "ASTEROIDS", "asteroids" }, { "DRILLS", "drills" }, { "FIND", "find" },
             { "RESET", "reset" }, { "SAVE", "save" }, { "CLOSE", "close" } }
  else
    defs = { { "ASTEROIDS", "asteroids" }, { "DRILLS", "drills" }, { "SETTINGS", "settings" },
             { "FIND", "find" }, { "SAVE", "save" }, { "CLOSE", "close" } }
  end
  edButtons = {}
  local x = 2
  for _, d in ipairs(defs) do
    local label = " " .. d[1] .. " "
    edButtons[#edButtons + 1] = { x1 = x, x2 = x + #label - 1, label = label, action = d[2] }
    x = x + #label + 2
  end
end

local X_MARK, X_NAME = 2, 6
local X_A, X_B, X_C = 44, 56, 68
-- Fourth column, used only by the drills page: what is actually in stock, right
-- beside the floor it is being compared against.
--
-- Every other column here is a fixed offset that quietly assumes a tier-3
-- screen, which the three-panel dashboard needs anyway. This one is guarded
-- rather than assumed, because a narrow screen would not truncate it -- it would
-- collide with the BATCH column and print nonsense.
DRILL.xStock    = 80
-- .stockFits needs W, so editor.init sets it.

-- ---------------------------------------------------------------------------
-- EDITOR PAINTER
--
-- edDraw cost ~625 component calls per repaint: a term.setCursor plus an
-- io.write for every field, a setForeground before most of them, and a
-- full-width fill on every one of the ~44 list rows -- all repeated whether or
-- not anything on that row had changed.
--
-- In OpenComputers each of those is a direct call against a per-tick budget, so
-- one repaint spanned several game ticks. With modules loading it competed with
-- the loader's transposer and ME calls for the same budget, which is why the
-- editor felt worst exactly when the miner was busy.
--
-- Three changes:
--   1. gpu.set instead of term.setCursor + io.write -- one call rather than
--      two, and it skips the OpenOS term layer's cursor bookkeeping.
--   2. Colour changes are guarded, so consecutive fields sharing a colour cost
--      one setForeground between them instead of one each.
--   3. Rows are cached by content signature. Moving the selection repaints the
--      two rows that actually changed, not the whole list.
-- ---------------------------------------------------------------------------
local edCache = {}
local edFG, edBG

-- Call whenever something else has painted over the screen (drawUI, boot). The
-- cache describes what is physically on screen, so if that assumption breaks
-- the cache has to go with it.
local edLastScroll, edLastMode

local function edInvalidate()
  edCache = {}
  edFG, edBG = nil, nil
  edLastScroll, edLastMode = nil, nil
end

-- Scrolling is the cache's worst case: every visible row shows different
-- content, so every signature misses and the whole list repaints -- the full
-- cold-paint cost, on every keypress once the selection reaches the window edge.
--
-- But a scroll is a SHIFT, not new content. gpu.copy moves the whole block in a
-- single call, leaving only the newly exposed rows to paint.
--
-- The cache is shifted to match, and stays truthful precisely because copy
-- really does move what the cache claims is there. A row whose new content
-- happens to equal the shifted content is then correctly skipped; one that
-- differs -- the selection highlight, usually -- is correctly repainted by the
-- signature check.
local function edScrollBlock()
  local first, rows = edFirst(), edRows()
  local prev, mode = edLastScroll, edLastMode
  edLastScroll, edLastMode = ed.scroll, ed.mode
  if not prev or mode ~= ed.mode then return end

  local d = ed.scroll - prev
  if d == 0 or math.abs(d) >= rows then return end

  -- Source row is further down the list when scrolling down, the top of the
  -- window when scrolling up. Either way the block moves by -d.
  gpu.copy(1, (d > 0) and (first + d) or first, W, rows - math.abs(d), 0, -d)

  local moved = {}
  for y, sig in pairs(edCache) do
    if y >= first and y < first + rows then
      local ny = y - d
      if ny >= first and ny < first + rows then moved[ny] = sig end
    else
      moved[y] = sig   -- header and footer rows sit outside the copied block
    end
  end
  edCache = moved
end

-- cells = { {x, s, fg}, ... }, painted left to right over a cleared row.
--
-- `key` identifies the content rather than describing it. Two rows with the
-- same key are guaranteed to hold identical content, so the caller can skip
-- building the cells at all -- which is the expensive part in Lua terms, not
-- the painting.
local function edPaint(y, key, bg, cells)
  if edCache[y] == key then return end
  edCache[y] = key

  if edBG ~= bg then gpu.setBackground(bg); edBG = bg end
  gpu.fill(1, y, W, 1, " ")
  for i = 1, #cells do
    local c = cells[i]
    if edFG ~= c[3] then gpu.setForeground(c[3]); edFG = c[3] end
    gpu.set(c[1], y, c[2])
  end
end

-- True when row y already shows exactly this content, so the caller can skip
-- past it without constructing anything at all.
local function edFresh(y, key) return edCache[y] == key end

local function edDraw()
  local title
  if ed.mode == "asteroids" then
    title = "CONDITION EDITOR  /  asteroids"
  elseif ed.mode == "detail" then
    title = "CONDITION EDITOR  /  " .. tostring(ed.asteroid)
  elseif ed.mode == "drills" then
    title = "CONDITION EDITOR  /  drill consumables"
  elseif ed.mode == "settings" then
    title = "CONDITION EDITOR  /  settings"
  else
    title = "CONDITION EDITOR  /  all tracked items"
  end
  edPaint(1, title, 0x000000, { { 2, title, 0x00FF00 } })

  local n = 0
  for _ in pairs(ed.enabled) do n = n + 1 end
  -- The key half of this line is generated from EDKEYS, so it cannot advertise
  -- a binding that does not exist -- which is the bug that started all this.
  -- Only the counts and the filter state are assembled here.
  local lead
  if ed.mode == "drills" then
    lead = "enter=edit all three"
  elseif ed.mode == "settings" then
    local changed = 0
    for key in pairs(ed.settings) do if SET.changed(key) then changed = changed + 1 end end
    lead = string.format("%d changed from shipped", changed)
  else
    lead = string.format("%d tracked", n)
  end

  local tail = ""
  if ed.changedOnly and ed.mode == "settings" then tail = tail .. "  |  changed only" end
  if ed.filter then tail = tail .. "  |  filter: " .. ed.filter end

  -- Unsaved work is stated in the one line that is always on screen, so it is
  -- something you see before reaching for CLOSE rather than only after.
  local pending = edDirtyCount()
  local hint = lead .. "  |  " .. edLegend() .. tail
  if pending > 0 then hint = hint .. string.format("  |  %d UNSAVED", pending) end
  edPaint(2, hint, 0x000000, { { 2, hint, pending > 0 and 0xFFAA00 or 0x888888 } })

  if ed.mode == "asteroids" then
    edPaint(4, "h:ast", 0x000000, {
      { X_NAME, "ASTEROID", 0x888888 }, { X_A, "MODULE", 0x888888 },
      { X_B, "DRONES", 0x888888 },      { X_C, "TRACKED", 0x888888 },
    })
  elseif ed.mode == "settings" then
    edPaint(4, "h:settings", 0x000000, {
      { X_NAME, "SETTING", 0x888888 }, { X_A, "VALUE", 0x888888 },
      { X_C, "WHAT IT DOES", 0x888888 },
    })
  elseif ed.mode == "drills" then
    edPaint(4, "h:drills", 0x000000, {
      { X_NAME, "MATERIAL / SETTING", 0x888888 }, { X_A, "TIPS", 0x888888 },
      { X_B, "RODS", 0x888888 },                 { X_C, "BATCH", 0x888888 },
      table.unpack(DRILL.stockFits and { { DRILL.xStock, "IN STOCK", 0x888888 } } or {}),
    })
  else
    edPaint(4, "h:" .. ed.mode, 0x000000, {
      { X_NAME, "ITEM", 0x888888 },  { X_A, "TARGET", 0x888888 },
      { X_B, "HAVE", 0x888888 },
      { X_C, ed.mode == "detail" and "VIA" or "ASTEROID", 0x888888 },
    })
  end

  edScrollBlock()

  for r = 0, edRows() - 1 do
    local y   = edFirst() + r
    local idx = ed.scroll + r + 1
    local row = ed.rows[idx]

    local sel = (idx == ed.sel and row and row.kind ~= "header" and row.kind ~= "note")
    -- Content is fully determined by which list entry is here, whether it is
    -- selected, and the model generation. Same key means the row on screen is
    -- already right, so skip it before building a single table.
    local key = idx .. (sel and "*" or "-") .. edGen()
    if edFresh(y, key) then goto continue end

    do
    local bg = sel and 0x222222 or 0x000000
    local cells = {}

    if row then
      if row.kind == "header" then
        cells[1] = { 2, "-- " .. row.text, 0x00AAFF }

      elseif row.kind == "note" then
        cells[1] = { 6, row.text, 0x555555 }

      elseif row.kind == "opt" then
        local spec = row.spec
        local value = ed.settings[spec.key]
        -- A boolean gets a checkbox, because that is what a boolean is and
        -- because the checkbox is also the click target. Everything else shows
        -- its value in the VALUE column and is typed or cycled.
        if spec.type == "bool" then
          cells[#cells+1] = { X_MARK, value and "[x]" or "[ ]",
                              value and 0x00FFFF or 0x555555 }
        end
        -- Anything moved off its shipped default is marked, so a page of
        -- defaults reads as untouched at a glance and the one line you changed
        -- three weeks ago is still findable.
        local moved = SET.changed(spec.key)
        cells[#cells+1] = { X_NAME, (moved and "* " or "  ") .. spec.label,
                            moved and 0xFFFFFF or 0x00FFFF }
        cells[#cells+1] = { X_A, SET.spec.display(spec, value),
                            moved and 0xFFAA00 or 0x00FF00 }
        cells[#cells+1] = { X_C, spec.help:sub(1, W - X_C), 0x666666 }

      elseif row.kind == "par" then
        local par  = ed.par[row.key]
        local on   = par ~= nil
        local fg   = on and 0x00FFFF or 0x555555
        cells[#cells+1] = { X_MARK, on and "[x]" or "[ ]", fg }
        cells[#cells+1] = { X_NAME, row.name, fg }
        cells[#cells+1] = { X_A, on and tostring(par.tips)  or "-", fg }
        cells[#cells+1] = { X_B, on and tostring(par.rods)  or "-", fg }
        cells[#cells+1] = { X_C, on and tostring(par.batch) or "-",
                            on and 0x888888 or 0x555555 }

        -- Kits, not tips and rods separately: a kit is what a load consumes,
        -- and it is what the dispatch floor is counted in.
        if DRILL.stockFits then
          local d     = brokerState.drills[row.key]
          local kits  = (d and d.kits) or 0
          local floor = on and math.min(par.tips or 0, par.rods or 0) or DRILL.floor()
          cells[#cells+1] = { DRILL.xStock, tostring(kits) .. " kits",
            (kits == 0 and 0xFF4444) or (kits >= floor and 0x00FF00) or 0xFFAA00 }

          -- Par is only published for materials a drone in this base actually
          -- uses. Say so on the row, or switching one on for a tier you do not
          -- own looks like the save did nothing.
          if on and W >= DRILL.xStock + 36 then
            if not row.restockOn then
              cells[#cells+1] = { DRILL.xStock + 10, "auto-craft off", 0x666666 }
            elseif not row.usable then
              cells[#cells+1] = { DRILL.xStock + 10, "no drone -- not published", 0x666666 }
            end
          end
        end

      elseif row.kind == "asteroid" then
        cells[#cells+1] = { X_NAME, row.name:sub(1, X_A - X_NAME - 1),
                            row.tracked > 0 and 0x00FFFF or 0x777777 }
        cells[#cells+1] = { X_A, "MK-" .. tostring(row.tier), 0x888888 }
        cells[#cells+1] = { X_B, row.drones, 0x888888 }
        cells[#cells+1] = { X_C, tostring(row.tracked),
                            row.tracked > 0 and 0x00FF00 or 0x555555 }
        if not row.direct then
          cells[#cells+1] = { X_C + 6, "no derived outputs", 0xFFAA00 }
        end

      else -- item
        local item = row.item
        local on   = ed.enabled[item]
        local fg   = on and 0x00FFFF or 0x555555
        cells[#cells+1] = { X_MARK, on and "[x]" or "[ ]", fg }
        cells[#cells+1] = { X_NAME,
          ((row.direct == false and ed.mode == "detail") and "~ " or "  ")
          .. item:sub(1, X_A - X_NAME - 3), fg }
        cells[#cells+1] = { X_A,
          on and formatQty(ed.threshold[item] or DEFAULT_TARGET) or "-", fg }

        local d    = brokerState.dust[item]
        local have = d and d.stock or 0
        local tgt  = ed.threshold[item] or DEFAULT_TARGET
        cells[#cells+1] = { X_B, formatQty(have),
          have >= tgt and 0x00FF00 or (have > 0 and 0xFFAA00 or 0x555555) }

        if ed.mode == "detail" then
          cells[#cells+1] = { X_C, tostring(row.source or "hand-typed"):sub(1, W - X_C),
                              0x666666 }
        else
          local t = ed.targets[item]
          if t then
            cells[#cells+1] = { X_C, tostring(t.asteroid):sub(1, W - X_C), 0x888888 }
          else
            cells[#cells+1] = { X_C, "NOT MINEABLE", 0xFF4444 }
          end
        end
      end
    end

    edPaint(y, key, bg, cells)
    end
    ::continue::
  end

  edLayoutButtons()
  local by    = H - 1
  local cells = {}
  for _, b in ipairs(edButtons) do
    cells[#cells+1] = { b.x1, b.label, 0xFFFFFF }
  end
  local pos = string.format("%d-%d/%d", math.min(ed.scroll + 1, #ed.rows),
    math.min(ed.scroll + edRows(), #ed.rows), #ed.rows)
  cells[#cells+1] = { W - #pos - 1, pos, 0x888888 }
  edPaint(by, "b:" .. pos .. ":" .. #edButtons, 0x000000, cells)

  if ed.input then
    local t = ed.input.label .. " " .. ed.input.buffer .. "_    enter=commit  tab=cancel"
    edPaint(H, "i:" .. t, 0x000000, { { 2, t, 0xFFAA00 } })
  elseif ed.filtering then
    local t = "/" .. (ed.filter or "") .. "_    enter=keep  tab=clear"
    edPaint(H, "f:" .. t, 0x000000, { { 2, t, 0xFFAA00 } })
  else
    local t = ed.msg:sub(1, W - 2)
    edPaint(H, "m:" .. t .. ":" .. tostring(ed.msgColor), 0x000000, { { 2, t, ed.msgColor } })
  end
end

-- ---------------------------------------------------------------------------
-- INPUT
-- ---------------------------------------------------------------------------

local function edOpenSelected()
  local row = ed.rows[ed.sel]
  if not row then return end
  if row.kind == "asteroid" then
    ed.mode, ed.asteroid = "detail", row.name
    ed.sel, ed.scroll = 1, 0
    edRebuild()
    edMoveSel(1)
  elseif row.kind == "opt" then
    SET.activate(row.spec)
  elseif row.kind == "par" then
    DRILL.editAll(row.key)
  elseif row.kind == "item" and ed.mode == "items" then
    local t = ed.targets[row.item]
    if t then
      ed.mode, ed.asteroid = "detail", t.asteroid
      ed.sel, ed.scroll = 1, 0
      edRebuild(); edMoveSel(1)
    else
      edSay(row.item .. " has no asteroid mapping", 0xFFAA00)
    end
  end
end

local function edAction(a)
  -- Any action other than a second CLOSE disarms the discard confirmation, so
  -- an armed CLOSE cannot sit waiting through a dozen further edits and then
  -- throw them away on a stray click.
  if a ~= "close" then ed.closeArmed = false end

  -- The prompt's own buttons. Handled first and returned from, because while a
  -- prompt is open nothing else on the button row should be reachable.
  if a == "input_ok" then
    if ed.input then
      local cb, buf = ed.input.onCommit, ed.input.buffer
      ed.input = nil
      cb(buf)
    elseif ed.filtering then
      ed.filtering = false; edSay("filter: " .. (ed.filter or ""))
    end
    return
  elseif a == "input_cancel" then
    if ed.input then
      ed.input = nil; edSay("cancelled -- value unchanged")
    elseif ed.filtering then
      ed.filtering = false; ed.filter = nil; edRebuild(); edSay("filter cleared")
    end
    return
  end

  if a == "close" then
    -- REFUSE THE FIRST CLOSE IF IT WOULD LOSE WORK.
    --
    -- Everything typed in here lives in a working copy until edSave runs; close
    -- used to drop the lot without a word. Two presses rather than a modal
    -- dialog: the editor has no modal machinery and this does not justify
    -- inventing some.
    local pending = edDirtyCount()
    if pending > 0 and not ed.closeArmed then
      ed.closeArmed = true
      edSay(string.format(
        "%d unsaved change(s) -- s saves them, CLOSE again discards", pending), 0xFFAA00)
      return
    end
    ed.open = false
    ed.closeArmed = false
    -- Same reason as on open: the panels are about to overwrite these rows, so
    -- the cache must not claim they still hold editor content.
    edInvalidate()
    drawStaticFrame()
  elseif a == "activate" then
    -- Space. What it activates depends on the row, which is why this lives here
    -- beside the other row-sensitive actions rather than inline in the key
    -- dispatch -- the dispatch table only needs to know the name.
    local row = selectedRow()
    if row and row.kind == "item" then
      edToggle(row.item, ed.mode == "detail" and ed.asteroid or
                         (ed.targets[row.item] and ed.targets[row.item].asteroid))
      edRebuild()
    elseif row and row.kind == "asteroid" then
      edOpenSelected()
    elseif row and row.kind == "par" then
      DRILL.toggle(row.key)
    elseif row and row.kind == "opt" then
      SET.activate(row.spec)
    end
  elseif a == "type" then
    local row = selectedRow()
    if row and row.kind == "item" then edTypeTarget(row.item)
    elseif row and row.kind == "par" then DRILL.editAll(row.key)
    elseif row and row.kind == "opt" then SET.prompt(row.spec) end
  elseif a == "step" then
    local row = selectedRow()
    if row and row.kind == "item" then edCycleTarget(row.item) end
  elseif a == "changed" then
    if ed.mode ~= "settings" then
      edSay("changed-only applies to the settings page", 0xFFAA00)
    else
      ed.changedOnly = not ed.changedOnly
      ed.sel, ed.scroll = 1, 0
      edRebuild()
      edMoveSel(1)
      edSay(ed.changedOnly and "showing only settings that differ from shipped"
                            or "showing all settings")
    end
  elseif a == "back" then
    if ed.mode == "detail" or ed.mode == "drills" or ed.mode == "settings" then
      ed.mode, ed.asteroid = "asteroids", nil
      ed.sel, ed.scroll = 1, 0
      edRebuild()
      edMoveSel(1)
    else
      edAction("close")
    end
  elseif a == "items" then
    ed.mode = "items"; ed.sel, ed.scroll = 1, 0; edRebuild()
  elseif a == "drills" then
    ed.mode, ed.asteroid = "drills", nil
    ed.sel, ed.scroll = 1, 0
    edRebuild()
    edMoveSel(1)   -- row 1 is a header
  elseif a == "settings" then
    ed.mode, ed.asteroid = "settings", nil
    ed.sel, ed.scroll = 1, 0
    edRebuild()
    edMoveSel(1)   -- row 1 is a header
  elseif a == "reset" then
    local row = selectedRow()
    if row and row.kind == "opt" then SET.reset(row.spec)
    else edSay("select a setting first -- R restores its shipped default", 0xFFAA00) end
  elseif a == "asteroids" then
    ed.mode, ed.asteroid = "asteroids", nil; ed.sel, ed.scroll = 1, 0; edRebuild()
  elseif a == "add" then
    if ed.mode == "detail" then edAddDownstream()
    else edSay("open an asteroid first, then A adds one of its outputs", 0xFFAA00) end
  elseif a == "find" then
    ed.filtering = true; ed.filter = ""; edRebuild()
  elseif a == "save" then
    edSave()
  end
end


-- Returns true if the event was consumed.
local function edHandle(ev)
  local kind = ev[1]

  if kind == "touch" then
    local x, y = ev[3], ev[4]
    if y == H - 1 then
      for _, b in ipairs(edButtons) do
        if x >= b.x1 and x <= b.x2 then edAction(b.action) return true end
      end
      return true
    end
    -- A prompt is modal to the mouse as well as the keyboard: the button row
    -- above is OK/CANCEL while one is open, and clicking a list row underneath
    -- it used to open a second prompt over the first.
    if ed.input or ed.filtering then return true end
    if y >= edFirst() and y < edFirst() + edRows() then
      local idx = ed.scroll + (y - edFirst()) + 1
      local row = ed.rows[idx]
      if row and row.kind ~= "header" and row.kind ~= "note" then
        ed.sel = idx
        if row.kind == "asteroid" then
          edOpenSelected()
        elseif row.kind == "opt" then
          -- Clicking the VALUE column opens the prompt, so a long choice list
          -- can be typed rather than cycled through. A bool has nothing to
          -- type, so it toggles wherever you click it.
          if x >= X_A and x < X_C and row.spec.type ~= "bool" then
            SET.prompt(row.spec)
          else
            SET.activate(row.spec)
          end
        elseif row.kind == "par" then
          -- Click the column you want rather than walking all three.
          if     x >= X_A and x < X_B then DRILL.editField(row.key, "tips")
          elseif x >= X_B and x < X_C then DRILL.editField(row.key, "rods")
          elseif x >= X_C and x < DRILL.xStock then DRILL.editField(row.key, "batch")
          else DRILL.toggle(row.key) end
        elseif x >= X_A and x < X_B then
          edTypeTarget(row.item)
        else
          edToggle(row.item, ed.mode == "detail" and ed.asteroid or
                             (ed.targets[row.item] and ed.targets[row.item].asteroid))
          edRebuild()
        end
      end
    end
    return true

  elseif kind == "scroll" then
    ed.scroll = ed.scroll - (ev[5] or 0) * 3
    local maxScroll = math.max(0, #ed.rows - edRows())
    if ed.scroll > maxScroll then ed.scroll = maxScroll end
    if ed.scroll < 0 then ed.scroll = 0 end
    return true

  elseif kind == "key_down" then
    local ch, code = ev[3], ev[4]

    -- CANCELLING A TEXT PROMPT.
    --
    -- Tab, because it is the only one of these that can work here: q is a
    -- character you might be typing and backspace already deletes one. Delete
    -- and Escape ride along as aliases -- see the K table's header for why
    -- Escape never actually arrives.
    local isCancel = (code == K.TAB or code == K.DELETE or code == K.ESC)

    -- Text entry swallows printable keys. Never blocks the scheduler.
    if ed.input then
      if code == K.ENTER then
        local cb, buf = ed.input.onCommit, ed.input.buffer
        ed.input = nil
        cb(buf)
      elseif isCancel then
        ed.input = nil; edSay("cancelled -- value unchanged")
      elseif code == K.BACKSPACE then
        ed.input.buffer = ed.input.buffer:sub(1, -2)
      elseif ch and ch >= 32 and ch < 127 then
        ed.input.buffer = ed.input.buffer .. string.char(ch)
      end
      return true
    end

    if ed.filtering then
      if code == K.ENTER then
        ed.filtering = false; edSay("filter: " .. (ed.filter or ""))
      elseif isCancel then
        ed.filtering = false; ed.filter = nil; edRebuild(); edSay("filter cleared")
      elseif code == K.BACKSPACE then
        ed.filter = (ed.filter or ""):sub(1, -2); edRebuild()
      elseif ch and ch >= 32 and ch < 127 then
        ed.filter = (ed.filter or "") .. string.char(ch):lower(); edRebuild()
      end
      return true
    end

    -- Navigation stays a ladder: these are not actions, they advertise nothing,
    -- and putting them in EDKEYS would only give the legend rows to skip.
    if     code == K.UP   then edMoveSel(-1)
    elseif code == K.DOWN then edMoveSel(1)
    elseif code == K.PGUP then edMoveSel(-edRows())
    elseif code == K.PGDN then edMoveSel(edRows())
    elseif code == K.HOME then ed.sel = 1; edMoveSel(1); edMoveSel(-1); edFollow()
    elseif code == K.END_ then ed.sel = #ed.rows; edMoveSel(-1); edMoveSel(1); edFollow()
    elseif code == K.ENTER then edOpenSelected()
    else
      -- Everything else comes off EDKEYS, which is also what built the legend
      -- above, so the two cannot disagree about what is bound.
      local binding = edBindingFor(ch, code)
      if binding then edAction(binding.action) end
    end
    return true
  end

  return false
end

-- ---------------------------------------------------------------------------
-- WIRING
-- ---------------------------------------------------------------------------
function editor.init(deps)
  config           = deps.config
  gpu              = deps.gpu
  W, H             = deps.W, deps.H
  brokerState      = deps.brokerState
  drillKeyOrder    = deps.drillKeyOrder
  usableDrillKeys  = deps.usableDrillKeys
  formatQty        = deps.formatQty
  drawStaticFrame  = deps.drawStaticFrame
  edTouch          = deps.edTouch
  edGen            = deps.edGen
  resetDustScroll  = deps.resetDustScroll

  -- The two things that used to be computed at load time, when config and W
  -- were already in scope because all of this was one chunk.
  SET.spec = config.settingsSpec
  -- A narrow screen would not truncate the stock column, it would collide with
  -- BATCH and print nonsense, so it is guarded rather than assumed.
  DRILL.stockFits = W >= 90
end

-- ---------------------------------------------------------------------------
-- WHAT THE BROKER CAN ASK
--
-- Deliberately small. The broker owns the screen, the schedule and the
-- hardware; this owns one input mode. Everything below replaces a place where
-- the main loop used to reach straight into `ed`.
-- ---------------------------------------------------------------------------

function editor.isOpen() return ed.open end

-- Opening is the handover out of the quiesce countdown. drawUI has been
-- painting this screen, so the row cache describes something that is about to
-- stop being true -- dropping it is not optional.
function editor.open(busyModules)
  ed.open = true
  edInvalidate()
  edBuild()
  if (busyModules or 0) > 0 then
    -- Opened on the grace rather than because the broker went quiet. Say so:
    -- otherwise it looks like the wait did not work, and it explains why the
    -- editor may feel sluggish for the next few seconds.
    edSay(busyModules .. " module(s) still working -- editor may lag briefly", 0xFFAA00)
  else
    edSay("new jobs paused while this is open -- tab or q to resume mining")
  end
  ed.dirty = true
end

-- Returns true when the event was consumed. The broker keeps running the
-- scheduler and the module lifecycle either way: this owns input, not execution.
function editor.handle(ev)
  local consumed = edHandle(ev)
  if consumed then ed.dirty = true end
  return consumed
end

function editor.draw() edDraw() end

function editor.needsRepaint() return ed.dirty end
function editor.clearRepaint() ed.dirty = false end

-- The quiesce countdown lives in the broker but has to accept the same keys
-- this does. Asking here is what stops the two drifting apart -- which is
-- exactly how "esc" outlived the key working.
function editor.isCancelKey(ch, code)
  local b = edBindingFor(ch, code)
  return b ~= nil and b.action == "back"
end

-- Drained, not read: a save sets these and the broker broadcasts on them, so
-- returning without clearing would rebroadcast every pass.
function editor.takeRequests()
  local w, p, n = edRequestWatchlist, edRequestPar, edRequestNodes
  edRequestWatchlist, edRequestPar, edRequestNodes = false, false, false
  return w, p, n
end

-- For the test suite, which drives these directly. Not used by the broker.
editor._internal = {
  ed          = ed,
  EDKEYS      = EDKEYS,
  K           = K,
  dirtyCount  = edDirtyCount,
  bindingFor  = edBindingFor,
  legend      = edLegend,
  action      = edAction,
}

return editor
