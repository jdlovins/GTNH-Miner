-- find_item.lua
-- Searches the ME network for items matching a keyword.
-- Usage: find_item  (searches for "salt" by default)

local component = require("component")
local me = component.me_controller

local keyword = (... or "salt"):lower()
print("Searching ME network for: " .. keyword)
print("")

local items = me.getItemsInNetwork()
for _, item in ipairs(items) do
    if item.label and item.label:lower():find(keyword, 1, true) then
        print(string.format("  label=%s  size=%d  name=%s  dmg=%d",
            item.label, item.size or 0, item.name or "?", item.damage or 0))
    end
end
