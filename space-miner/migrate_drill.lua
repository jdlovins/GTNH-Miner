-- =============================================================================
-- migrate_drill.lua — carry hand-edited drill settings into user_config.lua
--
-- RUN THIS BEFORE UPDATING config.lua. It reads the drill settings off the
-- config.lua currently on this machine and writes the ones that differ from the
-- shipped defaults into /home/user_config.lua, where the update cannot reach
-- them. Then update normally and your values come back through the overlay.
--
--   migrate_drill                     read /home/config.lua
--   migrate_drill /home/config.bak    read a backup instead
--   migrate_drill --dry               show what would change, write nothing
--
-- WHY THIS EXISTS
--
-- config.lua is shipped data. install-medina wgets it straight over the top, so
-- anything you changed in it is gone on the next update -- which was fine while
-- drill settings were the one thing you HAD to edit there to change. They are
-- not any more: the broker's edit menu owns them now (press E, then d) and
-- writes them to user_config.lua, which no update touches.
--
-- This script is the one-time bridge between those two worlds. After it has run
-- you should never need it again; change drill settings in the editor instead.
--
-- WHAT IT MOVES
--   config.drillPar     per material: tips and rods floors, and batch size
--   tipsPerLoad, rodsPerLoad, tipsToStart, rodsToStart, drillCraftSlots
--
-- Nothing else. Conditions and dust mappings are already the editor's, and if
-- you have a user_config.lua they are already safe in it -- this script reads
-- that file and writes it back with yours intact.
-- =============================================================================

local CONFIG_PATH      = "/home/config.lua"
local USER_CONFIG_PATH = "/home/user_config.lua"
local QUOTE            = string.char(34)

-- The shipped defaults AS OF THE VERSION THIS SCRIPT SHIPS WITH. Pinned here on
-- purpose rather than read from the new config.lua: the whole point is to run
-- before that file arrives, so it is not there to read. A value of yours that
-- matches one of these is not a customisation and is left alone, so it keeps
-- following config.lua the way an untouched setting should.
local SHIPPED_PAR = {
  steel             = { tips = 4096, rods = 4096, batch = 4096 },
  titanium          = { tips = 4096, rods = 4096, batch = 4096 },
  tungstensteel     = { tips = 4096, rods = 4096, batch = 4096 },
  naquadah          = { tips = 2048, rods = 2048, batch = 2048 },
  naquadahAlloy     = { tips = 2048, rods = 2048, batch = 2048 },
  neutronium        = { tips = 1024, rods = 1024, batch = 1024 },
  cosmicNeutronium  = { tips =  256, rods =  256, batch =  256 },
  infinity          = { tips =  256, rods =  256, batch =  256 },
  transcendentMetal = { tips =  256, rods =  256, batch =  256 },
}

local SHIPPED_LOAD = {
  tipsPerLoad = 128, rodsPerLoad = 128,
  tipsToStart =  64, rodsToStart =  64,
  drillCraftSlots = 2,
}

-- Order, not just membership: the written file should read the same way
-- config.lua does rather than in hash order.
local PAR_ORDER = {
  "steel", "titanium", "tungstensteel", "naquadah", "naquadahAlloy",
  "neutronium", "cosmicNeutronium", "infinity", "transcendentMetal"
}
local LOAD_ORDER = {
  "tipsPerLoad", "rodsPerLoad", "tipsToStart", "rodsToStart", "drillCraftSlots"
}

-- ---------------------------------------------------------------------------
-- ARGS
-- ---------------------------------------------------------------------------

local args   = { ... }
local dryRun = false
for _, a in ipairs(args) do
  if a == "--dry" or a == "-n" then dryRun = true
  elseif a:sub(1, 1) ~= "-" then CONFIG_PATH = a end
end

local function die(msg)
  io.write("\n" .. msg .. "\n")
  os.exit(1)
end

-- ---------------------------------------------------------------------------
-- READ THE OLD CONFIG
-- ---------------------------------------------------------------------------

local f = io.open(CONFIG_PATH, "r")
if not f then die("cannot read " .. CONFIG_PATH .. " -- pass the path as an argument") end
f:close()

local ok, old = pcall(dofile, CONFIG_PATH)
if not ok then die("could not load " .. CONFIG_PATH .. ": " .. tostring(old)) end
if type(old) ~= "table" then die(CONFIG_PATH .. " did not return a config table") end

io.write("MEDINA drill settings migration\n")
io.write("reading  " .. CONFIG_PATH .. "\n")

