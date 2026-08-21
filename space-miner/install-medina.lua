-- =============================================================================
-- install-medina.lua — MEDINA installer
-- (Named install-medina, not install, to avoid colliding with OpenOS's built-in
--  'install' program.)
--
-- Run this once on each computer to download the files that computer needs.
-- It asks what role the computer plays, then wgets only the matching files
-- into /home/.
--
-- To get this script onto a fresh computer in the first place:
--   wget https://raw.githubusercontent.com/novashep/GTNH/main/space-miner/install-medina.lua /home/install-medina.lua
--   install-medina
--
-- Roles:
--   1) Broker        — the main computer (dispatch + module loading + UI)
--   2) Dust node     — monitors dust storage        (required telem)
--   3) Hardware node — monitors drones/drill kits    (required telem)
--   4) Fluid node    — monitors plasma               (required telem)
--   5) Remote job node (optional, multi-node fleets)
--   6) Everything    — grab every file (e.g. one shared drive / testing)
-- =============================================================================

local component = require("component")
local RAW = "https://raw.githubusercontent.com/jdlovins/GTNH-Miner/main/space-miner"

-- Files every role needs.
local COMMON = { "config.lua" }

-- Files per role (in addition to COMMON).
local ROLES = {
  ["broker"] = {
    label = "Broker (main computer)",
    files = { "broker-mk3.lua", "scheduler.lua", "loader.lua", "logger.lua",
              "list_components.lua", "detect_module.lua", "detect_sides.lua", "find_item.lua" },
    config = { ["job_node_config.example.lua"] = "job_node_config.lua" },
    note = "Edit /home/job_node_config.lua with your hardware, then run: broker-mk3",
  },
  ["dust"] = {
    label = "Dust monitor node (required)",
    files = { "dust_telem.lua" },
    note = "Set targetSide at the top of dust_telem.lua, then run: dust_telem",
  },
  ["hw"] = {
    label = "Hardware monitor node (required)",
    files = { "hw_telem.lua" },
    note = "Set targetSide at the top of hw_telem.lua, then run: hw_telem",
  },
  ["fluid"] = {
    label = "Fluid/plasma monitor node (required)",
    files = { "fluid_telem.lua" },
    note = "Set targetSide at the top of fluid_telem.lua, then run: fluid_telem",
  },
  ["jobnode"] = {
    label = "Remote job node (optional, multi-node fleets)",
    files = { "job_node.lua", "list_components.lua", "detect_module.lua", "detect_sides.lua", "find_item.lua" },
    config = { ["job_node_config.example.lua"] = "job_node_config.lua" },
    note = "Edit /home/job_node_config.lua (give it a unique nodeId), then run: job_node",
  },
}

local fs = require("filesystem")

-- Download one file from RAW into /home/<dest>. Returns true on success.
-- We verify by checking the file exists and is non-empty afterward, rather than
-- trusting os.execute's return (which is unreliable in OpenOS).
local function fetch(name, dest)
  dest = dest or name
  local target = "/home/" .. dest
  io.write("  " .. name .. " -> " .. target .. " ... ")
  os.execute("wget -fq " .. RAW .. "/" .. name .. " " .. target)  -- -f overwrite, -q quiet
  local size = fs.size(target)
  if fs.exists(target) and size and size > 0 then
    print("ok (" .. size .. "b)")
    return true
  else
    print("FAILED")
    return false
  end
end

-- Don't clobber an existing job_node_config.lua (it holds the user's addresses).
local function fetchConfigExample(srcName, destName)
  local dest = "/home/" .. destName
  if fs.exists(dest) then
    print("  " .. destName .. " already exists — leaving it untouched.")
    return true
  end
  return fetch(srcName, destName)
end

local function installRole(key)
  local role = ROLES[key]
  if not role then print("Unknown role: " .. tostring(key)); return end

  print("\nInstalling: " .. role.label)
  print("From: " .. RAW)
  print("")

  local allOk = true
  for _, f in ipairs(COMMON) do
    if not fetch(f) then allOk = false end
  end
  for _, f in ipairs(role.files) do
    if not fetch(f) then allOk = false end
  end
  if role.config then
    for src, dest in pairs(role.config) do
      if not fetchConfigExample(src, dest) then allOk = false end
    end
  end

  print("")
  if allOk then
    print("Install complete.")
  else
    print("Some files FAILED — check the network card / internet access and re-run.")
  end
  if role.note then print("\nNext: " .. role.note) end
end

-- ---------------------------------------------------------------------------
-- Pre-flight: need an internet card to wget.
-- ---------------------------------------------------------------------------
if not component.isAvailable("internet") then
  print("ERROR: no Internet Card found. wget needs one to download files.")
  print("Install an OpenComputers Internet Card and try again.")
  return
end

-- ---------------------------------------------------------------------------
-- Menu
-- ---------------------------------------------------------------------------
print("================================================")
print("  MEDINA INSTALLER")
print("================================================")
print("What is this computer?")
print("  1) Broker        (main computer)")
print("  2) Dust node     (required monitor)")
print("  3) Hardware node (required monitor)")
print("  4) Fluid node    (required monitor)")
print("  5) Remote job node (optional)")
print("  6) Everything    (all files)")
io.write("Choice [1-6]: ")

local choice = tonumber(io.read())
local map = { [1]="broker", [2]="dust", [3]="hw", [4]="fluid", [5]="jobnode" }

if choice == 6 then
  -- Grab the whole shipped set into /home/ (config example never overwrites a
  -- real job_node_config.lua).
  print("\nInstalling EVERYTHING from " .. RAW .. "\n")
  local everything = {
    "config.lua", "broker-mk3.lua", "scheduler.lua", "loader.lua", "logger.lua",
    "list_components.lua", "detect_module.lua", "detect_sides.lua", "find_item.lua",
    "dust_telem.lua", "hw_telem.lua", "fluid_telem.lua", "job_node.lua",
  }
  local allOk = true
  for _, f in ipairs(everything) do if not fetch(f) then allOk = false end end
  fetchConfigExample("job_node_config.example.lua", "job_node_config.lua")
  print(allOk and "\nInstall complete." or "\nSome files FAILED — check internet and re-run.")
elseif map[choice] then
  installRole(map[choice])
else
  print("No valid choice made. Re-run 'install' and pick 1-6.")
end
