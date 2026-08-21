-- =============================================================================
-- verify_items.lua
-- Checks every item label in config against what the ME network actually calls
-- things, and suggests corrections for the ones that do not match.
--
-- WHY THIS EXISTS:
--   config.dustTargets and config.conditions key off EXACT ME item labels. Get
--   one wrong and the failure is silent and total: the dust node never scans it,
--   the broker shows a permanent 0%, and it looks like "we have none of this,
--   mine it urgently" rather than "this name is wrong". Two are already known
--   bad -- "Tengam Dust" is really "Raw Tengam Dust", and "PlatLine Dust" is not
--   an item at all -- and the labels were written by hand, so there is no reason
--   to think those are the only two.
--
--   OpenComputers cannot enumerate the game's item registry, so the only source
--   of truth available is your own ME network. Run this on a machine with an ME
--   Interface or Controller attached, ideally your main network rather than the
--   dust subnet, since it can only vouch for labels it can actually see.
--
-- READ THE OUTPUT CAREFULLY:
--   NOT FOUND does not prove a name is wrong. It means the network has none of
--   that item and no crafting pattern for it, which is also what a legitimately
--   empty stock looks like. What makes it damning is a near-miss suggestion:
--   "Tengam Dust" NOT FOUND alongside "Raw Tengam Dust" present is conclusive.
--
-- USAGE:  verify_items           check config.dustTargets (all 106)
--         verify_items cond      check only config.conditions
--         verify_items <text>    check only entries matching <text>
-- =============================================================================

local component = require("component")

local config = assert(loadfile("/home/config.lua"))()

-- --- Reach the ME network ----------------------------------------------------
local me
for addr in component.list("me_interface")  do me = component.proxy(addr) break end
if not me then
  for addr in component.list("me_controller") do me = component.proxy(addr) break end
end
if not me then
  print("No ME Interface or Controller found on this machine.")
  print("Attach one via an Adapter and run this again -- without a network to")
  print("compare against there is nothing this script can tell you.")
  return
end

-- --- Collect every label the network knows about -----------------------------
local labels = {}      -- label -> stock (craftable-only entries are 0)
local count  = 0

do
  local ok, items = pcall(me.getItemsInNetwork)
  if ok and items then
    for _, it in ipairs(items) do
      if it and it.label then
        labels[it.label] = (labels[it.label] or 0) + (it.size or 0)
      end
    end
  else
    print("getItemsInNetwork failed: " .. tostring(items))
    return
  end

  -- Craftables matter: an item you can make but hold none of is still a real
  -- label, and treating it as missing would produce a false alarm.
  if me.getCraftables then
    local okc, craft = pcall(me.getCraftables)
    if okc and craft then
      for _, c in ipairs(craft) do
        local oks, st = pcall(function() return c.getItemStack and c:getItemStack() end)
        if oks and st and st.label and labels[st.label] == nil then
          labels[st.label] = 0
        end
      end
    end
  end

  for _ in pairs(labels) do count = count + 1 end
end

print(string.format("ME network knows %d distinct item labels.", count))
print("")

-- --- Fuzzy suggestions -------------------------------------------------------
local STOPWORDS = { dust = true, ore = true, raw = true, crushed = true,
                    block = true, tiny = true, small = true, pile = true }

local function tokens(s)
  local out = {}
  for w in s:lower():gmatch("[%a]+") do
    if not STOPWORDS[w] then out[#out + 1] = w end
  end
  return out
end

-- Anything sharing a distinctive word with the query. That is what catches
-- "Tengam Dust" -> "Raw Tengam Dust".
local function suggest(name)
  local want = tokens(name)
  if #want == 0 then return {} end
  local hits = {}
  for label in pairs(labels) do
    local low = label:lower()
    local score = 0
    for _, w in ipairs(want) do
      if #w >= 4 and low:find(w, 1, true) then score = score + 1 end
    end
    if score > 0 then hits[#hits + 1] = { label = label, score = score } end
  end
  table.sort(hits, function(a, b)
    if a.score ~= b.score then return a.score > b.score end
    return #a.label < #b.label
  end)
  local top = {}
  for i = 1, math.min(4, #hits) do top[i] = hits[i].label end
  return top
end

local function fmt(n)
  if n >= 1000000 then return string.format("%.1fm", n / 1000000) end
  if n >= 1000    then return string.format("%.0fk", n / 1000) end
  return tostring(n)
end

-- --- What to check -----------------------------------------------------------
local arg = ...
local checkList, sourceName = {}, ""

if arg == "cond" then
  sourceName = "config.conditions"
  for _, c in ipairs(config.conditions) do checkList[#checkList + 1] = c.itemName end
else
  sourceName = "config.dustTargets"
  for name in pairs(config.dustTargets) do checkList[#checkList + 1] = name end
  if arg and arg ~= "" then
    local filtered = {}
    for _, n in ipairs(checkList) do
      if n:lower():find(arg:lower(), 1, true) then filtered[#filtered + 1] = n end
    end
    checkList = filtered
  end
end
table.sort(checkList)

print(string.format("Checking %d names from %s", #checkList, sourceName))
print(string.rep("-", 70))

local okCount, missing = 0, {}

for _, name in ipairs(checkList) do
  local stock = labels[name]
  if stock ~= nil then
    okCount = okCount + 1
    print(string.format("  OK        %-32s %s", name, fmt(stock)))
  else
    missing[#missing + 1] = name
  end
end

print("")
print(string.rep("-", 70))
print(string.format("%d of %d found. %d not found:", okCount, #checkList, #missing))
print("")

for _, name in ipairs(missing) do
  print("  NOT FOUND  " .. name)
  local s = suggest(name)
  if #s > 0 then
    for _, cand in ipairs(s) do
      print(string.format("               did you mean: %-34s %s", cand, fmt(labels[cand])))
    end
  else
    print("               no similar label in this network")
  end
end

print("")
print("Remember: NOT FOUND with a near-miss suggestion means the name is wrong.")
print("NOT FOUND with nothing similar may just mean you have none of it yet.")