-- Already updated? Then this file's drill values are the new shipped ones and
-- there is nothing of yours left in it to rescue. Say so plainly rather than
-- reporting "no changes found", which would read as reassurance.
-- `settingsSpec` is the marker for a config.lua that carries the settings
-- registry, which is every version that has an overlay at all. It replaced
-- `drillLoadFields`, which was the marker while the five load fields were a
-- table of their own -- checking for that now would call every current
-- config.lua "old" and offer to migrate settings out of it that are not there.
if old.settingsSpec or old.shippedSettings then
  io.write("\nThis config.lua is ALREADY the new version -- it has the drill overlay\n")
  io.write("built in, so whatever you had hand-edited was overwritten by the update.\n")
  io.write("\nIf you have a backup, point this script at it:\n")
  io.write("  migrate_drill /home/config.lua.bak\n")
  io.write("\nOtherwise set your values in the editor: run broker-mk3, press E, then d.\n")
  os.exit(0)
end

-- ---------------------------------------------------------------------------
-- DIFF
--
-- Only what differs is carried across. Migrating a value that already matches
-- the shipped default would pin it, and it would then stop following config.lua
-- forever -- which is the exact problem this script exists to undo, applied to
-- settings you never actually chose.
-- ---------------------------------------------------------------------------

local parOut, loadOut = {}, {}
local rows, n = {}, 0

local oldPar = type(old.drillPar) == "table" and old.drillPar or {}

