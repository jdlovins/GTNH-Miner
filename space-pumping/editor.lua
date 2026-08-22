-- =============================================================================
-- editor.lua — in-game fluid editor (press E on the dashboard)
--
-- Pick which fluids to keep stocked, and how much of each. That is the whole
-- feature. It is the pumping equivalent of the miner's condition editor, minus
-- the asteroid drill-down, because a pump's source is a fixed {planet, slot}
-- rather than something you choose.
--
-- SEMANTICS — the same split the miner uses, for the same reason:
--   config.master is the MAPPING: where a fluid comes from. Untouched here.
--     "Hydrogen is planet 8 slot 1" stays true whether or not you want Hydrogen.
--   config.wanted is the PREFERENCE: what to actually stock, and how much.
--     That is what this file edits.
--
-- WRITES ONE FILE, /home/user_config.lua, and nothing else writes it. config.lua
-- is shipped data that install-pump refreshes wholesale, so anything saved there
-- would be destroyed on the next update.
--
-- RUNS AS A UI MODE, NOT A MODAL DIALOG. The main loop keeps calling
-- sched.tick() and pumps.step() the whole time this is open, so an arm already
-- in flight still completes. That rules out term.read(): a blocking prompt could
-- stall an arm past armTimeout and fail it for no reason. All text entry is
-- incremental — every keystroke arrives as an ordinary event through the same
-- loop.
--
-- KEYS: up/down/pgup/pgdn/home/end  move
--       space  track / untrack        enter or t  set amount
--       /      filter                 a / n       track / untrack all shown
--       s      save                   esc         close
-- =============================================================================

local editor = {}

local config, pumps, ui, log
local W, H

local USER_CONFIG_PATH = "/home/user_config.lua"
local QUOTE            = string.char(34)

-- Cycled by `t` when you would rather not type a number.
local AMOUNT_LADDER = {
  1000000, 10000000, 100000000, 1000000000, 5000000000, 10000000000, 34000000000,
}

local ed = {
  open      = false,
  rows      = {},
  sel       = 1,
  scroll    = 0,
  filter    = nil,
  filtering = false,
  input     = nil,      -- { label, buffer, onCommit } while typing
  enabled   = {},       -- working copy: label -> true
  amount    = {},       -- working copy: label -> litres, or nil for "global"
  dirty     = false,    -- unsaved changes
  repaint   = true,     -- screen needs a repaint
  msg       = "",
  msgColor  = 0x888888,
  confirmClose = false,
}

editor.ed = ed

local function say(m, c) ed.msg = m; ed.msgColor = c or 0x888888; ed.repaint = true end
local function touch() ed.dirty = true; ed.confirmClose = false end

-- Rows 5 .. H-3 hold the list; H-2 is the button bar, H-1 the message, H the hints.
local function firstRow() return 5 end
local function listRows() return math.max(1, H - 7) end

-- ---------------------------------------------------------------------------
-- MODEL
-- ---------------------------------------------------------------------------

local function load()
  ed.enabled, ed.amount = {}, {}
  local explicit = pumps.hasWantedList()
  for label in pairs(config.master) do
    if not explicit then
      -- No list yet means everything is being stocked at the global target, so
      -- that is what the editor must show — otherwise opening it would look
      -- like nothing is tracked and saving would turn the array off.
      ed.enabled[label] = true
    end
  end
  for label, v in pairs(config.wanted or {}) do
    if config.master[label] then
      ed.enabled[label] = true
      if type(v) == "number" and v > 0 then ed.amount[label] = v end
    end
  end
  ed.dirty = false
  ed.confirmClose = false
end

local function matchesFilter(s)
  if not ed.filter or ed.filter == "" then return true end
  return s:lower():find(ed.filter, 1, true) ~= nil
end

