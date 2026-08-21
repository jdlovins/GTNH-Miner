-- =============================================================================
-- Node ID: MEDINA-HWRelay
-- File:    hw_telem.lua
-- Purpose: Scans Space Elevator staging ME network for drone and drill
--          consumable availability; broadcasts stock data to the broker, and
--          auto-crafts drill tips/rods back up to the par levels the broker
--          publishes (DRILL_PAR on port 2025).
--
--          The broker owns the par policy; this node owns execution, because it
--          holds the ME controller proxy and the freshest counts. See
--          broadcastDrillPar() in broker-mk3.lua for the other half.
--
-- OpenComputers Sides Reference Matrix:
--   0 = Bottom / Down (-Y) | 1 = Top / Up (+Y) | 2 = North (-Z)
--   3 = South (+Z)         | 4 = West (-X)     | 5 = East (+X)
-- =============================================================================

local component     = require("component")
local serialization = require("serialization")
local term          = require("term")
local event         = require("event")
local computer      = require("computer")

if not component.isAvailable("modem")   then error("Missing network card.")    end
if not component.isAvailable("gpu")     then error("Requires GPU.")             end

local modem = component.modem
if not modem.isWireless or not modem.isWireless() then
  error("Node requires a T2 Wireless Network Card.")
end

-- Find and connect to ME Controller for direct inventory scanning
local me = nil
for addr, name in component.list("me_controller") do
  me = component.proxy(addr)
  break
end
if not me then error("Missing ME Controller (needed to read network inventory).") end

local gpu      = component.gpu
local nodeName = "MEDINA-HWRelay"

