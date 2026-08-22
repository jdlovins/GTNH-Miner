-- =============================================================================
-- diag.lua — what is actually on this computer's component network?
--
-- Run this when autoPump reports ERR on a module, or ME: DOWN in the header.
-- It answers the only two questions that matter in those cases:
--
--   1. Which components can we see, and what are they called?
--   2. Which METHODS does each one actually expose, and what do the ones we
--      depend on return when called?
--
-- Everything is pcall'd, so a component that throws is reported rather than
-- ending the run. Nothing here writes or changes anything.
--
--   diag              summary of every component
--   diag full         plus the complete method list for each relevant component
-- =============================================================================

local component = require("component")

local args = { ... }
local FULL = false
for _, a in ipairs(args) do if a == "full" then FULL = true end end

local function hr() print(string.rep("-", 78)) end

local function methodsOf(addr)
  -- component.methods() is the canonical listing: name -> isDirect.
  local ok, m = pcall(component.methods, addr)
  if not ok or type(m) ~= "table" then return nil, tostring(m) end
  local names = {}
  for name in pairs(m) do names[#names + 1] = name end
  table.sort(names)
  return names
end

local function has(names, want)
  if not names then return false end
  for _, n in ipairs(names) do if n == want then return true end end
  return false
end

-- Call a method and describe what came back, without ever throwing.
local function tryCall(proxy, name, ...)
  local fn = proxy[name]
  if type(fn) ~= "function" then return "NOT PRESENT" end
  local r = table.pack(pcall(fn, ...))
  if not r[1] then return "THREW: " .. tostring(r[2]) end
  if r.n <= 1 then return "returned nothing" end
  local parts = {}
  for i = 2, r.n do
    local v = r[i]
    if type(v) == "table" then parts[#parts + 1] = "table(" .. #v .. " entries)"
    else parts[#parts + 1] = tostring(v) end
  end
  return "-> " .. table.concat(parts, ", ")
end

print("================================================")
print("  SPACE PUMPING DIAGNOSTIC")
print("================================================")
print("")

-- ---------------------------------------------------------------------------
-- 1. EVERYTHING WE CAN SEE
-- ---------------------------------------------------------------------------
print("ALL COMPONENTS")
hr()
local byType = {}
for addr, ctype in component.list() do
  byType[ctype] = byType[ctype] or {}
  table.insert(byType[ctype], addr)
end
local types = {}
for t in pairs(byType) do types[#types + 1] = t end
table.sort(types)
for _, t in ipairs(types) do
  print(string.format("  %-24s x%d   %s", t, #byType[t], byType[t][1]:sub(1, 8)))
end
print("")

-- ---------------------------------------------------------------------------
-- 2. GT MACHINES — the pumping modules
-- ---------------------------------------------------------------------------
print("GT MACHINES (pumping modules)")
hr()
if not byType["gt_machine"] then
  print("  NONE FOUND.")
  print("  Each module needs an Adapter touching its CONTROLLER block.")
else
  for _, addr in ipairs(byType["gt_machine"]) do
    local proxy = component.proxy(addr)
    print("  " .. addr:sub(1, 8))
    print("    getName()          " .. tryCall(proxy, "getName"))
    print("    isMachineActive()  " .. tryCall(proxy, "isMachineActive"))
    print("    isWorkAllowed()    " .. tryCall(proxy, "isWorkAllowed"))
    print("    hasWork()          " .. tryCall(proxy, "hasWork"))
    print("    getSensorInfo      " .. tryCall(proxy, "getSensorInformation"))

    local names, err = methodsOf(addr)
    if not names then
      print("    (method list unavailable: " .. tostring(err) .. ")")
    else
      print("    " .. #names .. " methods total")
      -- The ones this program depends on.
      for _, want in ipairs({ "getName", "isMachineActive", "setWorkAllowed",
                              "setParameters", "getParameters" }) do
        print(string.format("      %-18s %s", want, has(names, want) and "yes" or "MISSING"))
      end
      if FULL then
        print("    all methods:")
        for _, n in ipairs(names) do print("      " .. n) end
      end
    end
    print("")
  end
end

-- ---------------------------------------------------------------------------
-- 3. ME COMPONENTS — where stock figures come from
-- ---------------------------------------------------------------------------
print("ME COMPONENTS (fluid stock source)")
hr()
local found = false
for _, t in ipairs(types) do
  if t:find("^me_") or t:find("appliedenergistics") or t:find("^ae2") then
    found = true
    for _, addr in ipairs(byType[t]) do
      local proxy = component.proxy(addr)
      print("  " .. t .. "  " .. addr:sub(1, 8))
      print("    getFluidsInNetwork()  " .. tryCall(proxy, "getFluidsInNetwork"))
      print("    getItemsInNetwork()   " .. tryCall(proxy, "getItemsInNetwork"))
      print("    getFluidsInStorage()  " .. tryCall(proxy, "getFluidsInStorage"))
      print("    getAvgPowerUsage()    " .. tryCall(proxy, "getAvgPowerUsage"))

      local names, err = methodsOf(addr)
      if not names then
        print("    (method list unavailable: " .. tostring(err) .. ")")
      else
        print("    " .. #names .. " methods total")
        if FULL then
          for _, n in ipairs(names) do print("      " .. n) end
        else
          -- Without `full`, show just the ones that look fluid-related, which is
          -- what we are hunting for.
          local hits = {}
          for _, n in ipairs(names) do
            if n:lower():find("fluid") then hits[#hits + 1] = n end
          end
          if #hits > 0 then
            print("    fluid-related methods:")
            for _, n in ipairs(hits) do print("      " .. n) end
          else
            print("    NO fluid-related methods on this component.")
          end
        end
      end
      print("")
    end
  end
end
if not found then
  print("  NONE FOUND.")
  print("  Put an Adapter against an ME Controller (or an ME Interface) that")
  print("  belongs to the network holding your fluid cells.")
  print("")
end

print("Run 'diag full' for the complete method list of every component above.")