local function build()
  local labels = {}
  for label in pairs(config.master) do
    if matchesFilter(label) then labels[#labels + 1] = label end
  end
  table.sort(labels)

  local rows = {}
  for _, label in ipairs(labels) do rows[#rows + 1] = { label = label } end
  ed.rows = rows

  if ed.sel > #rows then ed.sel = #rows end
  if ed.sel < 1 then ed.sel = 1 end
  ed.repaint = true
end

local function selected()
  return ed.rows[ed.sel]
end

local function follow()
  local rows = listRows()
  if ed.sel < ed.scroll + 1 then ed.scroll = ed.sel - 1 end
  if ed.sel > ed.scroll + rows then ed.scroll = ed.sel - rows end
  local maxScroll = math.max(0, #ed.rows - rows)
  if ed.scroll > maxScroll then ed.scroll = maxScroll end
  if ed.scroll < 0 then ed.scroll = 0 end
end

local function move(delta)
  if #ed.rows == 0 then return end
  ed.sel = math.max(1, math.min(#ed.rows, ed.sel + delta))
  follow()
  ed.repaint = true
end

local function trackedCount()
  local n = 0
  for _ in pairs(ed.enabled) do n = n + 1 end
  return n
end

-- ---------------------------------------------------------------------------
-- MUTATIONS
-- ---------------------------------------------------------------------------

local function toggle(label)
  touch()
  if ed.enabled[label] then
    ed.enabled[label] = nil
    say("stopped stocking " .. label)
  else
    ed.enabled[label] = true
    local amt = ed.amount[label]
    say("stocking " .. label .. " to " ..
        (amt and ui.formatFluid(amt) or "the global target"), 0x00FF00)
  end
  ed.repaint = true
end

local function cycleAmount(label)
  touch()
  local cur = ed.amount[label] or 0
  local nxt = nil
  for _, v in ipairs(AMOUNT_LADDER) do
    if v > cur then nxt = v break end
  end
  -- Past the top of the ladder, wrap to "follow the global target" rather than
  -- sticking at the largest value — that is a real setting, not a dead end.
  ed.amount[label]  = nxt
  ed.enabled[label] = true
  say(label .. " -> " .. (nxt and ui.formatFluid(nxt) or "global target"), 0x00FF00)
  ed.repaint = true
end

local function prompt(label, onCommit, initial)
  ed.input = { label = label, buffer = initial or "", onCommit = onCommit }
  ed.repaint = true
end

-- "5g" / "500m" / "250000" / "" (empty = follow the global target).
local function parseQty(s)
  if not s then return nil, "no input" end
  s = s:lower():gsub("%s", "")
  if s == "" then return nil, nil end                     -- deliberate clear
  local num, suffix = s:match("^(%d+%.?%d*)([kmgbt]?)$")
  if not num then return nil, "not a number" end
  num = tonumber(num)
  local mult = ({ k = 1e3, m = 1e6, g = 1e9, b = 1e9, t = 1e12 })[suffix] or 1
  local v = math.floor(num * mult)
  if v <= 0 then return nil, "must be greater than zero" end
  return v, nil
end

local function promptAmount(label)
  prompt("amount of " .. label .. " to maintain (5g, 500m, 250000; blank = global):",
    function(text)
      local v, err = parseQty(text)
      if err then say("bad amount: " .. err .. " -- unchanged", 0xFF4444); return end
      touch()
      ed.amount[label]  = v
      ed.enabled[label] = true
      say(label .. " -> " .. (v and ui.formatFluid(v) or "global target"), 0x00FF00)
      build()
    end,
    ed.amount[label] and tostring(ed.amount[label]) or "")
end

-- Bulk actions apply to what is currently VISIBLE, so a filter scopes them.
-- Applying to all 40 fluids when you have filtered down to three would be a
-- nasty surprise.
local function setAllShown(on)
  touch()
  local n = 0
  for _, row in ipairs(ed.rows) do
    if on then ed.enabled[row.label] = true else ed.enabled[row.label] = nil end
    n = n + 1
  end
  local scope = (ed.filter and ed.filter ~= "") and (" matching '" .. ed.filter .. "'") or ""
  say((on and "stocking " or "stopped stocking ") .. n .. " fluid(s)" .. scope, 0x00FF00)
  ed.repaint = true
end

-- ---------------------------------------------------------------------------
-- SAVE
--
-- Writes /home/user_config.lua and applies the result live. Rebuilding in memory
-- beats re-reading config.lua, which pumps.lua already holds references into.
-- ---------------------------------------------------------------------------
local function save()
  local labels = {}
  for label in pairs(ed.enabled) do labels[#labels + 1] = label end
  table.sort(labels)

  local out = {}
  out[#out + 1] = "-- user_config.lua"
  out[#out + 1] = "--"
  out[#out + 1] = "-- Written by the in-game fluid editor (press E). Safe to hand-edit."
  out[#out + 1] = "-- Nothing else writes this file, and install-pump never touches it."
  out[#out + 1] = "--"
  out[#out + 1] = "--   wanted   which fluids to keep stocked, and how much of each."
  out[#out + 1] = "--            A number is that fluid's own ceiling in litres;"
  out[#out + 1] = "--            `true` means follow the global cell-derived target."
  out[#out + 1] = "--"
  out[#out + 1] = "-- An empty `wanted` here still means \"stock nothing\" -- it is an"
  out[#out + 1] = "-- explicit choice, unlike the empty default in config.lua."
  out[#out + 1] = ""
  out[#out + 1] = "return {"
  out[#out + 1] = "  wanted = {"
  for _, label in ipairs(labels) do
    local amt = ed.amount[label]
    out[#out + 1] = string.format("    [%s%s%s] = %s,",
      QUOTE, label, QUOTE, amt and string.format("%d", amt) or "true")
  end
  out[#out + 1] = "  },"
  out[#out + 1] = "}"

  local w, err = io.open(USER_CONFIG_PATH, "w")
  if not w then
    say("cannot write " .. USER_CONFIG_PATH .. ": " .. tostring(err), 0xFF4444)
    return
  end
  w:write(table.concat(out, "\n") .. "\n")
  w:close()

  -- Apply live.
  local fresh = {}
  for _, label in ipairs(labels) do fresh[label] = ed.amount[label] or true end
  config.wanted = fresh
  -- Saving is what makes the list explicit: from here on an empty list means
  -- "stock nothing", not "stock everything".
  config.wantedExplicit = true

  ed.dirty = false
  ed.confirmClose = false
  if log then log:info("editor saved " .. #labels .. " fluid(s) to " .. USER_CONFIG_PATH) end
  say(string.format("saved %d fluid(s) -> %s, applied live", #labels, USER_CONFIG_PATH), 0x00FF00)
end

-- ---------------------------------------------------------------------------
-- BUTTON BAR
-- ---------------------------------------------------------------------------
local buttons = {}
local function layoutButtons()
  local defs = { { "SAVE", "save" }, { "ALL", "all" }, { "NONE", "none" },
                 { "FIND", "find" }, { "CLOSE", "close" } }
  buttons = {}
  local x = 2
  for _, d in ipairs(defs) do
    local label = " " .. d[1] .. " "
    buttons[#buttons + 1] = { x1 = x, x2 = x + #label - 1, label = label, action = d[2] }
    x = x + #label + 2
  end
end

-- ---------------------------------------------------------------------------
-- DRAW
-- ---------------------------------------------------------------------------
local X_MARK, X_NAME = 2, 6
local X_AMT, X_HAVE, X_PCT, X_PRI = 30, 46, 62, 72

local function draw()
  local gpu = ui.gpu()
  if not gpu then return end
  local paint, fresh = ui.paint, ui.fresh
  local amounts = pumps.state.amounts or {}
  local globalTarget = pumps.getTarget()

  -- Title
  local title = string.format("FLUID EDITOR    %d of %d stocked%s",
    trackedCount(), (function() local n = 0; for _ in pairs(config.master) do n = n + 1 end; return n end)(),
    ed.dirty and "    * unsaved" or "")
  paint(1, "t|" .. title, { { 2, title, ed.dirty and 0xFFAA00 or 0x00AAFF } })

  local sub = string.format("global target %s%s", ui.formatFluid(globalTarget),
    (ed.filter and ed.filter ~= "") and ("    filter: " .. ed.filter .. (ed.filtering and "_" or "")) or "")
  paint(2, "s|" .. sub, { { 2, sub, 0x777777 } })

  local hdr = string.format("%-22s %-15s %-15s %-9s %s", "FLUID", "MAINTAIN", "HAVE", "FILL", "PRI")
  paint(3, "h|" .. hdr, { { X_NAME, hdr, 0x555555 } })
  paint(4, "rule", { { 1, string.rep("-", W), 0x333333 } })

  -- List
  local rows, first = listRows(), firstRow()
  for i = 0, rows - 1 do
    local y   = first + i
    local idx = ed.scroll + i + 1
    local row = ed.rows[idx]
    if not row then
      paint(y, "blank", {})
    else
      local label = row.label
      local on    = ed.enabled[label] and true or false
      local amt   = ed.amount[label]
      local cap   = amt or globalTarget
      local have  = amounts[label] or 0
      local perc  = (cap > 0) and (have / cap) * 100 or 0
      local pri   = (config.master[label] or {}).priority or 0
      local isSel = (idx == ed.sel)

      local key = table.concat({ label, tostring(on), tostring(amt or "g"),
                                 string.format("%.1f", have), string.format("%.2f", perc),
                                 pri, tostring(isSel) }, "~")
      if not fresh(y, key) then
        local nameColor = on and 0xFFFFFF or 0x666666
        local amtText   = amt and ui.formatFluid(amt) or "global"
        local pctColor  = 0x555555
        if on then
          if perc < 50 then pctColor = 0xFF6666
          elseif perc < 95 then pctColor = 0xFFCC33
          else pctColor = 0x00FF00 end
        end
        paint(y, key, {
          { X_MARK, on and "[x]" or "[ ]", on and 0x00FF00 or 0x555555 },
          { X_NAME, label:sub(1, 22),      nameColor },
          { X_AMT,  amtText,               amt and 0xAAAAAA or 0x666666 },
          { X_HAVE, ui.formatFluid(have),  on and 0xAAAAAA or 0x555555 },
          { X_PCT,  on and string.format("%.1f%%", perc) or "--", pctColor },
          { X_PRI,  "p" .. pri,            0x666666 },
        }, isSel and 0x1A3A5A or nil)
      end
    end
  end

  -- Buttons
  local bkey = "b|" .. tostring(ed.dirty)
  if not fresh(H - 2, bkey) then
    local cells = {}
    for _, b in ipairs(buttons) do
      cells[#cells + 1] = { b.x1, b.label,
        (b.action == "save" and ed.dirty) and 0xFFAA00 or 0x00AAFF }
    end
    paint(H - 2, bkey, cells)
  end

  -- Message / input line
  local line, color
  if ed.input then
    line  = ed.input.label .. "  " .. ed.input.buffer .. "_"
    color = 0xFFCC33
  else
    line, color = ed.msg, ed.msgColor
  end
  paint(H - 1, "m|" .. tostring(line) .. tostring(color), { { 2, tostring(line):sub(1, W - 3), color } })

  local hints = "space track  |  enter/t amount  |  a all  n none  |  / find  |  s save  |  esc close"
  paint(H, "k|" .. hints, { { 2, hints, 0x555555 } })
end

-- ---------------------------------------------------------------------------
-- ACTIONS AND INPUT
-- ---------------------------------------------------------------------------
local function close()
  if ed.dirty and not ed.confirmClose then
    ed.confirmClose = true
    say("unsaved changes -- esc again to discard, or s to save", 0xFFAA00)
    return
  end
  ed.open = false
  ui.invalidate()
end

local function action(a)
  if     a == "save"  then save()
  elseif a == "all"   then setAllShown(true)
  elseif a == "none"  then setAllShown(false)
  elseif a == "find"  then ed.filtering = true; ed.filter = ed.filter or ""; say("type to filter, enter to keep, esc to clear")
  elseif a == "close" then close()
  end
end

-- Returns true if the event was consumed.
function editor.handle(ev)
  local kind = ev[1]

  if kind == "touch" then
    local x, y = ev[3], ev[4]
    if y == H - 2 then
      for _, b in ipairs(buttons) do
        if x >= b.x1 and x <= b.x2 then action(b.action); return true end
      end
      return true
    end
    if y >= firstRow() and y < firstRow() + listRows() then
      local idx = ed.scroll + (y - firstRow()) + 1
      if ed.rows[idx] then
        ed.sel = idx
        -- Clicking the amount column edits the amount; anywhere else toggles.
        if x >= X_AMT and x < X_HAVE then promptAmount(ed.rows[idx].label)
        else toggle(ed.rows[idx].label) end
      end
    end
    return true

  elseif kind == "scroll" then
    ed.scroll = ed.scroll - (ev[5] or 0) * 3
    local maxScroll = math.max(0, #ed.rows - listRows())
    if ed.scroll > maxScroll then ed.scroll = maxScroll end
    if ed.scroll < 0 then ed.scroll = 0 end
    ed.repaint = true
    return true

  elseif kind == "key_down" then
    local ch, code = ev[3], ev[4]

    -- Text entry swallows printable keys. Never blocks.
    if ed.input then
      if code == 28 then                     -- enter
        local cb, buf = ed.input.onCommit, ed.input.buffer
        ed.input = nil
        cb(buf)
      elseif code == 1 then                  -- esc
        ed.input = nil; say("cancelled")
      elseif code == 14 then                 -- backspace
        ed.input.buffer = ed.input.buffer:sub(1, -2)
      elseif ch and ch >= 32 and ch < 127 then
        ed.input.buffer = ed.input.buffer .. string.char(ch)
      end
      ed.repaint = true
      return true
    end

    if ed.filtering then
      if code == 28 then
        ed.filtering = false; say("filter: " .. (ed.filter or ""))
      elseif code == 1 then
        ed.filtering = false; ed.filter = nil; build(); say("filter cleared")
      elseif code == 14 then
        ed.filter = (ed.filter or ""):sub(1, -2); build()
      elseif ch and ch >= 32 and ch < 127 then
        ed.filter = (ed.filter or "") .. string.char(ch):lower(); build()
      end
      ed.repaint = true
      return true
    end

    if     code == 200 then move(-1)                       -- up
    elseif code == 208 then move(1)                        -- down
    elseif code == 201 then move(-listRows())              -- pgup
    elseif code == 209 then move(listRows())               -- pgdn
    elseif code == 199 then ed.sel = 1; follow(); ed.repaint = true          -- home
    elseif code == 207 then ed.sel = #ed.rows; follow(); ed.repaint = true   -- end
    elseif code == 1   then close()                        -- esc
    elseif code == 28  then                                -- enter
      local row = selected(); if row then promptAmount(row.label) end
    elseif ch == 32 then
      local row = selected(); if row then toggle(row.label) end
    elseif ch == 116 or ch == 84 then                      -- t / T
      local row = selected(); if row then cycleAmount(row.label) end
    elseif ch == 97  or ch == 65 then action("all")        -- a / A
    elseif ch == 110 or ch == 78 then action("none")       -- n / N
    elseif ch == 47             then action("find")        -- /
    elseif ch == 115 or ch == 83 then action("save")       -- s / S
    end
    return true
  end

  return false
end

function editor.open()
  W, H = ui.size()
  layoutButtons()
  load()
  build()
  ed.sel, ed.scroll = 1, 0
  ed.open = true
  ui.invalidate()
  say("space to track a fluid, enter to set how much to keep")
end

function editor.isOpen() return ed.open end

-- Called by the main loop on its UI cadence. Repaints when something changed,
-- plus a slow tick so live HAVE figures refresh while you are looking at them.
function editor.draw(force)
  if not ed.open then return end
  if ed.repaint or force then
    draw()
    ed.repaint = false
  end
end

function editor.init(deps)
  config = deps.config
  pumps  = deps.pumps
  ui     = deps.ui
  log    = deps.logger
  W, H   = ui.size()
  layoutButtons()
  return editor
end

return editor
