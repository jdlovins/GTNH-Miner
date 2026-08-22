-- =============================================================================
-- diag.lua — what is actually on this computer's component network?
--
-- Run this when autoPump reports ERR on a module, or ME: DOWN in the header.
--
-- CALLS GO THROUGH component.invoke, NOT through a proxy.
--   The first version of this file probed methods as `proxy[name]` and reported
--   every single one as absent while component.methods() listed 29 of them --
--   pure noise, and it nearly sent us after the wrong bug. invoke() is the
--   primitive underneath both, so it cannot disagree with methods().
--
-- Nothing here writes or changes anything. Every call is pcall'd, so a component
-- that throws is reported rather than ending the run.
--
--   diag            everything, summarised
--   diag pumps      just the GT machines, including their live parameter list
--   diag me         just the fluid-source hunt
--   diag full       every method name of every component
-- =============================================================================

local component = require("component")

local args = { ... }
local want = {}
for _, a in ipairs(args) do want[a] = true end
local ALL   = not (want.pumps or want.me)
local FULL  = want.full

local function hr() print(string.rep("-", 76)) end

-- Method names a component genuinely has, straight from the driver.
local function methodsOf(addr)
  local ok, m = pcall(component.methods, addr)
  if not ok or type(m) ~= "table" then return nil, tostring(m) end
  local names = {}
  for name in pairs(m) do names[#names + 1] = name end
  table.sort(names)
  return names
end

local function has(names, wanted)
  if not names then return false end
  for _, n in ipairs(names) do if n == wanted then return true end end
  return false
end

-- Render any value compactly enough to read off a screenshot.
local function show(v, depth)
  depth = depth or 0
  if type(v) ~= "table" then return tostring(v) end
  if depth >= 2 then return "{...}" end
  local parts, n = {}, 0
  for k, val in pairs(v) do
    n = n + 1
    if n > 12 then parts[#parts + 1] = "..."; break end
    parts[#parts + 1] = tostring(k) .. "=" .. show(val, depth + 1)
  end
  return "{" .. table.concat(parts, " ") .. "}"
end

-- Invoke and describe the result, without ever throwing.
local function call(addr, name, ...)
  local r = table.pack(pcall(component.invoke, addr, name, ...))
  if not r[1] then return "THREW: " .. tostring(r[2]) end
  if r.n <= 1 then return "(no return value)" end
  local parts = {}
  for i = 2, r.n do parts[#parts + 1] = show(r[i]) end
  return "-> " .. table.concat(parts, ", ")
end

print("================================================")
print("  SPACE PUMPING DIAGNOSTIC")
print("================================================")
print("")

local byType = {}
for addr, ctype in component.list() do
  byType[ctype] = byType[ctype] or {}
  table.insert(byType[ctype], addr)
end
local types = {}
for t in pairs(byType) do types[#types + 1] = t end
table.sort(types)

-- ---------------------------------------------------------------------------
if ALL then
  print("ALL COMPONENTS")
  hr()
  for _, t in ipairs(types) do
    print(string.format("  %-26s x%-3d %s", t, #byType[t], byType[t][1]:sub(1, 8)))
  end
  print("")
end

-- ---------------------------------------------------------------------------
-- GT MACHINES
--
-- getParameters() is the important one. GTNH 2.9 replaced the old indexed
-- setParameters(i, j, value) with named setParameter(key, value), and the key
-- names are not documented anywhere we can rely on -- so we read them off the
-- machine itself.
-- ---------------------------------------------------------------------------
if ALL or want.pumps then
  print("GT MACHINES (pumping modules)")
  hr()
  if not byType["gt_machine"] then
    print("  NONE FOUND. Each module needs an Adapter touching its CONTROLLER.")
  else
    for _, addr in ipairs(byType["gt_machine"]) do
      print("  " .. addr:sub(1, 8))
      print("    getName            " .. call(addr, "getName"))
      print("    isMachineActive    " .. call(addr, "isMachineActive"))
      print("    isWorkAllowed      " .. call(addr, "isWorkAllowed"))
      print("    getWorkProgress    " .. call(addr, "getWorkProgress"))

      local names = methodsOf(addr)
      print("    parameter API:")
      for _, m in ipairs({ "setParameter", "setParameters",
                           "getParameter", "getParameters",
                           "setWorkAllowed", "getSensorInformation" }) do
        print(string.format("      %-22s %s", m, has(names, m) and "present" or "MISSING"))
      end

      -- The live parameter list: names, current values, and anything else the
      -- machine chooses to report about them.
      if has(names, "getParameters") then
        local ok, params = pcall(component.invoke, addr, "getParameters")
        if not ok then
          print("    getParameters THREW: " .. tostring(params))
        elseif type(params) ~= "table" then
          print("    getParameters -> " .. tostring(params))
        else
          print("    PARAMETERS:")
          local keys = {}
          for k in pairs(params) do keys[#keys + 1] = k end
          table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
          for _, k in ipairs(keys) do
            print(string.format("      %-22s %s", tostring(k), show(params[k])))
          end
        end
      end

      if FULL and names then
        print("    all " .. #names .. " methods:")
        for _, n in ipairs(names) do print("      " .. n) end
      elseif names then
        print("    (" .. #names .. " methods; 'diag full' to list them)")
      end
      print("")
    end
  end
end

-- ---------------------------------------------------------------------------
-- FLUID SOURCE
--
-- Probe EVERY component rather than the ones whose type name looks ME-ish. The
-- previous version filtered on "^me_" and reported NONE FOUND, which cannot
-- distinguish "no adapter on an ME block" from "the block is called something I
-- did not think of".
-- ---------------------------------------------------------------------------
if ALL or want.me then
  print("FLUID SOURCE HUNT")
  hr()
  print("  Probing every component for getFluidsInNetwork()...")
  print("")
  local hits = 0
  for _, t in ipairs(types) do
    for _, addr in ipairs(byType[t]) do
      local names = methodsOf(addr)
      if has(names, "getFluidsInNetwork") then
        hits = hits + 1
        print("  FOUND  " .. t .. "  " .. addr:sub(1, 8))
        local ok, fluids = pcall(component.invoke, addr, "getFluidsInNetwork")
        if not ok then
          print("    getFluidsInNetwork THREW: " .. tostring(fluids))
        elseif type(fluids) ~= "table" then
          print("    -> " .. tostring(fluids))
        else
          print("    " .. #fluids .. " fluid(s) visible:")
          for i = 1, math.min(#fluids, 8) do
            local f = fluids[i]
            print(string.format("      %-28s %s",
              tostring(f.label or f.name or "?"), tostring(f.amount or "?")))
          end
          if #fluids > 8 then print("      ... and " .. (#fluids - 8) .. " more") end
        end
        print("")
      end
    end
  end

  if hits == 0 then
    print("  NOTHING on this network answers getFluidsInNetwork().")
    print("")
    print("  Components that look ME-related, and what they DO offer:")
    local shown = false
    for _, t in ipairs(types) do
      if t:lower():find("me_") or t:lower():find("ae2") or t:lower():find("applied")
         or t:lower():find("interface") or t:lower():find("controller") then
        shown = true
        local addr = byType[t][1]
        local names = methodsOf(addr)
        print("    " .. t .. "  (" .. (names and #names or 0) .. " methods)")
        if names then
          for _, n in ipairs(names) do
            if n:lower():find("fluid") or n:lower():find("network")
               or n:lower():find("storage") then
              print("      " .. n)
            end
          end
        end
      end
    end
    if not shown then
      print("    (none -- no ME component is reaching this computer at all)")
      print("")
      print("  An Adapter reads only the block it is PHYSICALLY TOUCHING,")
      print("  face to face. Being on the same cable, or beside the block,")
      print("  is not enough. Check the Adapter is flush against the ME block.")
    end
    print("")
  end
end

print("Done.  'diag full' lists every method of every component.")
