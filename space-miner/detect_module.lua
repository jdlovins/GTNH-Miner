-- =============================================================================
-- detect_module.lua
-- Detects a newly-added Mining Module and appends it to job_node_config.lua.
--
-- WORKFLOW (one module at a time):
--   1. Physically add the new module's three components:
--        - gt_machine  adapter  (controls the Mining Module)
--        - me_interface adapter (the module's ME Interface)
--        - transposer           (moves items interface buffer -> input bus)
--   2. Run this script. It finds the components NOT already in the config.
--   3. It shows the detected module + the sides it copied from the last module,
--      and asks you to confirm before writing anything.
--   4. Verify the sides are right for this module's physical orientation, type y.
--   5. Repeat for the next module.
--
-- It deliberately handles ONE new module per run. If it finds zero or more than
-- one new component of any type, it stops and reports — so a stray cable or a
-- double-add can never silently produce a garbage config.
--
-- Sides (interfaceSide / inputBusSide) CANNOT be auto-detected — they depend on
-- physical orientation. We copy them from the most recent existing module (you
-- add modules in physical groups that usually share orientation) and print them
-- loudly for you to confirm.
-- =============================================================================

local component = require("component")
local fsExists  = require("filesystem").exists

local CONFIG_PATH = "/home/job_node_config.lua"

-- Component type strings as OpenComputers reports them.
local TYPE_MACHINE    = "gt_machine"
local TYPE_INTERFACE  = "me_interface"
local TYPE_TRANSPOSER = "transposer"
local TYPE_DATABASE   = "database"

print("=== DETECT MODULE ===")

-- ---------------------------------------------------------------------------
-- Load existing config, OR bootstrap a fresh one if none exists yet.
-- On a brand-new setup there's no job_node_config.lua and no modules, so we
-- create the skeleton here: auto-detect the shared database and ask for a node
-- name, then fall through to the normal "detect the new module" flow as M1.
-- ---------------------------------------------------------------------------
local config
if fsExists(CONFIG_PATH) then
  config = dofile(CONFIG_PATH)
end

if not config or type(config) ~= "table" then
  config = { nodeId = "", dbAddr = "", modules = {} }
end
config.modules = config.modules or {}

-- Ensure we have a shared database address. If missing OR still a placeholder,
-- auto-detect: there should be exactly one 'database' component on the broker.
-- Iterate the full list and substring-match the type (robust to type string).
if not config.dbAddr or config.dbAddr == "" or config.dbAddr:find("REPLACE", 1, true) then
  local dbs = {}
  for addr, ctype in component.list() do
    if ctype:find(TYPE_DATABASE, 1, true) then dbs[#dbs + 1] = addr end
  end
  if #dbs == 1 then
    config.dbAddr = dbs[1]
    print("Auto-detected shared database: " .. config.dbAddr)
  elseif #dbs == 0 then
    error("No 'database' component found. Attach an OC Database upgrade/component.")
  else
    print("Multiple databases found — pick one for dbAddr and set it manually:")
    for _, a in ipairs(dbs) do print("  " .. a) end
    error("Set config.dbAddr manually when more than one database exists.")
  end
end

-- Ensure a node name.
if not config.nodeId or config.nodeId == "" then
  io.write("Node name (nodeId) [MEDINA-Ring-1]: ")
  local n = io.read()
  if not n or n == "" then n = "MEDINA-Ring-1" end
  config.nodeId = n
end

-- Prune placeholder / invalid module entries before we do anything else.
-- The example config (or a half-edited one) can contain a stub module with
-- "REPLACE-..." addresses, or addresses that aren't real live components. Those
-- must NOT count as existing modules — otherwise detect_module would add your
-- first real module as M2 and leave the stub as M1. Build a set of live
-- component addresses, then drop any module entry that isn't backed by one.
local liveAddrs = {}
for addr in component.list() do liveAddrs[addr] = true end

local function isLiveAddr(a)
  if not a or a == "" then return false end
  if a:find("REPLACE", 1, true) then return false end   -- obvious placeholder
  for live in pairs(liveAddrs) do
    -- Match on the common-length prefix (config may store 8 chars vs full UUID).
    local n = math.min(#a, #live)
    if a:sub(1, n) == live:sub(1, n) then
      return true
    end
  end
  return false
end

local validModules = {}
local prunedCount = 0
for _, mod in ipairs(config.modules) do
  -- Keep a module only if its core addresses are real live components.
  if isLiveAddr(mod.moduleAddr) and isLiveAddr(mod.ifaceAddr) and isLiveAddr(mod.transposerAddr) then
    validModules[#validModules + 1] = mod
  else
    prunedCount = prunedCount + 1
  end
end
config.modules = validModules
if prunedCount > 0 then
  print("Dropped " .. prunedCount .. " placeholder/stale module entr" ..
        (prunedCount == 1 and "y" or "ies") .. " (addresses not live components).")
end

local existingCount = #config.modules
print("Existing valid modules in config: " .. existingCount)

-- Build a set of every address the config already references, so we can tell
-- "new" hardware from "already configured" hardware. Addresses in the config may
-- be stored short (8 chars) or full UUID; we normalize by prefix-matching.
local known = {}
for _, mod in ipairs(config.modules) do
  if mod.moduleAddr     then known[mod.moduleAddr]     = true end
  if mod.ifaceAddr      then known[mod.ifaceAddr]      = true end
  if mod.transposerAddr then known[mod.transposerAddr] = true end
end
-- Also treat the shared database as known so it's never mistaken for new.
if config.dbAddr then known[config.dbAddr] = true end

-- Is a live address already referenced by the config? Config addresses may be
-- stored short (8 chars) or as a full UUID, so we match if the shorter string is
-- a genuine prefix of the longer one — comparing the LONGER address truncated to
-- the shorter's length against the shorter string.
--   (The earlier version had a bug: `cfgAddr:sub(1,#fullAddr) == cfgAddr` is
--    always true when both are the same length, so every component looked
--    "known" and nothing was ever detected as new.)
local function isKnown(fullAddr)
  for cfgAddr in pairs(known) do
    local n = math.min(#fullAddr, #cfgAddr)
    if fullAddr:sub(1, n) == cfgAddr:sub(1, n) then
      return true
    end
  end
  return false
end

-- ---------------------------------------------------------------------------
-- Find new components of each type.
-- Modeled on list_components.lua: iterate component.list() with NO filter
-- (yields address, type), and bucket by SUBSTRING-matching the type. This is
-- robust to the exact type string — component.list("gt_machine") returns
-- nothing if the real type differs even slightly, but a substring match on the
-- full list does not. We also print every type we see, so if nothing matches
-- you can read the real names instead of getting a silent empty result.
-- ---------------------------------------------------------------------------
local newMachines, newInterfaces, newTransposers = {}, {}, {}
local seenTypes = {}

for addr, ctype in component.list() do
  seenTypes[ctype] = (seenTypes[ctype] or 0) + 1
  if not isKnown(addr) then
    if     ctype:find(TYPE_MACHINE,    1, true) then newMachines[#newMachines + 1]       = addr
    elseif ctype:find(TYPE_INTERFACE,  1, true) then newInterfaces[#newInterfaces + 1]   = addr
    elseif ctype:find(TYPE_TRANSPOSER, 1, true) then newTransposers[#newTransposers + 1] = addr
    end
  end
end

print("\nComponent types present on this computer:")
for t, n in pairs(seenTypes) do print(string.format("  %-22s x%d", t, n)) end

print(string.format("\nNew (unconfigured): %d %s, %d %s, %d %s",
  #newMachines, TYPE_MACHINE, #newInterfaces, TYPE_INTERFACE,
  #newTransposers, TYPE_TRANSPOSER))

-- ---------------------------------------------------------------------------
-- Validate the "exactly one new of each" assumption
-- ---------------------------------------------------------------------------
local function reportList(label, list)
  if #list > 0 then
    print("  " .. label .. ":")
    for _, a in ipairs(list) do print("    " .. a) end
  end
end

local ok = (#newMachines == 1 and #newInterfaces == 1 and #newTransposers == 1)
if not ok then
  print("\n[STOP] Expected exactly one new component of each type.")
  print("Add ONE module at a time, and check for loose adapters/cables.")
  reportList("new gt_machine",  newMachines)
  reportList("new me_interface", newInterfaces)
  reportList("new transposer",  newTransposers)
  if #newMachines == 0 and #newInterfaces == 0 and #newTransposers == 0 then
    print("\n(Nothing new detected. Check the module's hardware is connected. If")
    print(" the 'types present' list above doesn't show " .. TYPE_MACHINE .. " / " ..
          TYPE_INTERFACE .. " /")
    print(" " .. TYPE_TRANSPOSER .. ", the type names differ on your install — tell")
    print(" the script those names and they can be adjusted.)")
  end
  return
end

-- ---------------------------------------------------------------------------
-- Build the proposed module entry
-- ---------------------------------------------------------------------------
local newIndex = existingCount + 1
local template = config.modules[existingCount]  -- copy tier + sides from last module

-- OpenComputers transposer side numbers (sides API):
--   0 = bottom (down)    1 = top (up)
--   2 = north            3 = south
--   4 = west             5 = east
-- interfaceSide = the transposer face touching the ME Interface buffer.
-- inputBusSide  = the transposer face touching the module's Input Bus.
local SIDE_LEGEND = "0=down 1=up 2=north 3=south 4=west 5=east"

-- Prompt for a side number (0-5), defaulting to `def`. Re-asks on bad input.
local function askSide(label, def)
  while true do
    io.write(string.format("  %s side [%s] (default %d): ", label, SIDE_LEGEND, def))
    local s = io.read()
    if not s or s == "" then return def end
    local n = tonumber(s)
    if n and n >= 0 and n <= 5 and n == math.floor(n) then return n end
    print("    enter a number 0-5 (or blank for default)")
  end
end

local defIface = template and template.interfaceSide or 3
local defBus   = template and template.inputBusSide or 2
local srcNote  = template and ("default = M" .. existingCount .. "'s value")
                          or  "default = first-module guess"

print("\n=== NEW MODULE " .. newIndex .. " — detected components ===")
print("  moduleAddr     = " .. newMachines[1])
print("  ifaceAddr      = " .. newInterfaces[1])
print("  transposerAddr = " .. newTransposers[1])
print("\nNow set the transposer sides (" .. srcNote .. ").")
print("These depend on how this module is physically built — check your transposer.")

local proposed = {
  tier           = template and template.tier or "MK-II",
  moduleAddr     = newMachines[1],
  ifaceAddr      = newInterfaces[1],
  transposerAddr = newTransposers[1],
  interfaceSide  = askSide("Interface (ME Interface buffer)", defIface),
  inputBusSide   = askSide("Input Bus", defBus),
  distanceParam  = template and template.distanceParam or 0,
}

print("\n=== PROPOSED MODULE " .. newIndex .. " ===")
print("  tier           = " .. proposed.tier)
print("  moduleAddr     = " .. proposed.moduleAddr)
print("  ifaceAddr      = " .. proposed.ifaceAddr)
print("  transposerAddr = " .. proposed.transposerAddr)
print("  interfaceSide  = " .. proposed.interfaceSide)
print("  inputBusSide   = " .. proposed.inputBusSide)
print("  distanceParam  = " .. proposed.distanceParam)
io.write("\nWrite this as module " .. newIndex .. "? [y/N]: ")
local answer = io.read()
if not answer or answer:lower():sub(1, 1) ~= "y" then
  print("Aborted. No changes written.")
  return
end

-- ---------------------------------------------------------------------------
-- Append and write the config back
-- ---------------------------------------------------------------------------
config.modules[newIndex] = proposed

local f, err = io.open(CONFIG_PATH, "w")
if not f then error("Cannot open " .. CONFIG_PATH .. " for writing: " .. tostring(err)) end

f:write("return {\n")
f:write("  nodeId = \"" .. config.nodeId .. "\",\n")
f:write("  dbAddr = \"" .. config.dbAddr .. "\",\n")
f:write("  modules = {\n")
for i, mod in ipairs(config.modules) do
  f:write("    [" .. i .. "] = {\n")
  f:write("      tier           = \"" .. mod.tier .. "\",\n")
  f:write("      moduleAddr     = \"" .. mod.moduleAddr .. "\",\n")
  f:write("      ifaceAddr      = \"" .. mod.ifaceAddr .. "\",\n")
  f:write("      transposerAddr = \"" .. mod.transposerAddr .. "\",\n")
  f:write("      interfaceSide  = " .. mod.interfaceSide .. ",\n")
  f:write("      inputBusSide   = " .. mod.inputBusSide .. ",\n")
  f:write("      distanceParam  = " .. mod.distanceParam .. ",\n")
  -- pinnedAsteroid is optional and hand-set. Emit it only when present,
  -- so re-running this script never silently drops a module's pin.
  if mod.pinnedAsteroid then
    f:write("      pinnedAsteroid = \"" .. mod.pinnedAsteroid .. "\",\n")
  end
  f:write("    },\n")
end
f:write("  }\n")
f:write("}\n")
f:close()

print("\nModule " .. newIndex .. " written to " .. CONFIG_PATH)
print("Total modules now: " .. #config.modules)
print("\nIf the sides need correcting, edit the file or re-run after fixing orientation.")
print("Restart broker-mk3 to pick up the new module.")
