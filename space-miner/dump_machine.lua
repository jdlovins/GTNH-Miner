-- =============================================================================
-- dump_machine.lua
-- Dumps everything a Mining Module's gt_machine adapter actually exposes:
-- method names with GT's own doc strings, the full parameter table, and the
-- sensor readout.
--
-- WHY THIS EXISTS:
--   broker-mk3 used to call setParameters(distanceParam, 0, distance) to set the
--   asteroid distance. Current GT has no such method -- it dies with "attempt to
--   call a nil value (field 'setParameters')". What it has instead is:
--
--     setParameter(key:string, val:any)   -- note: singular, and keyed by STRING
--     getParameters():table               -- the value of all parameters
--
--   So the index-based call became a key-based one. This script prints the keys.
--
-- USAGE:  dump_machine            (dumps every gt_machine on the network)
--         dump_machine 1a2b3c4d   (dumps one, by address prefix)
--
-- Read-only. It calls no setter and changes nothing.
-- =============================================================================

local component = require("component")

local filter = ...

local targets = {}
for addr in component.list("gt_machine") do
  if not filter or addr:sub(1, #filter) == filter then
    targets[#targets + 1] = addr
  end
end

if #targets == 0 then
  print("No gt_machine adapters found" .. (filter and (" matching '" .. filter .. "'") or "") .. ".")
  print("Check the OC Adapter is on the Mining Module controller.")
  return
end

-- Walk a table of unknown shape (parameters may be nested hatch -> params).
local function dumpTable(t, indent)
  local keys = {}
  for k in pairs(t) do keys[#keys + 1] = k end
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
  if #keys == 0 then print(indent .. "(empty)") return end
  for _, k in ipairs(keys) do
    local v = t[k]
    if type(v) == "table" then
      print(string.format("%s%-30s (table)", indent, tostring(k)))
      dumpTable(v, indent .. "  ")
    else
      print(string.format("%s%-30s = %-12s [%s]", indent, tostring(k), tostring(v), type(v)))
    end
  end
end

for _, addr in ipairs(targets) do
  local proxy = component.proxy(addr)

  print("=====================================================================")
  print("gt_machine  " .. addr)
  print("=====================================================================")

  -- --- Methods, with GT's own documentation --------------------------------
  local ok, methods = pcall(component.methods, addr)
  if not ok or not methods then
    print("  (could not list methods: " .. tostring(methods) .. ")")
  else
    local names = {}
    for name in pairs(methods) do names[#names + 1] = name end
    table.sort(names)

    print("\n  METHODS (" .. #names .. "):")
    for _, name in ipairs(names) do
      local okDoc, doc = pcall(component.doc, addr, name)
      if okDoc and doc and doc ~= "" then
        print(string.format("    %-26s %s", name, doc))
      else
        print(string.format("    %-26s [direct=%s]", name, tostring(methods[name])))
      end
    end
  end

  -- --- THE POINT: the exact keys setParameter(key, val) accepts -------------
  print("\n  GET PARAMETERS:")
  local okP, params = pcall(function() return proxy.getParameters() end)
  if not okP then
    print("    (call failed: " .. tostring(params) .. ")")
  elseif type(params) ~= "table" then
    print("    (returned " .. type(params) .. ": " .. tostring(params) .. ")")
  else
    dumpTable(params, "    ")
  end

  -- --- Live sensor readout --------------------------------------------------
  print("\n  SENSOR INFORMATION:")
  local okS, info = pcall(function() return proxy.getSensorInformation() end)
  if okS and type(info) == "table" then
    for i, line in ipairs(info) do
      print(string.format("    [%2d] %s", i, tostring(line)))
    end
  else
    print("    (unavailable: " .. tostring(info) .. ")")
  end

  print("")
end

print("Paste the GET PARAMETERS section back -- those keys are what")
print("setParameter(key, val) needs for distance and tier.")
