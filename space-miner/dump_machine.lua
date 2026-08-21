-- =============================================================================
-- dump_machine.lua
-- Dumps everything a Mining Module's gt_machine adapter actually exposes:
-- method names, whether each is a direct call, and GT's own doc string for it
-- (which carries the real signature). Then prints the machine's sensor readout,
-- which is where the live parameter values show up.
--
-- WHY THIS EXISTS:
--   broker-mk3 used to call setParameters(distanceParam, 0, distance) to set the
--   asteroid distance. On current GT that method is gone -- calling it dies with
--   "attempt to call a nil value (field 'setParameters')". Rather than guess at
--   the replacement name and break the same way again, ask the machine.
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

for _, addr in ipairs(targets) do
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
        print("    " .. doc)
      else
        print("    " .. name .. "()  [direct=" .. tostring(methods[name]) .. "]")
      end
    end

    -- Call out anything parameter-shaped, since that is what we are hunting.
    print("\n  PARAMETER-SHAPED METHODS:")
    local hits = 0
    for _, name in ipairs(names) do
      if name:lower():find("param") or name:lower():find("tier")
         or name:lower():find("config") or name:lower():find("distance") then
        print("    -> " .. name)
        hits = hits + 1
      end
    end
    if hits == 0 then print("    (none -- parameters may be set another way)") end
  end

  -- --- Live sensor readout: where current parameter values appear ----------
  local proxy = component.proxy(addr)
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

print("Paste this whole output back to wire distance + tier to the real API.")
