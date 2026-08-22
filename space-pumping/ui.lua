-- =============================================================================
-- ui.lua — dashboard rendering for the space pumping array
--
-- WHY THIS IS NOT JUST gpu.set CALLS IN A LOOP:
--
--  1. NO term.clear() PER FRAME. The old drawUI() wiped the whole screen every
--     pass. On a 3x2 T3 array that is the single most expensive thing the
--     program does, and it is what made the display flicker. The static frame is
--     drawn once; every row below clears only itself.
--
--  2. ROW SIGNATURE CACHE. Each row is identified by a `key` describing its
--     content. If the key has not changed since the last frame the row is
--     skipped entirely — not repainted, not even rebuilt. On a settled array
--     almost every row is a cache hit and a frame costs a handful of GPU calls.
--     Lifted from the miner's editor (space-miner/broker-mk3.lua, edPaint/edFresh).
--
--  3. EVERY COORDINATE IS FLOORED. In OpenComputers' Lua 5.3, `w/2` is a float,
--     and the old code passed `w/2 - 25` straight into gpu.set. On an
--     odd-width screen that is a non-integer coordinate.
-- =============================================================================

local component = require("component")
local term      = require("term")

local ui = {}

local config, pumps
local gpu
local W, H = 80, 25

-- Row signature cache: y -> key. Cleared by ui.invalidate().
local cache = {}
-- Current GPU colours, so we skip redundant setForeground/setBackground calls.
local curFG, curBG

-- Layout, computed in ui.init once the resolution is known.
local L = {}

-- ---------------------------------------------------------------------------
-- FORMATTING
-- ---------------------------------------------------------------------------

-- 1234567 -> "1.23 ML". Exported: autoPump uses it for the boot banner.
function ui.formatFluid(amount)
  local suffixes = { " ", "K", "M", "G", "T", "P" }
  local i, v = 1, math.abs(amount or 0)
  while v >= 1000 and i < #suffixes do v = v / 1000; i = i + 1 end
  local sign = (amount or 0) < 0 and "-" or ""
  return string.format("%s%.2f %sL", sign, v, suffixes[i])
end

local function fillColor(perc)
  for _, band in ipairs(config.ui.fillColors) do
    if perc < band.under then return band.color end
  end
  return 0xFFFFFF
end

-- ---------------------------------------------------------------------------
-- PAINTING PRIMITIVES
-- ---------------------------------------------------------------------------

local function setFG(c)
  if curFG ~= c then gpu.setForeground(c); curFG = c end
end

local function setBG(c)
  if curBG ~= c then gpu.setBackground(c); curBG = c end
end

-- True when row y already shows exactly this content, so the caller can skip
-- building anything at all — which is the expensive part in Lua terms.
local function fresh(y, key) return cache[y] == key end

-- cells = { {x, text, fg}, ... }, painted left to right over a cleared row.
local function paint(y, key, cells)
  if cache[y] == key then return end
  cache[y] = key
  setBG(0x000000)
  gpu.fill(1, y, W, 1, " ")
  for i = 1, #cells do
    local c = cells[i]
    setFG(c[3])
    gpu.set(c[1], y, c[2])
  end
end

function ui.invalidate()
  cache = {}
  curFG, curBG = nil, nil
end

-- ---------------------------------------------------------------------------
-- LAYOUT
-- ---------------------------------------------------------------------------

local function computeLayout()
  local pumpRows = 4
  L.pumpHeader   = 5
  L.pumpRule     = 6
  L.pumpFirst    = 7
  L.pumpRows     = pumpRows
  L.pumpCols     = 2
  L.pumpColX     = { 2, math.floor(W / 2) + 2 }

  L.queueHeader  = L.pumpFirst + pumpRows + 1     -- 12 at the default layout
  L.queueRule    = L.queueHeader + 1
  L.queueFirst   = L.queueRule + 1

  L.deltaHeader  = H - 5
  L.deltaRule    = H - 4
  L.deltaTitle   = H - 3
  L.footer       = H

  -- Whatever vertical space is left between the queue rule and the delta block
  -- is what the demand queue gets.
  L.queueRows    = math.max(1, L.deltaHeader - L.queueFirst - 1)
  L.queueCols    = math.max(1, config.ui.fluidColumns or 3)
  L.queueColW    = math.floor(W / L.queueCols)
end

