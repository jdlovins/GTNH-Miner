-- =============================================================================
-- edit_conditions.lua
-- Clickable editor for config.conditions -- what the broker mines for.
--
-- WHY A TOOL RATHER THAN EDITING config.lua BY HAND:
--   A condition only does anything if config.dustTargets has an entry for that
--   exact itemName. The broker looks up dustTargets[cond.itemName] to find which
--   asteroid to mine; with no entry the item sits on the dashboard forever and
--   never dispatches. Hand-editing gives you no warning -- it looks like it
--   worked. This lists the mineable set, so what you enable can actually run,
--   and flags anything already in your conditions that cannot.
--
--   OpenComputers cannot enumerate every item in the game; there is no registry
--   API. It only sees what is in an ME network or an adjacent inventory. So the
--   menu is config.dustTargets (what this system can mine), with live ME stock
--   shown alongside when a network is reachable.
--
-- USAGE:  edit_conditions
--   Click a row to toggle it. Click its target number to change it.
--   Buttons along the bottom; scroll wheel and arrow/page keys also work.
--   Keys: space toggle, t target, f find, a all, n none, s save, q quit.
--
-- Writes config.conditions back into /home/config.lua, leaving the rest of the
-- file byte-for-byte alone. Restart the broker afterwards (it reads config.lua
-- once at startup); the dust node follows on the next watchlist broadcast.
-- =============================================================================

local component = require("component")
local event     = require("event")
local term      = require("term")

local CONFIG_PATH = "/home/config.lua"
local DEFAULT_QTY = 5000000

local gpu = component.gpu
local W, H = gpu.maxResolution()
gpu.setResolution(W, H)

-- Colours
local C_BG      = 0x000000
local C_TITLE   = 0x00FF00
local C_HEAD    = 0x888888
local C_ON      = 0x00FFFF
local C_OFF     = 0x555555
local C_WARN    = 0xFFAA00
local C_BAD     = 0xFF4444
local C_BTN     = 0x333333
local C_BTNTEXT = 0xFFFFFF
local C_OK      = 0x00FF00

-- =============================================================================
-- LOAD
-- =============================================================================

local config = assert(loadfile(CONFIG_PATH))()
assert(type(config.dustTargets) == "table", "config.dustTargets missing from config.lua")
assert(type(config.conditions)  == "table", "config.conditions missing from config.lua")

local enabled, threshold = {}, {}
for _, cond in ipairs(config.conditions) do
  enabled[cond.itemName]   = true
  threshold[cond.itemName] = cond.amountToMaintain
end

-- Live ME stock, if a network is reachable. Optional -- the editor works without.
local stock, haveStock = {}, false
do
  local me
  for addr in component.list("me_interface")  do me = component.proxy(addr) break end
  if not me then
    for addr in component.list("me_controller") do me = component.proxy(addr) break end
  end
  if me and me.getItemsInNetwork then
    local ok, list = pcall(me.getItemsInNetwork)
    if ok and list then
      for _, it in ipairs(list) do
        if it and it.label then stock[it.label] = (stock[it.label] or 0) + (it.size or 0) end
      end
      haveStock = next(stock) ~= nil
    end
  end
end

-- Build the row list: everything mineable, plus any condition that is not
-- mineable so it is visible rather than silently dead.
local items = {}
for name, entry in pairs(config.dustTargets) do
  items[#items + 1] = {
    name     = name,
    asteroid = entry.asteroid,
    priority = entry.priority or 99,
    mineable = true,
    known    = config.asteroids[entry.asteroid] ~= nil,
  }
end
for _, cond in ipairs(config.conditions) do
  if not config.dustTargets[cond.itemName] then
    items[#items + 1] = {
      name = cond.itemName, asteroid = nil, priority = 999,
      mineable = false, known = false,
    }
  end
end

local function sortItems()
  table.sort(items, function(a, b)
    if a.mineable ~= b.mineable then return a.mineable end
    if a.priority ~= b.priority then return a.priority < b.priority end
    return a.name < b.name
  end)
end
sortItems()

-- =============================================================================
-- HELPERS
-- =============================================================================

local function fmtQty(n)
  if n >= 1000000 and n % 1000000 == 0 then return string.format("%dm", n / 1000000) end
  if n >= 1000    and n % 1000    == 0 then return string.format("%dk", n / 1000)    end
  return tostring(n)
end

local function parseQty(s)
  if not s then return nil end
  local num, suffix = tostring(s):lower():gsub("%s", ""):match("^(%d+%.?%d*)([kmb]?)$")
  if not num then return nil end
  num = tonumber(num)
  if suffix == "k" then return math.floor(num * 1000) end
  if suffix == "m" then return math.floor(num * 1000000) end
  if suffix == "b" then return math.floor(num * 1000000000) end
  return math.floor(num)
