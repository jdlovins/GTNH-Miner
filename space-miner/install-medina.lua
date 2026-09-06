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

-- There is no COMMON list any more, and that is the point.
--
-- config.lua is three thousand lines of asteroid data. It used to be installed
-- everywhere, including on the telemetry nodes, which read three values out of
-- it and then ran out of memory holding an ME network scan.
--
-- A telemetry node is now ONE FILE. The only thing written down on it is the
-- pair of port numbers it cannot be told over the air; everything else is
-- pushed by the broker at runtime.
local ROLES = {
  ["broker"] = {
    label = "Broker (main computer)",
    files = { "config.lua", "settings.lua",
              "broker-mk3.lua", "scheduler.lua", "loader.lua", "logger.lua",
              "module_api.lua", "editor.lua",
              "list_components.lua", "detect_module.lua", "detect_sides.lua", "find_item.lua",
              "migrate_drill.lua" },
    config = { ["job_node_config.example.lua"] = "job_node_config.lua" },
    note = "Edit /home/job_node_config.lua with your hardware, then run: broker-mk3",
  },
  ["dust"] = {
    label = "Dust monitor node (required)",
    files = { "dust_telem.lua" },
    note = "run: dust_telem  (what to scan is pushed by the broker -- give it ~30s)",
  },
  ["hw"] = {
    label = "Hardware monitor node (required)",
    files = { "hw_telem.lua" },
    note = "run: hw_telem  (loads no config at all -- the broker pushes what it needs)",
  },
  ["fluid"] = {
    label = "Fluid/plasma monitor node (required)",
    files = { "fluid_telem.lua" },
    note = "Set targetSide at the top of fluid_telem.lua, then run: fluid_telem",
  },
  ["jobnode"] = {
    label = "Remote job node (optional, multi-node fleets)",
    files = { "config.lua", "settings.lua",
              "job_node.lua", "module_api.lua", "list_components.lua", "detect_module.lua",
              "detect_sides.lua", "find_item.lua" },
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

-- config.lua is fetched before anything else, which means an install destroys a
-- hand-edited one before the script that could have rescued it has even landed.
-- So copy it aside first. Costs one small file and removes the only irreversible
-- step in an install.
--
-- Returns true if the backup is a PRE-overlay config -- one whose drill settings
-- lived in config.lua itself, and are therefore worth migrating.
local function backupConfig()
  local path = "/home/config.lua"
  if not fs.exists(path) then return false end

  local src = io.open(path, "r")
  if not src then return false end
  local body = src:read("*a")
  src:close()

  local bak = io.open(path .. ".bak", "w")
  if not bak then return false end
  bak:write(body)
  bak:close()
  print("  config.lua -> /home/config.lua.bak (backup of your current one)")

  -- Text match rather than dofile: this runs before the new config lands, and a
  -- half-written or hand-broken file should not stop the install.
  return body:find("settingsSpec", 1, true) == nil
end

local hadOldConfig = false

-- Don't clobber an existing job_node_config.lua (it holds the user's addresses).
local function fetchConfigExample(srcName, destName)
  local dest = "/home/" .. destName
  if fs.exists(dest) then
    print("  " .. destName .. " already exists — leaving it untouched.")
    return true
  end
  return fetch(srcName, destName)
end

-- Drill settings used to live in config.lua, which an install overwrites. Say so
-- while the backup is still fresh, and only when there is actually something to
-- rescue -- an upgrade from a version that already had the overlay has nothing.
local function drillNotice()
  if not hadOldConfig then return end
  print("")
  print("------------------------------------------------------------")
  print("Your previous config.lua predates the drill overlay.")
  print("If you had hand-edited any drill settings in it -- drillPar,")
  print("tipsPerLoad, rodsPerLoad, tipsToStart, rodsToStart or")
  print("drillCraftSlots -- carry them across with:")
  print("")
  print("  migrate_drill /home/config.lua.bak")
  print("")
  print("It writes them to user_config.lua, which updates never touch.")
  print("From then on edit them in the broker: press E, then d for drills")
  print("or g for every other setting.")
  print("------------------------------------------------------------")
end

local function installRole(key)
  local role = ROLES[key]
  if not role then print("Unknown role: " .. tostring(key)); return end

  print("\nInstalling: " .. role.label)
  print("From: " .. RAW)
  print("")

  local allOk = true
  hadOldConfig = backupConfig()
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
  drillNotice()
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
    "config.lua", "settings.lua", "reference.lua",
    "broker-mk3.lua", "scheduler.lua", "loader.lua", "logger.lua",
    "list_components.lua", "detect_module.lua", "detect_sides.lua", "find_item.lua",
    "dust_telem.lua", "hw_telem.lua", "fluid_telem.lua", "job_node.lua",
    "migrate_drill.lua",
  }
  local allOk = true
  hadOldConfig = backupConfig()
  for _, f in ipairs(everything) do if not fetch(f) then allOk = false end end
  fetchConfigExample("job_node_config.example.lua", "job_node_config.lua")
  print(allOk and "\nInstall complete." or "\nSome files FAILED — check internet and re-run.")
  drillNotice()
elseif map[choice] then
  installRole(map[choice])
else
  print("No valid choice made. Re-run 'install' and pick 1-6.")
end
