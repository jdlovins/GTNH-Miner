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
-- Only 2025 is opened. modem.open() is what makes a port RECEIVE; broadcasting
-- needs nothing opened, which is why the dust and fluid nodes have always sent
-- on 2026 while opening only their command port.
--
-- This node used to open 2026 as well, labelled "telemetry: this node ->
-- broker" -- which is the misconception. The effect was that every DUST_UPDATE,
-- HW_UPDATE and FLUID_UPDATE broadcast in the fleet was queued as an event
-- here, woke the loop out of event.pull, and was thrown away on the port check
-- below. That is the irregular-cadence problem described in the header note:
-- the traffic waking this loop was traffic it had asked for by mistake.
--
-- Nothing is sent TO this node on 2026, so nothing is lost. If that ever
-- changes, open it deliberately and add a payloadType guard with it.
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
--  2. This loop does not tick on a reliable period. event.pull(10, ...) returns
--     early on any modem traffic on an OPEN port, plus key presses. It used to
--     be far worse: this node also opened 2026, so all three telem nodes'
--     continuous broadcasts woke it. That open was unnecessary -- sending does
--     not require it -- and is gone, leaving only the broker's occasional
--     DRILL_PAR on 2025. Iterations are still not evenly spaced, so every rate
--     limit here remains wall-clock (computer.uptime()), never a loop counter.
-- =============================================================================

-- label -> { min, batch }, as last published by the broker. Empty until it
-- speaks, and an empty table means "order nothing" -- with no broker on the air
-- this node behaves exactly as it did before auto-crafting existed.
--
-- `min` is the floor that triggers a craft; `batch` is how much we then ask for.
-- They are separate on purpose: requesting the shortfall meant a material a
-- little under its floor produced a token request that tied up a crafting CPU
-- for almost nothing.
local par = {}

-- How many crafts we may have in flight at once, published alongside par.
-- AE2 cancels a request outright when no CPU is free, so firing every shortfall
-- at a one-CPU network starts one craft and gets the rest rejected -- which is
-- indistinguishable from a broken pattern unless we simply do not ask.
local slots = 1

-- label -> shortfall, for materials below par that are waiting on a free slot.
-- Deliberately not in `orders`: nothing has been requested for these.
local queued = {}

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
--
-- Only applies to a handle that has STOPPED ANSWERING -- see statusAlive. A
-- craft still reporting its state is left alone however long it takes.
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

-- Does this handle still answer at all?
--
-- statusSays cannot tell "the craft says it is not done" from "the handle is
-- dead and threw" -- both come back false. The timeout below needs exactly that
-- difference. A craft that is merely TAKING a long time must not be retired,
-- because retiring it re-orders on top of a craft that is still running, and a
-- large batch of drill tips can easily outlast a ten minute timeout.
--
-- That duplicate used to be invisible: with every CPU busy AE2 rejected the
-- second request and it showed as one red line. Free up a CPU and the duplicate
-- is accepted instead, and the same batch gets crafted twice.
local function statusAlive(status)
  if type(status) ~= "table" and type(status) ~= "userdata" then return false end
  return (pcall(function() return status.isDone and status.isDone(status) end))
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

-- Pick the craftable that actually IS `label` out of what getCraftables handed
-- back, rather than trusting the first entry.
--
-- The filter is a hint, not a guarantee: with a Pattern Repeater joining another
-- network's patterns to this one, an unhonoured filter returns every craftable
-- in both networks -- and craftables[1] is then some unrelated item that we
-- would happily order thousands of. Matching on the stack's own label costs one
-- pass over a list we already have.
local function pickCraftable(craftables, label)
  for i = 1, #craftables do
    local c = craftables[i]
    local ok, stack = pcall(function() return c.getItemStack and c.getItemStack() end)
    if ok and type(stack) == "table" and stack.label == label then return c end
  end
  -- No entry exposed a label to check against. A single result came back from a
  -- query for this label and there is nothing to confuse it with, so use it;
  -- anything ambiguous is treated as "no pattern" instead of guessed at.
  if #craftables == 1 then return craftables[1] end
  return nil