end

local function countEnabled()
  local n = 0
  for _ in pairs(enabled) do n = n + 1 end
  return n
end

-- =============================================================================
-- LAYOUT
-- =============================================================================

local TOP_ROWS = 4          -- title, status, blank, column header
local BOT_ROWS = 3          -- blank, buttons, message
local firstRow = TOP_ROWS + 1
local lastRow  = H - BOT_ROWS
local perPage  = lastRow - firstRow + 1

local scroll  = 0           -- index of first visible item
local sel     = 1           -- selected row, as an index into `view`
local filter  = nil
local message = ""
local msgColor = C_HEAD

-- Column x positions
local X_MARK = 2
local X_NAME = 6
local X_TGT  = 40
local X_HAVE = 50
local X_AST  = 64

local view = {}             -- filtered view -> items index

local function rebuildView()
  view = {}
  for i, it in ipairs(items) do
    if not filter
       or it.name:lower():find(filter, 1, true)
       or (it.asteroid or ""):lower():find(filter, 1, true) then
      view[#view + 1] = i
    end
  end
  if scroll > math.max(0, #view - perPage) then scroll = math.max(0, #view - perPage) end
  if scroll < 0 then scroll = 0 end
  if sel > #view then sel = #view end
  if sel < 1 then sel = 1 end
end

-- Keep the selected row on screen after a move.
local function followSel()
  if sel < scroll + 1 then scroll = sel - 1 end
  if sel > scroll + perPage then scroll = sel - perPage end
  if scroll < 0 then scroll = 0 end
end

-- Buttons: { x1, x2, label, action }
local buttons = {}

local function layoutButtons()
  buttons = {}
  local defs = {
    { "FIND",  "find"  }, { "ALL", "all" }, { "NONE", "none" },
    { "ADD",   "add"   }, { "SAVE", "save" }, { "QUIT", "quit" },
  }
  local x = 2
  for _, d in ipairs(defs) do
    local label = " " .. d[1] .. " "
    buttons[#buttons + 1] = { x1 = x, x2 = x + #label - 1, label = label, action = d[2] }
    x = x + #label + 2
  end
end
layoutButtons()

-- =============================================================================
-- DRAW
-- =============================================================================

local function clearRow(y)
  gpu.fill(1, y, W, 1, " ")
end

local function drawHeader()
  clearRow(1)
  gpu.setForeground(C_TITLE)
  term.setCursor(2, 1)
  io.write("MEDINA CONDITION EDITOR")

  clearRow(2)
  gpu.setForeground(C_HEAD)
  term.setCursor(2, 2)
  local src = haveStock and "ME stock: live" or "ME stock: unavailable"
  io.write(string.format("%d mineable  |  %d enabled  |  %s%s",
    #items, countEnabled(), src, filter and ("  |  filter: " .. filter) or ""))

  clearRow(4)
  gpu.setForeground(C_HEAD)
  term.setCursor(X_NAME, 4)
  io.write("ITEM")
  term.setCursor(X_TGT, 4);  io.write("TARGET")
  if haveStock then term.setCursor(X_HAVE, 4); io.write("HAVE") end
  term.setCursor(X_AST, 4);  io.write("ASTEROID")
end

local function drawRows()
  for r = 0, perPage - 1 do
    local y   = firstRow + r
    local idx = view[scroll + r + 1]
    clearRow(y)
    if idx then
      local it = items[idx]
      local on = enabled[it.name]

      -- Highlight the keyboard selection so space/t have an obvious target.
      if scroll + r + 1 == sel then
        gpu.setBackground(0x1A1A1A)
        gpu.fill(1, y, W, 1, " ")
      end

      gpu.setForeground(on and C_ON or C_OFF)
      term.setCursor(X_MARK, y)
      io.write(on and "[x]" or "[ ]")

      term.setCursor(X_NAME, y)
      io.write(it.name:sub(1, X_TGT - X_NAME - 1))

      term.setCursor(X_TGT, y)
      io.write(on and fmtQty(threshold[it.name] or DEFAULT_QTY) or "-")

      if haveStock then
        local have = stock[it.name] or 0
        local tgt  = threshold[it.name] or DEFAULT_QTY
        gpu.setForeground(have >= tgt and C_OK or (have > 0 and C_WARN or C_OFF))
        term.setCursor(X_HAVE, y)
        io.write(fmtQty(have))
      end

      if not it.mineable then
        gpu.setForeground(C_BAD)
        term.setCursor(X_AST, y)
        io.write("NOT MINEABLE")
      elseif not it.known then
        gpu.setForeground(C_WARN)
        term.setCursor(X_AST, y)
        io.write("? " .. tostring(it.asteroid))
      else
        gpu.setForeground(on and C_HEAD or C_OFF)
        term.setCursor(X_AST, y)
        io.write(tostring(it.asteroid):sub(1, W - X_AST))
      end

      gpu.setBackground(C_BG)
    end
  end
end

local function drawFooter()
  local by = H - 1
  clearRow(H - 2)
  clearRow(by)
  for _, b in ipairs(buttons) do
    gpu.setBackground(C_BTN)
    gpu.setForeground(C_BTNTEXT)
    term.setCursor(b.x1, by)
    io.write(b.label)
  end
  gpu.setBackground(C_BG)

  gpu.setForeground(C_HEAD)
  local pos = string.format("%d-%d of %d",
    math.min(scroll + 1, #view), math.min(scroll + perPage, #view), #view)
  term.setCursor(W - #pos - 1, by)
  io.write(pos)

  clearRow(H)
  gpu.setForeground(msgColor)
  term.setCursor(2, H)
  io.write(message:sub(1, W - 2))
end

local function draw()
  drawHeader()
  drawRows()
  drawFooter()
end

local function say(m, color)
  message  = m
  msgColor = color or C_HEAD
end

-- =============================================================================
-- PROMPT (for find / target / add)
-- =============================================================================

local function prompt(label)
  clearRow(H)
  gpu.setForeground(C_TITLE)
  term.setCursor(2, H)
  io.write(label .. " ")
  gpu.setForeground(C_BTNTEXT)
  local s = term.read()
  if s then s = s:gsub("[\r\n]", "") end
  return (s and s ~= "") and s or nil
end

-- =============================================================================
-- ACTIONS
-- =============================================================================

local function toggle(idx)
  local it = items[idx]
  if enabled[it.name] then
    enabled[it.name] = nil
    say("disabled " .. it.name)
  else
    enabled[it.name]   = true
    threshold[it.name] = threshold[it.name] or DEFAULT_QTY
    if not it.mineable then
      say("enabled " .. it.name .. " -- but it has no dustTargets entry, so the broker cannot dispatch for it", C_BAD)
    else
      say("enabled " .. it.name .. " at " .. fmtQty(threshold[it.name]))
    end
  end
end

local function editTarget(idx)
  local it = items[idx]
  local s  = prompt("target for " .. it.name .. " (e.g. 5m, 500k, 250000):")
  if not s then say("cancelled") return end
  local q = parseQty(s)
  if not q or q <= 0 then say("bad quantity: " .. s, C_BAD) return end
  threshold[it.name] = q
  enabled[it.name]   = true
  say(it.name .. " -> " .. fmtQty(q), C_OK)
end

local function addItem()
  local name = prompt("item label to add (exact ME label):")
  if not name then say("cancelled") return end
  for i, it in ipairs(items) do
    if it.name == name then
      enabled[name]   = true
      threshold[name] = threshold[name] or DEFAULT_QTY
      say("already listed at row " .. i .. " -- enabled it", C_OK)
      return
    end
  end
  -- Not in dustTargets. Allow it, but be explicit that it cannot dispatch.
  items[#items + 1] = { name = name, asteroid = nil, priority = 999,
                        mineable = false, known = false }
  enabled[name]   = true
  threshold[name] = DEFAULT_QTY
  sortItems()
  rebuildView()
  say("added " .. name .. " -- NOT in dustTargets, so it will display but never mine", C_BAD)
end

-- Rewrite only the config.conditions block; everything else is left untouched.
local function save()
  local f = io.open(CONFIG_PATH, "r")
  if not f then say("cannot read " .. CONFIG_PATH, C_BAD) return false end
  local src = f:read("*a"); f:close()

  local head = src:find("config%.conditions%s*=%s*{")
  if not head then say("could not find config.conditions in the file", C_BAD) return false end
  local tail = src:find("\n}", head)
  if not tail then say("could not find the end of config.conditions", C_BAD) return false end

  local out = {}
  out[#out + 1] = "config.conditions = {"
  out[#out + 1] = "  -- Managed by edit_conditions.lua."
  out[#out + 1] = "  -- Entries are the config.dustTargets set, so anything enabled here has an"
  out[#out + 1] = "  -- asteroid to mine. Commented lines are simply disabled, not deleted."

  local lastPriority, wroteInertHeader = nil, false
  for _, it in ipairs(items) do
    if it.mineable then
      if it.priority ~= lastPriority then
        out[#out + 1] = string.format("  -- ---- priority %d ----", it.priority)
        lastPriority = it.priority
      end
    elseif not wroteInertHeader then
      out[#out + 1] = "  -- ---- NOT in dustTargets: these display but can never dispatch ----"
      wroteInertHeader = true
    end
    local body = string.format('{ itemName = %-32s amountToMaintain = qty("%s") },',
      '"' .. it.name .. '",', fmtQty(threshold[it.name] or DEFAULT_QTY))
    out[#out + 1] = (enabled[it.name] and "  " or "  --  ") .. body
  end
  out[#out + 1] = "}"

  local new = src:sub(1, head - 1) .. table.concat(out, "\n") .. src:sub(tail + 2)
  local w = io.open(CONFIG_PATH, "w")
  if not w then say("cannot write " .. CONFIG_PATH, C_BAD) return false end
  w:write(new); w:close()
  return true
end

-- =============================================================================
-- HIT TESTING
-- =============================================================================

local function rowAt(y)
  if y < firstRow or y > lastRow then return nil end
  return view[scroll + (y - firstRow) + 1]
end

local function buttonAt(x, y)
  if y ~= H - 1 then return nil end
  for _, b in ipairs(buttons) do
    if x >= b.x1 and x <= b.x2 then return b.action end
  end
  return nil
end

-- =============================================================================
-- MAIN
-- =============================================================================

local function doAction(a)
  if a == "quit" then
    return false
  elseif a == "save" then
    if save() then
      gpu.setBackground(C_BG)
      term.clear()
      print("Written to " .. CONFIG_PATH)
      print(countEnabled() .. " conditions enabled.")
      print("")
      print("Restart the broker to load it. The dust node picks the new")
      print("watchlist up automatically on the next broadcast.")
      return false
    end
  elseif a == "all" then
    for _, it in ipairs(items) do
      if it.mineable then
        enabled[it.name]   = true
        threshold[it.name] = threshold[it.name] or DEFAULT_QTY
      end
    end
    say("enabled everything mineable", C_OK)
  elseif a == "none" then
    enabled = {}
    say("disabled everything")
  elseif a == "find" then
    local s = prompt("filter (blank to clear):")
    filter = s and s:lower() or nil
    scroll = 0
    rebuildView()
    say(filter and ("filtering on " .. filter) or "filter cleared")
  elseif a == "add" then
    addItem()
  end
  return true
end

gpu.setBackground(C_BG)
term.clear()
rebuildView()

if #view == 0 then
  print("config.dustTargets is empty -- nothing to edit.")
  return
end

say("click a row to toggle, click its target to change it")
draw()

while true do
  local ev = { event.pull() }
  local name = ev[1]
  local run = true

  if name == "touch" then
    local x, y = ev[3], ev[4]
    local action = buttonAt(x, y)
    if action then
      run = doAction(action)
    else
      local idx = rowAt(y)
      if idx then
        sel = scroll + (y - firstRow) + 1
        if x >= X_TGT and x < X_HAVE then editTarget(idx) else toggle(idx) end
      end
    end

  elseif name == "scroll" then
    local dir = ev[5]
    scroll = scroll - dir * 3
    if scroll < 0 then scroll = 0 end
    if scroll > math.max(0, #view - perPage) then scroll = math.max(0, #view - perPage) end

  elseif name == "key_down" then
    local ch, code = ev[3], ev[4]
    if     code == 200 then sel = math.max(1, sel - 1); followSel()                -- up
    elseif code == 208 then sel = math.min(#view, sel + 1); followSel()            -- down
    elseif code == 201 then sel = math.max(1, sel - perPage); followSel()          -- pgup
    elseif code == 209 then sel = math.min(#view, sel + perPage); followSel()      -- pgdn
    elseif code == 199 then sel = 1; followSel()                                   -- home
    elseif code == 207 then sel = #view; followSel()                               -- end
    elseif ch == 32 then                                                            -- space
      local idx = view[sel]
      if idx then toggle(idx) end
    elseif ch == 116 then                                                           -- t
      local idx = view[sel]
      if idx then editTarget(idx) end
    elseif ch == 102 then run = doAction("find")
    elseif ch == 97  then run = doAction("all")
    elseif ch == 110 then run = doAction("none")
    elseif ch == 115 then run = doAction("save")
    elseif ch == 113 then run = doAction("quit")
    end
  end

  if not run then break end
  draw()
end

gpu.setBackground(C_BG)
gpu.setForeground(0xFFFFFF)