-- ---------------------------------------------------------------------------
-- STATIC FRAME — drawn once at boot and after the terminal is disturbed.
-- ---------------------------------------------------------------------------
function ui.drawStaticFrame()
  if not gpu then return end
  ui.invalidate()
  setBG(0x000000)
  term.clear()

  local title = " GTNH SPACE-GAS LOGISTICS TERMINAL "
  setFG(0x00AAFF)
  gpu.fill(1, 1, W, 1, "=")
  setFG(0xFFFFFF)
  gpu.set(math.max(1, math.floor((W - #title) / 2)), 1, title)

  setFG(0x00AAFF)
  gpu.set(1, L.pumpHeader, "PUMP ARRAY STATUS")
  setFG(0x555555)
  gpu.fill(1, L.pumpRule, W, 1, "-")

  setFG(0x00AAFF)
  gpu.set(1, L.queueHeader, "FLUID DEMAND QUEUE")
  setFG(0x555555)
  gpu.fill(1, L.queueRule, W, 1, "-")

  setFG(0x555555)
  gpu.fill(1, L.deltaRule, W, 1, "-")
end

-- ---------------------------------------------------------------------------
-- PANELS
-- ---------------------------------------------------------------------------

local function drawHeaderLine(target)
  local st = pumps.state
  local me = st.meOk and "OK" or "DOWN"
  local key = string.format("%s|%d|%s|%s|%s",
    config.currentCellType, math.floor(config.safetyMargin * 100),
    ui.formatFluid(target), me, st.mode)
  if fresh(3, key) then return end
  paint(3, key, {
    { 2, string.format("CELL: %s   SAFE: %d%%   MAX: %s",
        config.currentCellType,
        math.floor((1 - config.safetyMargin) * 100),
        ui.formatFluid(target)), 0xAAAAAA },
    { math.floor(W / 2) + 2, "ME: " .. me, st.meOk and 0x00FF00 or 0xFF4444 },
    { math.floor(W / 2) + 14, "MODE: " .. st.mode, 0xFFCC33 },
  })
end

local function drawPumpPanel()
  local list = pumps.list()
  local perCol = L.pumpRows

  for slot = 1, L.pumpRows * L.pumpCols do
    local y = L.pumpFirst + ((slot - 1) % perCol)
    local colIndex = math.floor((slot - 1) / perCol) + 1
    -- Two pumps share each row (one per column), so the row's signature has to
    -- cover both of them. Build the key for the whole row when we reach its
    -- first column, and skip the row entirely if nothing in it moved.
    if colIndex == 1 then
      local keyParts, cells = {}, {}
      for c = 1, L.pumpCols do
        local p = list[(c - 1) * perCol + ((slot - 1) % perCol) + 1]
        local x = L.pumpColX[c]
        if not p then
          keyParts[#keyParts + 1] = "-"
        else
          local rate = "---"
          if p.status == "RUNNING" and p.task then
            local m = config.master[p.task]
            if m then rate = ui.formatFluid(m.rate * p.mult * p.threads) .. "/t" end
          end
          local statusColor =
            (p.status == "RUNNING" and 0x00FF00) or
            (p.status == "ARMING"  and 0xFFCC33) or
            (p.status == "ERROR"   and 0xFF4444) or 0x777777
          local detail
          if p.status == "ERROR" then
            detail = (p.lastError or "error"):sub(1, math.max(8, L.pumpColX[2] - x - 34))
          else
            detail = tostring(p.task or "None")
          end
          keyParts[#keyParts + 1] = table.concat({ p.short, p.tier, p.status, detail, rate }, "~")
          cells[#cells + 1] = { x,      string.format("%-4s %-3s", p.short, p.tier), 0xFFFFFF }
          cells[#cells + 1] = { x + 9,  string.format("%-8s", p.status),             statusColor }
          cells[#cells + 1] = { x + 18, string.format("%-20s", detail:sub(1, 20)),   0xCCCCCC }
          cells[#cells + 1] = { x + 39, rate,                                        0x668866 }
        end
      end
      local key = table.concat(keyParts, "||")
      if not fresh(y, key) then paint(y, key, cells) end
    end
  end
end

local function drawQueue(fluids)
  local cols  = L.queueCols
  local shown = math.min(#fluids, L.queueRows * cols, config.ui.maxFluidRows or 40)

  -- Fill the columns evenly rather than running the first one to the bottom of
  -- the screen before starting the second. With 40 fluids and 30 rows of space
  -- the naive version put 30 entries in column one, 10 in column two and left
  -- column three empty.
  local rows = math.min(L.queueRows, math.max(1, math.ceil(shown / cols)))

  -- Iterate the full height, not just `rows`: rows the layout has just vacated
  -- need one blank repaint to clear whatever used to be there.
  for r = 0, L.queueRows - 1 do
    local y = L.queueFirst + r
    local keyParts, cells = {}, {}
    for c = 0, cols - 1 do
      local idx = (r < rows) and (c * rows + r + 1) or (shown + 1)
      local f = (idx <= shown) and fluids[idx] or nil
      if not f then
        keyParts[#keyParts + 1] = "-"
      else
        local text = string.format("%-16s %7.3f%% %11s",
          f.label:sub(1, 16), f.perc, ui.formatFluid(f.amount))
        keyParts[#keyParts + 1] = text
        cells[#cells + 1] = { c * L.queueColW + 2, text, fillColor(f.perc) }
      end
    end
    local key = table.concat(keyParts, "||")
    if not fresh(y, key) then paint(y, key, cells) end
  end
end

local function drawDeltas()
  local st = pumps.state
  local n = config.ui.deltaRows or 3

  local sorted = {}
  for label, r in pairs(st.rates) do
    if r ~= 0 then sorted[#sorted + 1] = { label = label, rate = r } end
  end
  table.sort(sorted, function(a, b)
    if a.rate ~= b.rate then return a.rate > b.rate end
    return a.label < b.label
  end)

  local hdr = string.format("NET FLOW   (total in: %s/s)", ui.formatFluid(st.throughput))
  if not fresh(L.deltaHeader, hdr) then
    paint(L.deltaHeader, hdr, { { 1, hdr, 0x00AAFF } })
  end

  local rightX = math.floor(W / 2) + 2
  local titleKey = "titles"
  if not fresh(L.deltaTitle, titleKey) then
    paint(L.deltaTitle, titleKey, {
      { 2,      "TOP INFLOW:",  0x00FF00 },
      { rightX, "TOP OUTFLOW:", 0xFF6666 },
    })
  end

  for i = 1, n do
    local y = L.deltaTitle + i
    if y >= L.footer then break end
    local up   = sorted[i]
    local down = sorted[#sorted - (i - 1)]
    if up and up.rate <= 0 then up = nil end
    if down and down.rate >= 0 then down = nil end
    -- Guard the middle: with few movers the same entry can be both the i-th
    -- highest and the i-th lowest.
    if up and down and up.label == down.label then down = nil end

    local keyParts, cells = {}, {}
    if up then
      local s = string.format("%-16s %+12s/s", up.label:sub(1, 16), ui.formatFluid(up.rate))
      keyParts[1] = s
      cells[#cells + 1] = { 2, s, 0x00FF00 }
    else keyParts[1] = "-" end
    if down then
      local s = string.format("%-16s %12s/s", down.label:sub(1, 16), ui.formatFluid(down.rate))
      keyParts[2] = s
      cells[#cells + 1] = { rightX, s, 0xFF6666 }
    else keyParts[2] = "-" end

    local key = table.concat(keyParts, "||")
    if not fresh(y, key) then paint(y, key, cells) end
  end
end

local function drawFooter(target)
  local mode = pumps.state.mode
  local key = "footer|" .. mode .. "|" .. ui.formatFluid(target)
  if fresh(L.footer, key) then return end

  local cells = { { 2, "TARGET: " .. ui.formatFluid(target), 0xAAAAAA } }
  local labels = { { "[N]ormal", "Normal" }, { "[S]tairstep", "Stairstep" },
                   { "[W]aterfall", "Waterfall" }, { "[Q]uit", nil } }
  local x = math.max(30, W - 56)
  for _, m in ipairs(labels) do
    local selected = (m[2] ~= nil and mode == m[2])
    cells[#cells + 1] = { x, (selected and ">" or " ") .. m[1],
                          selected and 0x00FF00 or 0x777777 }
    x = x + 14
  end
  paint(L.footer, key, cells)
end

-- One frame. Cheap when nothing changed.
function ui.draw(fluids, target)
  if not gpu then return end
  drawHeaderLine(target)
  drawPumpPanel()
  drawQueue(fluids)
  drawDeltas()
  drawFooter(target)
end

-- ---------------------------------------------------------------------------
-- BOOT SCREEN — plain writes, no cache; the frame is not up yet.
-- ---------------------------------------------------------------------------
function ui.drawBoot(lines)
  if not gpu then return end
  setBG(0x000000)
  term.clear()
  setFG(0x00AAFF)
  gpu.fill(1, 1, W, 1, "=")
  setFG(0xFFFFFF)
  gpu.set(3, 1, " SPACE PUMPING - PRE-LAUNCH CHECK ")
  setFG(0xAAAAAA)
  for i, line in ipairs(lines) do
    if 3 + i <= H then
      gpu.fill(1, 3 + i, W, 1, " ")
      gpu.set(3, 3 + i, tostring(line):sub(1, W - 4))
    end
  end
end

function ui.shutdown(message)
  if not gpu then return end
  setBG(0x000000)
  setFG(0xFFFFFF)
  term.clear()
  term.setCursor(1, 1)
  if message then print(message) end
end

function ui.size() return W, H end

function ui.init(deps)
  config = deps.config
  pumps  = deps.pumps
  gpu    = component.isAvailable("gpu") and component.gpu or nil
  if gpu then
    -- Precedence trap the miner documents: `local W, H = gpu and f() or 120, 50`
    -- binds H to 50 whatever the hardware says. Two statements, no ambiguity.
    local mw, mh = gpu.maxResolution()
    W = mw or W
    H = mh or H
    gpu.setResolution(W, H)
  end
  computeLayout()
  ui.invalidate()
  return ui
end

return ui