end

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

  local craftable = pickCraftable(craftables, label)
  craftables = nil
  if not craftable then
    return { state = "nopattern", want = amount, since = computer.uptime() }
  end

  local okReq, status = pcall(function() return craftable.request(amount) end)
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
      elseif statusSays(o.status, "isCanceled") or statusSays(o.status, "isFailed") then
        -- Nothing was delivered, so no settle window: re-order immediately if
        -- the deficit is still real.
        orders[label] = nil
      elseif (now - o.since) > ORDER_TIMEOUT and not statusAlive(o.status) then
        -- Presumed-dead handle, which is the case the timeout was written for:
        -- AE2 status objects do not survive every network hiccup, and without
        -- this one lost handle would wedge a material permanently.
        --
        -- The aliveness check is what keeps it from ALSO retiring healthy but
        -- slow crafts. Time alone was never evidence a craft had died.
        orders[label] = nil
      end
    elseif (now - o.since) > RETRY_INTERVAL then
      -- "nopattern"/"failed" are advisory, not sticky. Clearing them here lets
      -- the ordering pass below re-evaluate, which is how adding a pattern in
      -- game resolves the warning without restarting this node.
      orders[label] = nil
    end
  end

  -- Collect every shortfall first, then spend the available slots on the worst
  -- ones. Deciding in label order would let an alphabetically early material
  -- monopolise the only CPU while something nearly empty waits.
  local short = {}
  for _, label in ipairs(drillLabels) do
    local have = stockOf(assets, label)

    local s = settle[label]
    if s and (have ~= s.stock or now > s.expires) then
      settle[label] = nil
      s = nil
    end

    local target = par[label]
    local floor  = target and target.min or 0
    if target and floor > 0 and not orders[label] and not s and have and have < floor then
      short[#short + 1] = {
        label = label,
        have  = have,
        -- A whole batch, not the shortfall. Overshooting the floor is the
        -- intended trade -- see the config.drillPar comment.
        need  = target.batch or floor,
        ratio = have / floor,
      }
    end
  end

  -- Emptiest first; label as a tie-break so the order is stable frame to frame.
  table.sort(short, function(a, b)
    if a.ratio ~= b.ratio then return a.ratio < b.ratio end
    return a.label < b.label
  end)

  local inFlight = 0
  for _, o in pairs(orders) do
    if o.state == "crafting" then inFlight = inFlight + 1 end
  end

  queued = {}
  for _, item in ipairs(short) do
    if inFlight < slots then
      local o = placeOrder(item.label, item.have, item.need)
      orders[item.label] = o
      -- Only a live craft consumes a slot. A nopattern/failed result did not
      -- occupy a CPU, so it must not block the next material from trying.
      if o.state == "crafting" then inFlight = inFlight + 1 end
    else
      queued[item.label] = item.need
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

  -- Right column only (x=40+). The drone list occupies rows 7-20 on the left,
  -- so anything full-width here gets erased by it.
  gpu.setForeground(0xFFFFFF)
  term.setCursor(40, 16) io.write("RESTOCK (auto-craft to par)")

  gpu.setForeground(0x555555)
  term.setCursor(2, 22) io.write(string.rep("=", 76))
  term.setCursor(2, 23) io.write("  Wireless Signal Range: " .. tostring(modem.getStrength()) .. " blocks")
  term.setCursor(2, 24) io.write("  Network Port: 2026")
end

-- OpenComputers' sandbox does not hand the Lua `collectgarbage` global to the
-- script -- the host decides when to collect -- so calling it directly kills
-- the node with "attempt to call a nil value". Bind it where it exists and
-- no-op where it does not: every call below is a hint that now is a good
-- moment, never something the logic depends on.
local gc = type(collectgarbage) == "function" and collectgarbage or function() end