for _, key in ipairs(PAR_ORDER) do
  local sh, cur = SHIPPED_PAR[key], oldPar[key]
  if type(cur) ~= "table" then
    -- Deleted or commented out. That is a real choice -- "never order this" --
    -- and `false` is how the overlay says it.
    if sh then
      parOut[key] = false; n = n + 1
      rows[#rows + 1] = { key, "not ordered", "shipped: on" }
    end
  else
    local tips  = cur.tips  or 0
    local rods  = cur.rods  or 0
    local batch = cur.batch or cur.tips or 0
    if not sh or sh.tips ~= tips or sh.rods ~= rods or sh.batch ~= batch then
      parOut[key] = { tips = tips, rods = rods, batch = batch }
      n = n + 1
      rows[#rows + 1] = { key,
        string.format("%d / %d / %d", tips, rods, batch),
        sh and string.format("shipped: %d / %d / %d", sh.tips, sh.rods, sh.batch)
           or  "shipped: not listed" }
    end
  end
end

for _, key in ipairs(LOAD_ORDER) do
  local cur = old[key]
  if type(cur) == "number" and cur >= 1 and cur ~= SHIPPED_LOAD[key] then
    loadOut[key] = math.floor(cur)
    n = n + 1
    rows[#rows + 1] = { key, tostring(math.floor(cur)),
                        "shipped: " .. tostring(SHIPPED_LOAD[key]) }
  end
end

if n == 0 then
  io.write("\nNothing to migrate -- every drill setting in this config.lua matches the\n")
  io.write("shipped defaults, so an update will not change any of them.\n")
  os.exit(0)
end

io.write("\nFound " .. n .. " setting(s) of your own:\n\n")
for _, r in ipairs(rows) do
  io.write(string.format("  %-20s %-22s %s\n", r[1], r[2], r[3]))
end

-- The one case worth a second look. A stale shipped default reads exactly like
-- a deliberate choice from here -- both are "your number differs from the new
-- one" -- and carrying it across pins you to a value you never picked.
io.write("\nCheck these are yours. A value left over from an older config.lua looks\n")
io.write("identical to a deliberate one from here, and migrating it pins you to it.\n")
io.write("Anything you did not want is two keystrokes to change later: press E, then d.\n")

-- ---------------------------------------------------------------------------
-- MERGE INTO user_config.lua
--
-- Read first, write second. This file already holds what you track and any dust
-- mappings you added, and clobbering those to save drill settings would be a
-- poor trade. Only the two drill blocks are replaced.
-- ---------------------------------------------------------------------------

local user = {}
local hadUserConfig = false
local uf = io.open(USER_CONFIG_PATH, "r")
if uf then
  uf:close()
  hadUserConfig = true
  local uok, loaded = pcall(dofile, USER_CONFIG_PATH)
  if not uok or type(loaded) ~= "table" then
    die("\n" .. USER_CONFIG_PATH .. " exists but will not load:\n  " .. tostring(loaded) ..
        "\nFix or move it before running this, or its contents would be lost.")
  end
  user = loaded
  local c = type(user.conditions)  == "table" and #user.conditions or 0
  local d = 0
  if type(user.dustTargets) == "table" then for _ in pairs(user.dustTargets) do d = d + 1 end end
  io.write(string.format("\nmerging into %s (keeping %d tracked item(s), %d mapping(s))\n",
    USER_CONFIG_PATH, c, d))
else
  io.write("\ncreating " .. USER_CONFIG_PATH .. "\n")
end

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
out[#out + 1] = "--"
out[#out + 1] = "-- The drill blocks below were migrated out of config.lua by migrate_drill."
out[#out + 1] = ""
out[#out + 1] = "return {"

out[#out + 1] = "  conditions = {"
for _, cond in ipairs(type(user.conditions) == "table" and user.conditions or {}) do
  if cond.itemName then
    out[#out + 1] = string.format("    { itemName = %-38s amountToMaintain = %-10d },",
      QUOTE .. cond.itemName .. QUOTE .. ",", cond.amountToMaintain or 5000000)
  end
end
out[#out + 1] = "  },"

out[#out + 1] = "  dustTargets = {"
local names = {}
for item in pairs(type(user.dustTargets) == "table" and user.dustTargets or {}) do
  names[#names + 1] = item
end
table.sort(names)
for _, item in ipairs(names) do
  local t = user.dustTargets[item]
  out[#out + 1] = string.format("    [%s%s%s] = { asteroid = %s%s%s, priority = %d },",
    QUOTE, item, QUOTE, QUOTE, tostring(t.asteroid), QUOTE, t.priority or 99)
end
out[#out + 1] = "  },"

-- Yours wins over anything already in the file: you asked for the config.lua
-- values to be carried across, and a half-migrated state helps nobody.
out[#out + 1] = "  drillPar = {"
for _, key in ipairs(PAR_ORDER) do
  local v = parOut[key]
  if v == nil and type(user.drillPar) == "table" then v = user.drillPar[key] end
  if v == false then
    out[#out + 1] = string.format("    %-18s = false,   -- do not auto-craft", key)
  elseif type(v) == "table" then
    out[#out + 1] = string.format("    %-18s = { tips = %d, rods = %d, batch = %d },",
      key, v.tips or 0, v.rods or 0, v.batch or 0)
  end
end
out[#out + 1] = "  },"

-- The five load fields are ordinary settings now, so they are written into the
-- `settings` block rather than a `drillLoad` one of their own.
--
-- Everything ELSE already in that block is copied through untouched. This
-- script rewrites user_config.lua whole, and it is the only block here that can
-- hold values this script knows nothing about -- dropping them would silently
-- undo every unrelated setting the editor had saved.
out[#out + 1] = "  settings = {"
local settingsOut = {}
local settingKeys = {}
for key, v in pairs(type(user.settings) == "table" and user.settings or {}) do
  settingsOut[key] = v
  settingKeys[#settingKeys + 1] = key
end
for _, key in ipairs(LOAD_ORDER) do
  -- Migrated value first, then anything a previous run left in either block.
  local v = loadOut[key]
  if v == nil and type(user.drillLoad) == "table" then v = user.drillLoad[key] end
  if type(v) == "number" then
    if settingsOut[key] == nil then settingKeys[#settingKeys + 1] = key end
    settingsOut[key] = v
  end
end
table.sort(settingKeys)
for _, key in ipairs(settingKeys) do
  local v = settingsOut[key]
  local lit
  if type(v) == "string" then lit = QUOTE .. v .. QUOTE
  elseif type(v) == "boolean" then lit = v and "true" or "false"
  elseif type(v) == "number" then lit = tostring(v)
  end
  -- Bracket a dotted key: `logging.enabled = x` is a syntax error in a table
  -- constructor. Only preserved keys can be dotted -- the five migrated ones
  -- never are -- but this file is rewritten whole, so a key it does not
  -- understand still has to come out valid.
  local name = key:find(".", 1, true)
    and string.format("[%s%s%s]", QUOTE, key, QUOTE) or key
  if lit then out[#out + 1] = string.format("    %-24s = %s,", name, lit) end
end
out[#out + 1] = "  },"
out[#out + 1] = "}"

local text = table.concat(out, "\n") .. "\n"

if dryRun then
  io.write("\n--- would write " .. USER_CONFIG_PATH .. " ---\n")
  io.write(text)
  io.write("--- dry run, nothing written ---\n")
  os.exit(0)
end

io.write("\nWrite it? [y/N] ")
local answer = io.read()
if not answer or answer:lower():sub(1, 1) ~= "y" then
  io.write("nothing written\n")
  os.exit(0)
end

-- Back the old file up before replacing it. It is small, this is a one-shot
-- script, and the alternative to a backup here is retyping a watchlist.
if hadUserConfig then
  local src = io.open(USER_CONFIG_PATH, "r")
  if src then
    local body = src:read("*a"); src:close()
    local bak = io.open(USER_CONFIG_PATH .. ".bak", "w")
    if bak then bak:write(body); bak:close()
      io.write("previous file saved as " .. USER_CONFIG_PATH .. ".bak\n")
    end
  end
end

local w = io.open(USER_CONFIG_PATH, "w")
if not w then die("cannot write " .. USER_CONFIG_PATH) end
w:write(text)
w:close()

io.write("wrote " .. USER_CONFIG_PATH .. "\n")
io.write("\nYou can update config.lua now -- run install-medina and pick your role.\n")
io.write("After it finishes, start the broker and check the values with E then d.\n")
