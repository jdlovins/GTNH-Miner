-- =============================================================================
-- install-pump.lua — Space Pumping installer
--
-- Run this once on the pumping computer. It downloads every file the program
-- needs into /home/.
--
-- To get this script onto a fresh computer in the first place:
--   wget https://raw.githubusercontent.com/jdlovins/GTNH-Miner/main/space-pumping/install-pump.lua /home/install-pump.lua
--   install-pump
--
-- Your config.lua is never overwritten: it holds your planet/slot layout, and
-- re-fetching it would silently throw that away. Delete it first if you really
-- do want the shipped defaults back.
-- =============================================================================

local component = require("component")
local fs        = require("filesystem")

local RAW = "https://raw.githubusercontent.com/jdlovins/GTNH-Miner/main/space-pumping"

-- Program files: always refreshed.
local FILES = {
  "scheduler.lua",
  "logger.lua",
  "pumps.lua",
  "ui.lua",
  "autoPump.lua",
}

-- Files that carry your settings: fetched only when absent.
local KEEP = { "config.lua" }

-- Download one file into /home/<name>. Verifies by checking the file exists and
-- is non-empty afterwards rather than trusting os.execute's return, which is
-- unreliable in OpenOS.
local function fetch(name)
  local target = "/home/" .. name
  io.write("  " .. name .. " ... ")
  os.execute("wget -fq " .. RAW .. "/" .. name .. " " .. target)  -- -f overwrite, -q quiet
  local size = fs.size(target)
  if fs.exists(target) and size and size > 0 then
    print("ok (" .. size .. "b)")
    return true
  end
  print("FAILED")
  return false
end

if not component.isAvailable("internet") then
  print("ERROR: no Internet Card found. wget needs one to download files.")
  print("Install an OpenComputers Internet Card and try again.")
  return
end

print("================================================")
print("  SPACE PUMPING INSTALLER")
print("================================================")
print("From: " .. RAW)
print("")

local allOk = true
for _, f in ipairs(FILES) do
  if not fetch(f) then allOk = false end
end
for _, f in ipairs(KEEP) do
  if fs.exists("/home/" .. f) then
    print("  " .. f .. " already exists - leaving your settings alone.")
  elseif not fetch(f) then
    allOk = false
  end
end

print("")
if allOk then
  print("Install complete.")
  print("")
  print("Next:")
  print("  1. Edit /home/config.lua - currentCellType, safetyMargin, and the")
  print("     {planet, slot} pair on every fluid in config.master.")
  print("  2. Run:  autoPump")
else
  print("Some files FAILED - check the Internet Card and re-run install-pump.")
end