-- =============================================================================
-- NETWORK SCAN
--
-- me.getItemsInNetwork() with no filter materialises EVERY stack in the network
-- as its own Lua table, in one allocation. That was fine on a standalone
-- staging network, but a Pattern Repeater grafts another network's contents
-- onto this one and the list grows with it -- tens of thousands of entries,
-- each a table of label/name/damage/size/nbt. This machine's heap is a couple
-- of hundred kilobytes, so the list alone no longer fits and the node died with
-- "not enough memory" before it could read a single count.
--
-- This node only ever cares about the 32 exact labels below, so ask for them by
-- name. A filtered query is matched on the Java side and hands back a handful
-- of entries, which makes peak memory a function of what we track rather than
-- of how large the ME network happens to be.
-- =============================================================================

-- Every label worth asking about, and where its count belongs in `assets`.
-- Built from the tables above so there is still exactly one list of names.
local scanTargets = {}
for _, key in ipairs(droneKeys) do
  local label = droneNames[key]
  -- assets.drones is keyed by full label (updateDashboard looks it up that way).
  scanTargets[#scanTargets + 1] = { label = label, bucket = "drones", key = label }
end
for _, label in ipairs(drillLabels) do
  local bucket = string.find(label, "Drill Tip", 1, true) and "drillTips" or "drillRods"
  scanTargets[#scanTargets + 1] = { label = label, bucket = bucket, key = drillLookup[label] }
end

-- More entries than any single label could plausibly occupy. A filtered query
-- that comes back bigger than this was not filtered at all.
local FILTER_SANE_MAX = 64

-- Total network count for one exact label, or nil if the query failed.
local function countLabel(label)
  local ok, items = pcall(me.getItemsInNetwork, { label = label })
  if not ok or type(items) ~= "table" then return nil end
  local total = 0
  for i = 1, #items do
    local it = items[i]
    -- Re-check the label rather than trusting the filter. It is compared field
    -- by field on the Java side and a loose or ignored match would otherwise
    -- fold unrelated items into this count; an exact test costs one comparison.
    if type(it) == "table" and it.label == label then
      total = total + (it.size or 0)
    end
  end
  return total
end

-- Is the filter actually honoured here? Decided once, at startup.
--
-- If it is not, a filtered call still returns the whole network -- and doing
-- that 32 times a cycle is far worse than the single unfiltered pass we are
-- replacing. So probe once and fall back to one full scan per cycle if the
-- device ignores us.
local useFilter = false
do
  local ok, items = pcall(me.getItemsInNetwork, { label = drillLabels[1] })
  useFilter = ok and type(items) == "table" and #items <= FILTER_SANE_MAX
  items = nil
  gc()
end

-- Why the counts look the way they do, for the status line. A failed query and
-- an empty network are indistinguishable on the board otherwise.
local scanState = { ok = true, mode = useFilter and "filtered" or "full", err = nil }

local function newAssets()
  return { drones = {}, drillTips = {}, drillRods = {} }
end

-- 32 small queries. Returns nil if any of them failed: a partial scan reads as
-- "the network is empty", and ordering against that would fire a craft for
-- every material at once.
local function scanFiltered()
  local assets = newAssets()
  for _, t in ipairs(scanTargets) do
    local n = countLabel(t.label)
    if not n then
      scanState = { ok = false, mode = "filtered", err = "query failed: " .. t.label }
      return nil
    end
    if n > 0 then assets[t.bucket][t.key] = (assets[t.bucket][t.key] or 0) + n end
  end
  scanState = { ok = true, mode = "filtered", err = nil }
  return assets
end

-- Fallback for a device that ignores the filter: the original whole-network
-- pass, which is what runs out of memory on a repeated network. Collect first
-- so the previous cycle's garbage is not still holding the heap when the list
-- lands, and treat the failure as a failed scan instead of letting it kill the
-- node -- a dashboard reporting "SCAN FAILED" is far more use than a dead one.
local function scanFull()
  gc()
  local assets = newAssets()

  local success, itemList = pcall(me.getItemsInNetwork)
  if not success or not itemList then
    scanState = { ok = false, mode = "full",
                  err = success and "returned nothing" or tostring(itemList) }
    return nil
  end

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

  -- Drop the list before anything else allocates against it.
  itemList = nil
  gc()
  scanState = { ok = true, mode = "full", err = nil }
  return assets
end

-- Reads items directly from ME network via controller.
-- nil means "this cycle's numbers are not trustworthy" -- the caller keeps the
-- previous snapshot rather than acting on a blank one.
local function scanAssets()
  if useFilter then return scanFiltered() end
  return scanFull()
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

  -- Restock queue: right column (x=40, width 38), rows 17-21.
  --
  -- This has to live under the DRILL column, not across the screen. The drone
  -- loop above owns rows 7-20 on the left and clears x=2..37 on every one of
  -- them, so a full-width block here is partly erased on each repaint. The
  -- drill column stops at row 15, which is what leaves 16-21 free on the right.
  local QX, QW = 40, 38

  -- Failures first: they are the entries a human has to act on, so if there are
  -- more orders than rows, the benign "crafting" lines are the ones to lose.
  -- state -> sort rank and colour. Failures first (a human has to act on them),
  -- then live crafts, then things merely waiting on a slot. If there are more
  -- entries than rows, the ones that get cut are the ones nobody needs to see.
  local RANK  = { nopattern = 0, failed = 0, crafting = 1, queued = 2 }
  local COLOR = { nopattern = 0xFF4444, failed = 0xFF4444,
                  crafting  = 0xFFAA00, queued = 0x555555 }

  local view = {}
  for _, label in ipairs(drillLabels) do
    local o = orders[label]
    if o then
      view[#view + 1] = { label = label, state = o.state, want = o.want }
    elseif queued[label] then
      view[#view + 1] = { label = label, state = "queued", want = queued[label] }
    end
  end
  table.sort(view, function(a, b)
    local ra, rb = RANK[a.state] or 3, RANK[b.state] or 3
    if ra ~= rb then return ra < rb end
    return a.label < b.label
  end)
  local pending = view

  local qRow, QLAST = 17, 21
  local WORD = { nopattern = "NO PATTERN", failed = "REJECTED", queued = "queued" }
  for i, e in ipairs(pending) do
    if qRow > QLAST then break end
    gpu.fill(QX, qRow, QW, 1, " ")
    term.setCursor(QX, qRow)
    -- More entries than rows: spend the last line on a count rather than
    -- showing one more and silently hiding the rest.
    if qRow == QLAST and #pending > i then
      gpu.setForeground(0x555555)
      io.write(string.format("  ...and %d more", #pending - i + 1))
    else
      local short = e.label:gsub(" Drill Tip$", " TIP"):gsub(" Rod$", " ROD")
      gpu.setForeground(COLOR[e.state] or 0xFF4444)
      if e.state == "crafting" then
        io.write(string.format("  %-22s x%d", short, e.want or 0))
      elseif e.state == "queued" then
        io.write(string.format("  %-22s queued x%d", short, e.want or 0))
      else
        io.write(string.format("  %-22s %s", short, WORD[e.state] or "FAILED"))
      end
    end
    qRow = qRow + 1
  end

  if #pending == 0 then
    gpu.fill(QX, qRow, QW, 1, " ")
    term.setCursor(QX, qRow)
    gpu.setForeground(0x555555)
    -- Distinguish "at par" from "no par received": a broker that is down or on
    -- a stale config would otherwise look identical to a fully stocked network.
    io.write(next(par) and "  All at par." or "  Awaiting par from broker...")
    qRow = qRow + 1
  end
  for r = qRow, QLAST do gpu.fill(QX, r, QW, 1, " ") end

  -- Scan health, bottom of the LEFT column. Row 21 is the one line there the
  -- drone list (rows 7-20) does not repaint over, and the restock block owns
  -- the right half of it. Free memory is on show because this node's failure
  -- mode is running out of it -- a repeated network can grow the item list
  -- without anything else on screen changing.
  gpu.fill(2, 21, 36, 1, " ")
  term.setCursor(2, 21)
  if scanState.ok then
    gpu.setForeground(0x555555)
    io.write(string.format("  scan %s  free %dk",
      scanState.mode, math.floor(computer.freeMemory() / 1024)))
  else
    gpu.setForeground(0xFF4444)
    io.write(string.sub("  SCAN FAILED: " .. (scanState.err or "?"), 1, 36))
  end

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
  for label, need in pairs(queued) do
    crafting[label] = { want = need, state = "queued" }
    any = true
  end
  if any then payload.crafting = crafting end
  return payload
end

while true do
  -- Scan the ME network for current inventory. A failed scan keeps the previous
  -- snapshot and skips ordering: a half-read network looks like an empty one,
  -- and ordering against that would fire a craft for every material at once.
  local assets = scanAssets()
  if assets then
    lastAssets = assets
    -- Order before drawing and before building the payload, so both reflect
    -- this cycle's decisions rather than lagging one iteration behind.
    stepOrders(lastAssets)
  end
  updateDashboard(lastAssets)

  -- Build and broadcast periodic HW_UPDATE
  local payload = buildPayload(lastAssets)
  modem.broadcast(2026, serialization.serialize({
    protocol    = "MEDINA_TELEMETRY",
    sender      = nodeName,
    payloadType = "HW_UPDATE",
    data        = payload
  }))

  -- Hand the cycle's garbage back before parking in event.pull. The scan and
  -- the serialized packet are the two large allocations here, and collecting
  -- them while we are idle anyway keeps the heap floor steady instead of
  -- letting it drift up until an unlucky cycle has nowhere to allocate.
  payload = nil
  gc()

  -- Listen for Ctrl+C or broker commands (10s timeout).
  --
  -- No name filter. event.pull(timeout, name, ...) matches `name` against the
  -- SIGNAL NAME and every argument after it against the signal's PARAMETERS --
  -- it is not an either/or list. The old call here was
  --   event.pull(10, "key_down", "modem_message")
  -- which asks for a key_down whose first parameter is the string
  -- "modem_message", and therefore never matched anything. This node could not
  -- receive a modem message at all, which is why HW_QUERY never worked and why
  -- Ctrl+C did not quit. dust_telem.lua:212 has it right with a single filter.
  --
  -- Pulling everything (like broker-mk3.lua does) keeps both branches working.
  -- Unrelated signals just wake the loop early, which is harmless: the body is
  -- idempotent and every rate limit here is wall-clock, not per-iteration.
  local ev = { event.pull(10) }
  if ev[1] == "key_down" and ev[3] == 3 then -- Ctrl+C
    term.clear()
    os.exit()
  elseif ev[1] == "modem_message" then
    -- Query received on port 2025
    local _, _, senderAddr, port, _, rawMsg = table.unpack(ev)
    -- Belt and braces now that 2026 is not opened: nothing else should reach
    -- this node, and the two payload types that do are both wanted, so there is
    -- no string guard here of the kind dust_telem and fluid_telem carry. The
    -- port check already does that job, more cheaply and more exactly.
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
        elseif msg.payloadType == "DRILL_PAR" and type(msg.data) == "table"
               and type(msg.data.par) == "table" then
          -- data.par is label -> { min, batch }.
          -- Replace, do not merge: the broker sends the complete par table, so
          -- a material it stopped publishing -- because you removed it from
          -- config.drillPar, or because you no longer hold a drone that uses
          -- it -- actually stops being ordered.
          par = msg.data.par
          -- Absent-value fallback, not the shipped default (config sets 2).
          -- A broker that does not tell us the CPU count gets the conservative
          -- answer: too few slots is slow, too many is rejected requests.
          slots = tonumber(msg.data.slots) or 1
          if slots < 1 then slots = 1 end
        end
      end
    end
  end
end