-- Hardcoded drone and drill lists (don't load config to save memory)
local droneKeys = {"max","uxv","umv","uiv","uev","uhv","uv","zpm","luv","iv","ev","hv","mv","lv"}
-- Full ME network labels, including the voltage suffix (mirrors config.drones).
local droneNames = {
  max="Mining Drone MK-XIV (MAX)", uxv="Mining Drone MK-XIII (UXV)", umv="Mining Drone MK-XII (UMV)",
  uiv="Mining Drone MK-XI (UIV)", uev="Mining Drone MK-X (UEV)", uhv="Mining Drone MK-IX (UHV)",
  uv="Mining Drone MK-VIII (UV)", zpm="Mining Drone MK-VII (ZPM)", luv="Mining Drone MK-VI (LuV)",
  iv="Mining Drone MK-V (IV)", ev="Mining Drone MK-IV (EV)", hv="Mining Drone MK-III (HV)",
  mv="Mining Drone MK-II (MV)", lv="Mining Drone MK-I (LV)"
}

-- Map drone keys to their voltage tiers
local droneVoltages = {
  max="MAX", uxv="UXV", umv="UMV", uiv="UIV", uev="UEV", uhv="UHV",
  uv="UV", zpm="ZPM", luv="LuV", iv="IV", ev="EV", hv="HV",
  mv="MV", lv="LV"
}

modem.setStrength(400)
modem.open(2026)  -- telemetry: this node -> broker
modem.open(2025)  -- commands from the broker aimed at this node (DRILL_PAR)
gpu.setResolution(80, 25)

-- Build exact-match lookup tables for drill names (item label → drill key).
-- Avoids substring matching that would catch non-consumable items like "Gold Rod".
local drillLookup = {
  ["Steel Drill Tip"]              = "steel",
  ["Steel Rod"]                    = "steel",
  ["Titanium Drill Tip"]           = "titanium",
  ["Titanium Rod"]                 = "titanium",
  ["Tungstensteel Drill Tip"]      = "tungstensteel",
  ["Tungstensteel Rod"]            = "tungstensteel",
  ["Naquadah Drill Tip"]           = "naquadah",
  ["Naquadah Rod"]                 = "naquadah",
  ["Naquadah Alloy Drill Tip"]     = "naquadahAlloy",
  ["Naquadah Alloy Rod"]           = "naquadahAlloy",
  ["Neutronium Drill Tip"]         = "neutronium",
  ["Neutronium Rod"]               = "neutronium",
  ["Cosmic Neutronium Drill Tip"]  = "cosmicNeutronium",
  ["Cosmic Neutronium Rod"]        = "cosmicNeutronium",
  ["Infinity Drill Tip"]           = "infinity",
  ["Infinity Rod"]                 = "infinity",
  ["Transcendent Metal Drill Tip"] = "transcendentMetal",
  ["Transcendent Metal Rod"]       = "transcendentMetal"
}

-- Display order for drills (lowest → highest tier)
local drillKeyOrder = {
  "steel","titanium","tungstensteel","naquadah",
  "naquadahAlloy","neutronium","cosmicNeutronium","infinity","transcendentMetal"
}

-- Drill display names (key → short name for display)
local drillDisplayNames = {
  steel="Steel", titanium="Titanium", tungstensteel="Tungstensteel",
  naquadah="Naquadah", naquadahAlloy="Naquadah Alloy", neutronium="Neutronium",
  cosmicNeutronium="Cosmic Neutronium", infinity="Infinity", transcendentMetal="Transcendent Metal"
}

-- =============================================================================
-- AUTO-CRAFT / PAR RESTOCK
--
-- The broker publishes par levels as ME labels (DRILL_PAR on 2025). Every scan
-- cycle we diff par against what the network actually holds and, for anything
-- short, ask the ME network to craft the difference.
--
-- Two things make this less trivial than the diff suggests:
--
--  1. An in-flight craft has not landed in the network yet, so the deficit stays
--     positive for as long as it runs. Without the `orders` guard below we would
--     re-issue the same request every cycle and bury the crafting CPUs.
--  2. This loop does NOT actually tick every 10s. event.pull(10, ...) returns
--     early on any modem traffic on any open port, and two other telem nodes
--     broadcast on 2026 continuously -- so iterations are frequent and
--     irregular. Every rate limit here is therefore wall-clock
--     (computer.uptime()), never a loop counter.
-- =============================================================================

-- label -> par count, as last published by the broker. Empty until it speaks,
-- and an empty table means "order nothing" -- with no broker on the air this
-- node behaves exactly as it did before auto-crafting existed.
local par = {}

-- label -> { want, state, status, since, baseStock }
--   state     = "crafting" | "nopattern" | "failed"
--   status    = the AE2 craft-status object, only present while "crafting"
--   since     = computer.uptime() when this state was entered
--   baseStock = network count at the moment the request was placed; the
--               reference point the settle gate below compares against
local orders = {}

-- How long a "crafting" order may sit before we assume its status object is
-- dead and allow a re-request. AE2 status objects do not survive every network
-- hiccup, and without this a single lost handle would wedge one material
-- permanently -- exactly the silent stall this feature exists to remove.
local ORDER_TIMEOUT = 600

-- Minimum wall-clock gap before retrying a label that had no pattern or whose
-- request failed. A network with no pattern must not be probed every iteration.
local RETRY_INTERVAL = 60

-- After a craft reports done, wait until a scan actually observes the delivered
-- items before considering that label again.
--
-- Without this we double-order. `assets` is the snapshot taken at the top of the
-- iteration, so when a craft completes mid-cycle the order is retired while the
-- scan still shows the old, pre-delivery count -- and the ordering pass below
-- re-requests a deficit that has in fact just been filled.
--
-- The gate is "stock changed", not "N seconds elapsed", because this loop has no
-- reliable period to time against (see the header note: event.pull returns early
-- on any modem traffic, so cycles are irregular). Waiting on the real signal is
-- both simpler to reason about and correct at any cycle rate.
--
-- The baseline is the stock recorded when the request was PLACED, not when
-- completion was noticed. Those differ, and using the latter breaks partial
-- deliveries: if a craft yields less than asked and we notice completion a cycle
-- late, the count has already moved, and a "did it move since completion?" test
-- would sit and wait for a second delivery that is never coming.
--
-- SETTLE_MAX is only a backstop, for the case where a craft reports done but the
-- count never moves -- someone pulled the output, or the status lied. Without it
-- that label would never be ordered again.
local SETTLE_MAX = 120

-- label -> { stock = count when the order was placed, expires = uptime }
local settle = {}

-- Ask a craft-status object a yes/no question without letting a dead handle
-- take down the telemetry loop. Returns false if the call is unavailable or
-- throws, which is the safe answer for all three callers below: "not finished".
--
-- Called with `status` as an argument so this works whether the object wants
-- self (userdata with a metatable) or not (a plain table of closures, which is
-- what OC hands back today, and which simply ignores the extra argument).
local function statusSays(status, method)
  if type(status) ~= "table" and type(status) ~= "userdata" then return false end
  local ok, res = pcall(function() return status[method] and status[method](status) end)
  return ok and res == true
end

-- Derive the label list from drillLookup rather than hardcoding a third copy of
-- these names (config.drills is the second). drillLookup already enumerates
-- every tip and rod label; we only need it in a stable order.
local drillLabels = {}   -- every tip/rod label the broker could name
for label in pairs(drillLookup) do drillLabels[#drillLabels + 1] = label end
table.sort(drillLabels)  -- deterministic display order

-- How many of `label` does the network hold right now, per this cycle's scan?
local function stockOf(assets, label)
  local key = drillLookup[label]
  if not key then return nil end
  if string.find(label, "Drill Tip", 1, true) then
    return assets.drillTips[key] or 0
  end
  return assets.drillRods[key] or 0
end

-- Not every ME controller build exposes the crafting API (verify_items.lua
-- guards the same call for the same reason). Check once at startup rather than
-- discovering it via a pcall failure on every label, every cycle.
local canCraft = (me.getCraftables ~= nil)

-- Place one crafting request. Returns the new order state.
local function requestCraft(label, amount)
  if not canCraft then
    return { state = "failed", want = amount, since = computer.uptime() }
  end
  local ok, craftables = pcall(me.getCraftables, { label = label })
  if not ok or type(craftables) ~= "table" or #craftables == 0 then
    -- No pattern in this network. Not an error we can fix from here -- it is
    -- surfaced on both dashboards so someone adds the pattern.
    return { state = "nopattern", want = amount, since = computer.uptime() }
  end

  local okReq, status = pcall(function() return craftables[1].request(amount) end)
  if not okReq or not status then
    return { state = "failed", want = amount, since = computer.uptime() }
  end
  -- AE2 can reject immediately (no CPU free, missing ingredients). That reads
  -- as an already-failed status rather than a thrown error.
  if statusSays(status, "isCanceled") or statusSays(status, "isFailed") then
    return { state = "failed", want = amount, since = computer.uptime() }
  end

  return { state = "crafting", want = amount, status = status, since = computer.uptime() }
end

-- Place an order and stamp it with the stock we saw at that instant, so the
-- settle gate has a fixed reference point to compare later scans against.
local function placeOrder(label, have, amount)
  local o = requestCraft(label, amount)
  o.baseStock = have
  return o
end

-- One pass: retire finished orders, then order anything still below par.
local function stepOrders(assets)
  local now = computer.uptime()

  -- Retire first, so a craft that just landed frees its label for a re-order in
  -- this same pass instead of waiting a full cycle.
  for label, o in pairs(orders) do
    if o.state == "crafting" then
      if statusSays(o.status, "isDone") then
        orders[label] = nil
        settle[label] = { stock = o.baseStock, expires = now + SETTLE_MAX }
      elseif statusSays(o.status, "isCanceled")
        or statusSays(o.status, "isFailed")
        or (now - o.since) > ORDER_TIMEOUT then
        -- Nothing was delivered, so no settle window: re-order immediately if
        -- the deficit is still real. A timed-out order is a presumed-dead status
        -- handle, which is precisely the case we want to retry.
        orders[label] = nil
      end
    elseif (now - o.since) > RETRY_INTERVAL then
      -- "nopattern"/"failed" are advisory, not sticky. Clearing them here lets
      -- the ordering pass below re-evaluate, which is how adding a pattern in
      -- game resolves the warning without restarting this node.
      orders[label] = nil
    end
  end

  for _, label in ipairs(drillLabels) do
    local have = stockOf(assets, label)

    local s = settle[label]
    if s and (have ~= s.stock or now > s.expires) then
      settle[label] = nil
      s = nil
    end

    local target = par[label]
    if target and target > 0 and not orders[label] and not s then
      if have and have < target then
        orders[label] = placeOrder(label, have, target - have)
      end
    end
  end
end

local function drawStaticFrame()
  term.clear()
  gpu.setForeground(0x00FF00)
  print("================================================================================")
  print(" MEDINA RELAY NETWORK  |  NODE: " .. nodeName)
  print("================================================================================")
  gpu.setForeground(0xFFFFFF)
  term.setCursor(2, 5)  io.write("DRONE FLEET STATUS")
  term.setCursor(40, 5) io.write("DRILL KIT AVAILABILITY")
  term.setCursor(2, 6)  io.write(string.rep("-", 76))

  gpu.setForeground(0xFFFFFF)
  term.setCursor(2, 16)  io.write("RESTOCK QUEUE (auto-craft to broker par)")
  term.setCursor(2, 17)  io.write(string.rep("-", 76))

  gpu.setForeground(0x555555)
  term.setCursor(2, 22) io.write(string.rep("=", 76))
  term.setCursor(2, 23) io.write("  Wireless Signal Range: " .. tostring(modem.getStrength()) .. " blocks")
  term.setCursor(2, 24) io.write("  Network Port: 2026")
end

-- Reads items directly from ME network via controller
local function scanAssets()
  local assets = { drones={}, drillTips={}, drillRods={} }

  -- Query all items in the ME network
  local success, itemList = pcall(me.getItemsInNetwork)
  if not success or not itemList then return assets end

  for _, item in ipairs(itemList) do
    if item.label then
      if string.find(item.label, "Mining Drone", 1, true) then
        assets.drones[item.label] = (assets.drones[item.label] or 0) + item.size
      elseif drillLookup[item.label] then
        local key = drillLookup[item.label]
        if string.find(item.label, "Drill Tip", 1, true) then
          assets.drillTips[key] = (assets.drillTips[key] or 0) + item.size
        elseif string.find(item.label, "Rod", 1, true) then
          assets.drillRods[key] = (assets.drillRods[key] or 0) + item.size
        end
      end
    end
  end

  return assets
end

local function updateDashboard(assets)
  -- Drone column (left, rows 7-20)
  local totalDrones = 0
  for i, key in ipairs(droneKeys) do
    local label = droneNames[key]
    local count = assets.drones[label] or 0
    totalDrones = totalDrones + count
    local row = 6 + i
    term.setCursor(2, row)
    gpu.fill(2, row, 36, 1, " ")
    gpu.setForeground(count > 0 and 0x00FFFF or 0x555555)
    -- Display drone model with voltage tier
    -- Labels carry a voltage suffix; show just the MK-N model, tier is its own column.
    local voltage = droneVoltages[key]
    local model   = string.match(label, "MK%-[XVI]+") or label
    io.write(string.format("  %-14s [%s]: %d", model, voltage, count))
  end

  -- Drill column (right, rows 7-15)
  for i, key in ipairs(drillKeyOrder) do
    local tips = assets.drillTips[key] or 0
    local rods = assets.drillRods[key] or 0
    local kits = math.min(tips, rods)
    local displayName = drillDisplayNames[key]
    local row = 6 + i
    term.setCursor(40, row)
    gpu.fill(40, row, 38, 1, " ")
    if totalDrones > 0 then
      gpu.setForeground(kits > 0 and 0xFF00FF or 0x555555)
      -- Display kits with individual tip and rod counts
      io.write(string.format("  %-15s: %d (%d|%d)", displayName, kits, tips, rods))
    else
      gpu.setForeground(0x333333)
      io.write("  [ NO FLEET — MASKED ]")
    end
  end

  -- Restock queue (rows 18-21). The drill column above ends at row 15 and the
  -- footer starts at 22, so this fits without moving anything that was there.
  local qRow = 18
  for _, label in ipairs(drillLabels) do
    local o = orders[label]
    if o then
      if qRow > 21 then break end
      gpu.fill(2, qRow, 76, 1, " ")
      term.setCursor(2, qRow)
      local short = label:gsub(" Drill Tip$", " TIP"):gsub(" Rod$", " ROD")
      if o.state == "crafting" then
        gpu.setForeground(0xFFAA00)
        io.write(string.format("  %-30s crafting x%d", short, o.want or 0))
      else
        gpu.setForeground(0xFF4444)
        io.write(string.format("  %-30s %s", short,
          o.state == "nopattern" and "NO CRAFTING PATTERN" or "REQUEST FAILED"))
      end
      qRow = qRow + 1
    end
  end
  if qRow == 18 then
    gpu.fill(2, qRow, 76, 1, " ")
    term.setCursor(2, qRow)
    gpu.setForeground(0x555555)
    -- Distinguish "at par" from "no par received": a broker that is down or on
    -- a stale config would otherwise look identical to a fully stocked network.
    io.write(next(par) and "  All drill consumables at par." or "  Awaiting par levels from broker...")
    qRow = qRow + 1
  end
  for r = qRow, 21 do gpu.fill(2, r, 76, 1, " ") end

  gpu.setForeground(0x555555)
  term.setCursor(55, 2)
  io.write("LAST_SYNC: " .. os.date("%X"))
end

drawStaticFrame()

local lastAssets = { drones={}, drillTips={}, drillRods={} }

-- Helper to build payload from assets
local function buildPayload(assets)
  local payload = { drones={}, drills={} }
  for _, key in ipairs(droneKeys) do
    local count = assets.drones[droneNames[key]] or 0
    if count > 0 then payload.drones[key] = count end
  end
  for _, key in ipairs(drillKeyOrder) do
    local tips = assets.drillTips[key] or 0
    local rods = assets.drillRods[key] or 0
    local kits = math.min(tips, rods)
    if kits > 0 then payload.drills[key] = { kits=kits, tips=tips, rods=rods } end
  end
  -- Ride the existing HW_UPDATE rather than opening a second channel: the broker
  -- already parses this message, so restock state costs no new listener. Only
  -- outstanding orders are included, so in the steady state (everything at par)
  -- this field is absent and the packet is exactly the size it always was.
  local crafting, any = {}, false
  for label, o in pairs(orders) do
    crafting[label] = { want = o.want, state = o.state }
    any = true
  end
  if any then payload.crafting = crafting end
  return payload
end

while true do
  -- Scan the ME network for current inventory
  lastAssets = scanAssets()
  -- Order before drawing and before building the payload, so both reflect this
  -- cycle's decisions rather than lagging one iteration behind.
  stepOrders(lastAssets)
  updateDashboard(lastAssets)

  -- Build and broadcast periodic HW_UPDATE
  local payload = buildPayload(lastAssets)
  modem.broadcast(2026, serialization.serialize({
    protocol    = "MEDINA_TELEMETRY",
    sender      = nodeName,
    payloadType = "HW_UPDATE",
    data        = payload
  }))

  -- Listen for Ctrl+C or HW_QUERY requests (non-blocking, 10s timeout)
  local ev = { event.pull(10, "key_down", "modem_message") }
  if ev[1] == "key_down" and ev[3] == 3 then -- Ctrl+C
    term.clear()
    os.exit()
  elseif ev[1] == "modem_message" then
    -- Query received on port 2025
    local _, _, senderAddr, port, _, rawMsg = table.unpack(ev)
    if port == 2025 then
      local ok, msg = pcall(serialization.unserialize, rawMsg)
      if ok and msg and msg.protocol == "MEDINA_COMMAND" then
        if msg.payloadType == "HW_QUERY" then
          -- Respond immediately with current inventory
          local payload = buildPayload(lastAssets)
          modem.send(senderAddr, 2025, serialization.serialize({
            protocol    = "MEDINA_TELEMETRY",
            sender      = nodeName,
            payloadType = "HW_QUERY_RESPONSE",
            data        = payload
          }))
        elseif msg.payloadType == "DRILL_PAR" and type(msg.data) == "table" then
          -- Replace, do not merge: the broker sends the complete par table, so
          -- assignment is what lets a material you removed from config.drillPar
          -- actually stop being ordered.
          par = msg.data
        end
      end
    end
  end
end
