-- =============================================================================
-- install-pump.lua — Space Pumping installer
--
-- Run this once on the pumping computer, and again whenever you want to update.
--
-- To get this script onto a fresh computer in the first place:
--   wget https://raw.githubusercontent.com/jdlovins/GTNH-Miner/main/space-pumping/install-pump.lua /home/install-pump.lua
--   install-pump
--
-- WHAT IT DOWNLOADS IS NOT DECIDED HERE. It fetches manifest.lua from the repo
-- first and installs whatever that lists.
--
-- That indirection exists because the obvious design is broken. With the list
-- hardcoded in this file, the installer on your disk only ever knows the files
-- that existed when you last wget'd it — so a file added to the project later is
-- invisible to it, `install-pump` reports success, and the program dies on a
-- missing file. That happened here with editor.lua. Now the list lives on the
-- server, and the manifest includes this installer, so it updates itself too.
--
-- Your config.lua is never overwritten: it holds your planet/slot layout and
-- your fluid choices, and re-fetching it would silently throw those away. Delete
-- it first if you really do want the shipped defaults back.
-- =============================================================================

local component = require("component")
local fs        = require("filesystem")

local RAW = "https://raw.githubusercontent.com/jdlovins/GTNH-Miner/main/space-pumping"
local MANIFEST_TMP = "/tmp/spacepump-manifest.lua"

-- Used only when the manifest cannot be fetched or parsed, so a network blip
-- still leaves you with a working install. It will drift; the manifest is the
-- source of truth.
local FALLBACK = {
  program = { "scheduler.lua", "logger.lua", "pumps.lua", "ui.lua", "editor.lua",
              "autoPump.lua", "diag.lua", "install-pump.lua" },
  keep    = { "config.lua" },
}

-- Download RAW/<name> to <dest>. Verifies by checking the file exists and is
-- non-empty afterwards rather than trusting os.execute's return, which is
-- unreliable in OpenOS.
local function fetch(name, dest, quiet)
  dest = dest or ("/home/" .. name)
  if not quiet then io.write("  " .. name .. " ... ") end
  os.execute("wget -fq " .. RAW .. "/" .. name .. " " .. dest)  -- -f overwrite, -q quiet
  local size = fs.size(dest)
  local ok = fs.exists(dest) and size and size > 0
  if not quiet then print(ok and ("ok (" .. size .. "b)") or "FAILED") end
  return ok
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

-- 1. What are we installing?
local list = FALLBACK
io.write("  reading manifest ... ")
if fetch("manifest.lua", MANIFEST_TMP, true) then
  local ok, m = pcall(dofile, MANIFEST_TMP)
  if ok and type(m) == "table" and type(m.program) == "table" then
    list = { program = m.program, keep = m.keep or {} }
    print("ok (" .. #list.program .. " files)")
  else
    print("unreadable, using built-in list")
  end
else
  print("unavailable, using built-in list")
end
print("")

-- 2. Install it.
local allOk = true
for _, f in ipairs(list.program) do
  if not fetch(f) then allOk = false end
end
for _, f in ipairs(list.keep or {}) do
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
  print("  3. Press E on the dashboard to choose what to stock.")
else
  print("Some files FAILED - check the Internet Card and re-run install-pump.")
end
