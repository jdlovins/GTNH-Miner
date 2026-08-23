-- config.lua
-- Space Mining Automation — Master Configuration
-- Data validated against the GTNH Wiki and the Space Elevator Calculator spreadsheet.
-- Item names confirmed against live in-game ME network tooltips.

local config = {}

-- Helper: convert k/m/b suffixes to numbers (e.g. 100k=100000, 1m=1000000, 1b=1000000000)
local function qty(s)
  if type(s) == "number" then return s end
  local num, suffix = string.match(s, "^(%d+%.?%d*)([kmb]?)$")
  if not num then return tonumber(s) or 0 end
  num = tonumber(num)
  if suffix == "k" then
    return num * 1000
  elseif suffix == "m" then
    return num * 1000000
  elseif suffix == "b" then
    return num * 1000000000
  else
    return num
  end
end

--------------------------------------------------------------------------------
-- 1. DRONE REGISTRY
-- Maps short tier keys (lv, mv, ... uxv) to the exact item name as reported
-- by the ME network. Used by hw_telem for inventory scanning and by job_node
-- when requesting items via transposer.
--------------------------------------------------------------------------------
config.drones = {
  lv  = "Mining Drone MK-I (LV)",
  mv  = "Mining Drone MK-II (MV)",
  hv  = "Mining Drone MK-III (HV)",
  ev  = "Mining Drone MK-IV (EV)",
  iv  = "Mining Drone MK-V (IV)",
  luv = "Mining Drone MK-VI (LuV)",
  zpm = "Mining Drone MK-VII (ZPM)",
  uv  = "Mining Drone MK-VIII (UV)",
  uhv = "Mining Drone MK-IX (UHV)",
  uev = "Mining Drone MK-X (UEV)",
  uiv = "Mining Drone MK-XI (UIV)",
  umv = "Mining Drone MK-XII (UMV)",
  uxv = "Mining Drone MK-XIII (UXV)",
  max = "Mining Drone MK-XIV (MAX)"
}

-- Iteration order for best-available drone selection (highest tier first).
-- Broker walks this list and picks the first tier that is both in stock
-- and within the target asteroid's [minDrone, maxDrone] range.
config.droneKeyOrder = {
  "max", "uxv", "umv", "uiv", "uev", "uhv", "uv", "zpm", "luv", "iv", "ev", "hv", "mv", "lv"
}

-- Reverse map: drone key → numeric tier for minDrone/maxDrone range comparisons.
config.droneTierKeys = {
  lv = 1,
  mv = 2,
  hv = 3,
  ev = 4,
  iv = 5,
  luv = 6,
  zpm = 7,
  uv = 8,
  uhv = 9,
  uev = 10,
  uiv = 11,
  umv = 12,
  uxv = 13,
  max = 14
}

--------------------------------------------------------------------------------
-- 2. DRILL CONSUMABLES
-- Each recipe cycle consumes 4x Drill Tips + 4x Rods per parallel. The
-- required material is determined by the drone tier in use. job_node looks
-- up config.droneDrillMap[tier] to get the key, then reads this table for
-- the exact ME item names to pull via transposer.
--------------------------------------------------------------------------------
config.drills = {
  steel             = { tip = "Steel Drill Tip", rod = "Steel Rod" },
  titanium          = { tip = "Titanium Drill Tip", rod = "Titanium Rod" },
  tungstensteel     = { tip = "Tungstensteel Drill Tip", rod = "Tungstensteel Rod" },
  naquadah          = { tip = "Naquadah Drill Tip", rod = "Naquadah Rod" },
  naquadahAlloy     = { tip = "Naquadah Alloy Drill Tip", rod = "Naquadah Alloy Rod" },
  neutronium        = { tip = "Neutronium Drill Tip", rod = "Neutronium Rod" },
  cosmicNeutronium  = { tip = "Cosmic Neutronium Drill Tip", rod = "Cosmic Neutronium Rod" },
  infinity          = { tip = "Infinity Drill Tip", rod = "Infinity Rod" },
  transcendentMetal = { tip = "Transcendent Metal Drill Tip", rod = "Transcendent Metal Rod" }
}

--------------------------------------------------------------------------------
-- 2b. ITEM REGISTRY (internal names for db.set)
-- GTNH 2.9 broke iface.store(); we now write fingerprints via db.set(slot,
-- registryName, damage). These tables map config keys to the Minecraft internal
-- item name + damage value. Scan new items with scan_items.lua to get values.
--------------------------------------------------------------------------------
config.droneRegistry = {
  lv  = { name = "gtnhintergalactic:item.MiningDrone", damage = 0 },
  mv  = { name = "gtnhintergalactic:item.MiningDrone", damage = 1 },
  hv  = { name = "gtnhintergalactic:item.MiningDrone", damage = 2 },
  ev  = { name = "gtnhintergalactic:item.MiningDrone", damage = 3 },
  iv  = { name = "gtnhintergalactic:item.MiningDrone", damage = 4 },
  luv = { name = "gtnhintergalactic:item.MiningDrone", damage = 5 },
  zpm = { name = "gtnhintergalactic:item.MiningDrone", damage = 6 },
  uv  = { name = "gtnhintergalactic:item.MiningDrone", damage = 7 },
  uhv = { name = "gtnhintergalactic:item.MiningDrone", damage = 8 },
  uev = { name = "gtnhintergalactic:item.MiningDrone", damage = 9 },
  uiv = { name = "gtnhintergalactic:item.MiningDrone", damage = 10 },
  umv = { name = "gtnhintergalactic:item.MiningDrone", damage = 11 },
  uxv = { name = "gtnhintergalactic:item.MiningDrone", damage = 12 },
  max = { name = "gtnhintergalactic:item.MiningDrone", damage = 13 },
}

config.drillRegistry = {
  steel         = {
    tip = { name = "gregtech:gt.metaitem.02", damage = 8305 },
    rod = { name = "gregtech:gt.metaitem.01", damage = 23305 }
  },
  titanium      = {
    tip = { name = "gregtech:gt.metaitem.02", damage = 8028 },
    rod = { name = "gregtech:gt.metaitem.01", damage = 23028 }
  },
  tungstensteel = {
    tip = { name = "gregtech:gt.metaitem.02", damage = 8316 },
    rod = { name = "gregtech:gt.metaitem.01", damage = 23316 }
  },
  naquadah      = {
    tip = { name = "gregtech:gt.metaitem.02", damage = 8324 },
    rod = { name = "gregtech:gt.metaitem.01", damage = 23324 }
  },
  naquadahAlloy = {
    tip = { name = "gregtech:gt.metaitem.02", damage = 8325 },
    rod = { name = "gregtech:gt.metaitem.01", damage = 23325 }
  },
  neutronium    = {
    tip = { name = "gregtech:gt.metaitem.02", damage = 8129 },
    rod = { name = "gregtech:gt.metaitem.01", damage = 23129 }
  },
  -- Missing: cosmicNeutronium, infinity, transcendentMetal.
  --
  -- This does NOT hold back those tiers. Nothing reads this table any more --
  -- the loader resolves items by LABEL via iface.store(), and tryDispatch()
  -- gates on config.drills, which has all nine materials. Tiers 11-14 dispatch
  -- and load fine without an entry here.
  --
  -- Kept because a fingerprint-based loader would need it again, but treat it
  -- as reference data, not as the list of what works.
}

-- Maps drone tier number to the drill key in config.drills above.
-- Two tiers can share a drill material (e.g. LV and MV both use steel).
config.droneDrillMap = {
  [1] = "steel",
  [2] = "steel",
  [3] = "titanium",
  [4] = "titanium",
  [5] = "tungstensteel",
  [6] = "tungstensteel",
  [7] = "naquadah",
  [8] = "naquadah",
  [9] = "naquadahAlloy",
  [10] = "neutronium",
  [11] = "cosmicNeutronium",
  [12] = "infinity",
  [13] = "transcendentMetal",
  [14] = "transcendentMetal"
}

--------------------------------------------------------------------------------
-- 3. SPACE MINING MODULE SPECIFICATIONS
-- Three tiers of Mining Module are available on the Space Elevator.
-- Parallels run the same asteroid recipe simultaneously and multiply ALL
-- inputs: EU/t, computation/s, and plasma mB consumed per cycle.
-- Draconic Core is capped at 1 parallel regardless of module tier due to
-- its extreme power draw (7,864,320 EU/t per parallel).
--------------------------------------------------------------------------------
config.moduleTiers = {
  ["MK-I"]   = { maxParallels = 2, maxPower = 245760, maxComputation = 600 },
  ["MK-II"]  = { maxParallels = 4, maxPower = 4815896, maxComputation = 1280 },
  ["MK-III"] = { maxParallels = 8, maxPower = 7864320, maxComputation = 2880 }
}

--------------------------------------------------------------------------------
-- 4. PLASMA OVERDRIVE SPECIFICATIONS
-- Plasma is a required fluid input for every mining recipe. Higher tier
-- plasmas consume less per cycle but offer greater speed and size bonuses.
--   amount   = mB consumed per cycle (multiplied by parallels)
--   tau      = time discount fraction:   Time = base * (1 - tau) / OD
--   lambda   = size bonus fraction:      B = lambda * (2.0 - OD)
--   minOD/maxOD = valid overdrive parameter range for this plasma tier
-- Higher OD = faster cycles, lower size bonus. Lower OD = slower, more ore.
--------------------------------------------------------------------------------
config.plasmas = {
  ["Helium Plasma"]        = { tier = 1, amount = 825, tau = 0.0, lambda = 0.004, minOD = 0.0, maxOD = 2.0 },
  ["Bismuth Plasma"]       = { tier = 2, amount = 550, tau = 0.1, lambda = 0.037, minOD = 0.0, maxOD = 1.8 },
  ["Radon Plasma"]         = { tier = 3, amount = 375, tau = 0.2, lambda = 0.125, minOD = 0.0, maxOD = 1.6 },
  ["Technetium Plasma"]    = { tier = 4, amount = 250, tau = 0.3, lambda = 0.296, minOD = 0.0, maxOD = 1.4 },
  ["Plutonium 241 Plasma"] = { tier = 5, amount = 150, tau = 0.4, lambda = 0.578, minOD = 0.7, maxOD = 1.2 }
}

-- Iteration order for best-available plasma selection (highest tier first).
config.plasmaKeyOrder = {
  "Plutonium 241 Plasma", "Technetium Plasma", "Radon Plasma",
  "Bismuth Plasma", "Helium Plasma"
}

--------------------------------------------------------------------------------
-- 5. CYCLE MODE DEFAULTS
-- Used when a job_node sets mode=1 (dynamic distance sweep) on a module.
-- In cycle mode the module sweeps distances between (distance - range) and
-- (distance + range), incrementing by step each pass, harvesting a wider
-- spread of asteroid types. Static mode (mode=0) locks to one distance.
--------------------------------------------------------------------------------
config.cycleDefaults = {
  defaultMode  = 0,
  defaultRange = 50,
  defaultStep  = 20
}

--------------------------------------------------------------------------------
-- 6. ASTEROID DATABASE
-- materials    = ordered list of output material names
-- weights      = parallel list of integer weights (sum = 10000)
-- minSize/maxSize = stack output range (base drone tier)
-- minDist/maxDist = valid distance parameter range
-- computation  = computation required per parallel (per second)
-- minModule    = minimum mining module tier (1=MK-I, 2=MK-II, 3=MK-III)
-- baseDuration = base recipe duration in ticks (before plasma discount)
-- euPerTick    = power draw per parallel
-- minDrone     = minimum drone tier number
-- maxDrone     = maximum drone tier number (asteroid stops existing above this)
-- weight       = spawn weight for selection probability calculation
--------------------------------------------------------------------------------
config.asteroids = {
  ["Adamantium"] = {
    materials = { "Adamantium", "Bismuth", "Antimony", "Gallium", "Lithium" },
    weights = { 2500, 2000, 2000, 2000, 1500 },
    minSize = 30,
    maxSize = 120,
    minDist = 5,
    maxDist = 120,
    computation = 20,
    minModule = 1,
    baseDuration = 500,
    euPerTick = 1920,
    minDrone = 4,
    maxDrone = 7,
    weight = 300
  },
  ["Aluminium"] = {
    materials = { "Aluminium", "Bauxite", "Rutile" },
    weights = { 5000, 3500, 1500 },
    minSize = 10,
    maxSize = 20,
    minDist = 5,
    maxDist = 20,
    computation = 20,
    minModule = 1,
    baseDuration = 50,
    euPerTick = 7680,
    minDrone = 2,
    maxDrone = 4,
    weight = 120
  },
  ["Aluminium-LanthLine"] = {
    materials = { "Aluminium", "Bauxite", "Monazite", "Bastnasite" },
    weights = { 3500, 1500, 2500, 2500 },
    minSize = 10,
    maxSize = 80,
    minDist = 40,
    maxDist = 120,
    computation = 60,
    minModule = 1,
    baseDuration = 500,
    euPerTick = 7680,
    minDrone = 2,
    maxDrone = 7,
    weight = 250
  },
  ["Ardite/Cobalt"] = {
    materials = { "Cobalt", "Ardite", "Manyullyn" },
    weights = { 3750, 3750, 2500 },
    minSize = 20,
    maxSize = 90,
    minDist = 30,
    maxDist = 100,
    computation = 180,
    minModule = 1,
    baseDuration = 1000,
    euPerTick = 7680,
    minDrone = 4,
    maxDrone = 9,
    weight = 150
  },
  ["Basic Magic"] = {
    materials = { "InfusedGold", "Shadow", "InfusedAir", "InfusedEarth", "InfusedFire", "InfusedWater", "InfusedEntropy", "InfusedOrder" },
    weights = { 3500, 3500, 500, 500, 500, 500, 500, 500 },
    minSize = 24,
    maxSize = 60,
    minDist = 8,
    maxDist = 24,
    computation = 120,
    minModule = 1,
    baseDuration = 100,
    euPerTick = 30720,
    minDrone = 3,
    maxDrone = 6,
    weight = 200
  },
  ["Blue"] = {
    materials = { "Lapis", "Calcite", "Lazurite", "Sodalite" },
    weights = { 6000, 2000, 1000, 1000 },
    minSize = 10,
    maxSize = 50,
    minDist = 20,
    maxDist = 200,
    computation = 60,
    minModule = 1,
    baseDuration = 500,
    euPerTick = 7680,
    minDrone = 3,
    maxDrone = 8,
    weight = 250
  },
  ["Cheese"] = {
    materials = { "Cheese" },
    weights = { 10000 },
    minSize = 1,
    maxSize = 30,
    minDist = 90,
    maxDist = 200,
    computation = 240,
    minModule = 2,
    baseDuration = 1000,
    euPerTick = 122880,
    minDrone = 5,
    maxDrone = 13,
    weight = 10
  },
  ["Chrome"] = {
    materials = { "Chrome", "Ruby", "Chromite" },
    weights = { 5000, 3000, 2000 },
    minSize = 16,
    maxSize = 32,
    minDist = 10,
    maxDist = 20,
    computation = 40,
    minModule = 1,
    baseDuration = 50,
    euPerTick = 30720,
    minDrone = 2,
    maxDrone = 6,
    weight = 100
  },
  ["Clay"] = {
    materials = { "Clay Block" },
    weights = { 10000 },
    minSize = 30,
    maxSize = 60,
    minDist = 20,
    maxDist = 100,
    computation = 30,
    minModule = 1,
    baseDuration = 800,
    euPerTick = 7680,
    minDrone = 1,
    maxDrone = 6,
    weight = 200
  },
  ["Coal"] = {
    materials = { "Coal", "Lignite", "Graphite" },
    weights = { 7000, 1000, 2000 },
    minSize = 30,
    maxSize = 120,
    minDist = 1,
    maxDist = 40,
    computation = 20,
    minModule = 1,
    baseDuration = 200,
    euPerTick = 1920,
    minDrone = 1,
    maxDrone = 7,
    weight = 200
  },
  ["Copper"] = {
    materials = { "Copper", "Chalcopyrite", "Malachite" },
    weights = { 5000, 3000, 2000 },
    minSize = 30,
    maxSize = 150,
    minDist = 3,
    maxDist = 12,
    computation = 10,
    minModule = 1,
    baseDuration = 200,
    euPerTick = 1920,
    minDrone = 1,
    maxDrone = 6,
    weight = 500
  },
  ["Cosmic"] = {
    materials = { "CosmicNeutronium", "Neutronium", "BlackPlutonium", "Bedrockium" },
    weights = { 2500, 2500, 2500, 2500 },
    minSize = 10,
    maxSize = 70,
    minDist = 60,
    maxDist = 100,
    computation = 240,
    minModule = 2,
    baseDuration = 500,
    euPerTick = 491520,
    minDrone = 7,
    maxDrone = 13,
    weight = 170
  },
  ["Draconic"] = {
    materials = { "Draconium", "DraconiumAwakened", "ElectrumFlux" },
    weights = { 6500, 2500, 1000 },
    minSize = 15,
    maxSize = 60,
    minDist = 60,
    maxDist = 200,
    computation = 360,
    minModule = 2,
    baseDuration = 600,
    euPerTick = 30720,
    minDrone = 6,
    maxDrone = 9,
    weight = 190
  },
  ["Draconic Core"] = {
    materials = { "Draconic Core Blueprint", "Draconic Core", "Zero Point Module (Empty)" },
    weights = { 100, 100, 9800 },
    minSize = 1,
    maxSize = 1,
    minDist = 50,
    maxDist = 200,
    computation = 1000,
    minModule = 3,
    baseDuration = 2000,
    euPerTick = 7864320,
    minDrone = 9,
    maxDrone = 11,
    weight = 1
  },
  ["Europium"] = {
    materials = { "Ledox", "CallistoIce", "Borax", "Europium" },
    weights = { 4000, 4000, 1500, 500 },
    minSize = 40,
    maxSize = 120,
    minDist = 40,
    maxDist = 60,
    computation = 240,
    minModule = 2,
    baseDuration = 1000,
    euPerTick = 122880,
    minDrone = 7,
    maxDrone = 13,
    weight = 150
  },
  ["Everglades"] = {
    materials = { "Koboldite", "Crocoite", "GadoliniteY", "Lepersonnite", "Zircon", "Lautarite", "Honeaite", "Alburnite", "RareEarthI", "RareEarthII", "RareEarthIII" },
    weights = { 600, 400, 1500, 1500, 1000, 400, 1000, 600, 1000, 1000, 1000 },
    minSize = 10,
    maxSize = 20,
    minDist = 110,
    maxDist = 230,
    computation = 200,
    minModule = 1,
    baseDuration = 500,
    euPerTick = 7680,
    minDrone = 7,
    maxDrone = 9,
    weight = 100
  },
  ["Gem Ores"] = {
    materials = { "Ruby", "Emerald", "Sapphire", "GreenSapphire", "Diamond", "Opal", "Topaz", "BlueTopaz", "Bauxite", "Vinteum", "NetherStar" },
    weights = { 1500, 1500, 1500, 1500, 750, 750, 1000, 500, 500, 400, 100 },
    minSize = 30,
    maxSize = 160,
    minDist = 17,
    maxDist = 40,
    computation = 60,
    minModule = 1,
    baseDuration = 100,
    euPerTick = 30720,
    minDrone = 1,
    maxDrone = 6,
    weight = 180
  },
  ["Holmium/Samarium"] = {
    materials = { "Holmium", "Samarium", "Tiberium", "Strontium" },
    weights = { 2000, 3000, 3000, 2000 },
    minSize = 15,
    maxSize = 50,
    minDist = 40,
    maxDist = 80,
    computation = 260,
    minModule = 2,
    baseDuration = 500,
    euPerTick = 30720,
    minDrone = 8,
    maxDrone = 13,
    weight = 75
  },
  ["Ichorium"] = {
    materials = { "ShadowIron", "MeteoricIron", "Ichorium", "Desh", "Americium" },
    weights = { 4500, 3000, 1500, 500, 500 },
    minSize = 30,
    maxSize = 120,
    minDist = 70,
    maxDist = 100,
    computation = 320,
    minModule = 3,
    baseDuration = 1000,
    euPerTick = 491520,
    minDrone = 10,
    maxDrone = 13,
    weight = 150
  },
  ["Indium"] = {
    materials = { "Indium", "Sphalerite", "Zinc", "Cadmium" },
    weights = { 6000, 2000, 1000, 1000 },
    minSize = 30,
    maxSize = 120,
    minDist = 50,
    maxDist = 90,
    computation = 120,
    minModule = 2,
    baseDuration = 500,
    euPerTick = 30720,
    minDrone = 5,
    maxDrone = 10,
    weight = 170
  },
  ["Infinity Catalyst"] = {
    materials = { "InfinityCatalyst", "CosmicNeutronium", "Neutronium" },
    weights = { 5000, 3000, 2000 },
    minSize = 30,
    maxSize = 120,
    minDist = 70,
    maxDist = 100,
    computation = 320,
    minModule = 2,
    baseDuration = 1000,
    euPerTick = 491520,
    minDrone = 8,
    maxDrone = 13,
    weight = 150
  },
  ["Iron"] = {
    materials = { "Iron", "Gold", "Magnetite", "Pyrite", "BasalticMineralSand", "GraniticMineralSand" },
    weights = { 4000, 2000, 1000, 1000, 500, 500 },
    minSize = 30,
    maxSize = 150,
    minDist = 1,
    maxDist = 180,
    computation = 10,
    minModule = 1,
    baseDuration = 200,
    euPerTick = 1920,
    minDrone = 1,
    maxDrone = 7,
    weight = 600
  },
  ["Lanthanum"] = {
    materials = { "Trinium", "Lanthanum", "Orundum", "Silver" },
    weights = { 1500, 2000, 3000, 3500 },
    minSize = 30,
    maxSize = 120,
    minDist = 30,
    maxDist = 230,
    computation = 120,
    minModule = 2,
    baseDuration = 500,
    euPerTick = 30720,
    minDrone = 5,
    maxDrone = 11,
    weight = 150
  },
  ["Lead"] = {
    materials = { "Lead", "Arsenic", "Barium", "Lepidolite" },
    weights = { 3000, 2500, 2500, 2000 },
    minSize = 30,
    maxSize = 100,
    minDist = 5,
    maxDist = 150,
    computation = 20,
    minModule = 1,
    baseDuration = 500,
    euPerTick = 1920,
    minDrone = 1,
    maxDrone = 8,
    weight = 220
  },
  ["Lutetium"] = {
    materials = { "Tellurium", "Thulium", "Tantalum", "Lutetium", "Redstone" },
    weights = { 1500, 1000, 1500, 500, 5500 },
    minSize = 20,
    maxSize = 80,
    minDist = 40,
    maxDist = 240,
    computation = 90,
    minModule = 1,
    baseDuration = 500,
    euPerTick = 30720,
    minDrone = 5,
    maxDrone = 9,
    weight = 100
  },
  ["Magnesium"] = {
    materials = { "Magnesium", "Manganese", "Fluorspar" },
    weights = { 4000, 3000, 3000 },
    minSize = 10,
    maxSize = 80,
    minDist = 10,
    maxDist = 200,
    computation = 60,
    minModule = 1,
    baseDuration = 400,
    euPerTick = 7680,
    minDrone = 4,
    maxDrone = 9,
    weight = 250
  },
  ["Mysterious Crystal"] = {
    materials = { "MysteriousCrystal", "Mytryl", "Oriharukon", "Endium", "endPowder" },
    weights = { 7400, 2000, 500, 98, 2 },
    minSize = 30,
    maxSize = 60,
    minDist = 65,
    maxDist = 120,
    computation = 300,
    minModule = 1,
    baseDuration = 500,
    euPerTick = 122880,
    minDrone = 5,
    maxDrone = 13,
    weight = 220
  },
  ["Naquadah"] = {
    materials = { "Naquadah Oxide Mixture", "Enriched Naquadah Oxide Mixture", "Naquadria Oxide Mixture" },
    weights = { 4000, 3500, 2500 },
    minSize = 20,
    maxSize = 80,
    minDist = 50,
    maxDist = 150,
    computation = 240,
    minModule = 1,
    baseDuration = 1000,
    euPerTick = 30720,
    minDrone = 5,
    maxDrone = 8,
    weight = 200
  },
  ["Nickel"] = {
    materials = { "Nickel", "Pentlandite", "Garnierite" },
    weights = { 4000, 3000, 3000 },
    minSize = 20,
    maxSize = 40,
    minDist = 5,
    maxDist = 20,
    computation = 20,
    minModule = 1,
    baseDuration = 50,
    euPerTick = 7680,
    minDrone = 1,
    maxDrone = 5,
    weight = 170
  },
  ["Niobium"] = {
    materials = { "Niobium", "Quantium", "Ytterbium", "Yttrium" },
    weights = { 3000, 2000, 1500, 3500 },
    minSize = 30,
    maxSize = 120,
    minDist = 30,
    maxDist = 160,
    computation = 120,
    minModule = 1,
    baseDuration = 500,
    euPerTick = 30720,
    minDrone = 5,
    maxDrone = 9,
    weight = 160
  },
  ["Phosphate"] = {
    materials = { "Phosphate", "TricalciumPhosphate", "Sulfur" },
    weights = { 4500, 2500, 3000 },
    minSize = 20,
    maxSize = 150,
    minDist = 60,
    maxDist = 250,
    computation = 60,
    minModule = 1,
    baseDuration = 500,
    euPerTick = 30720,
    minDrone = 5,
    maxDrone = 11,
    weight = 150
  },
  ["PlatLine Dust"] = {
    materials = { "Platinum", "Palladium", "Iridium", "Osmium", "Ruthenium", "Rhodium" },
    weights = { 3800, 2000, 1500, 500, 1200, 1000 },
    minSize = 10,
    maxSize = 30,
    minDist = 25,
    maxDist = 200,
    computation = 360,
    minModule = 3,
    baseDuration = 500,
    euPerTick = 122880,
    minDrone = 7,
    maxDrone = 10,
    weight = 60
  },
  ["PlatLine Ore"] = {
    materials = { "Platinum", "Palladium", "Iridium", "Osmium" },
    weights = { 6000, 2000, 1500, 500 },
    minSize = 20,
    maxSize = 40,
    minDist = 10,
    maxDist = 50,
    computation = 60,
    minModule = 1,
    baseDuration = 50,
    euPerTick = 30720,
    minDrone = 3,
    maxDrone = 7,
    weight = 130
  },
  ["Quartz"] = {
    materials = { "Quartzite", "CertusQuartz", "NetherQuartz", "Vanadium" },
    weights = { 3000, 2250, 2250, 2500 },
    minSize = 20,
    maxSize = 80,
    minDist = 20,
    maxDist = 120,
    computation = 50,
    minModule = 1,
    baseDuration = 500,
    euPerTick = 7680,
    minDrone = 2,
    maxDrone = 7,
    weight = 230
  },
  ["Salt"] = {
    materials = { "Salt", "Rock Salt", "Saltpeter" },
    weights = { 4000, 2000, 4000 },
    minSize = 30,
    maxSize = 120,
    minDist = 1,
    maxDist = 250,
    computation = 20,
    minModule = 1,
    baseDuration = 200,
    euPerTick = 1920,
    minDrone = 1,
    maxDrone = 5,
    weight = 300
  },
  ["Silicon"] = {
    materials = { "Mica", "Silicon", "SiliconSG" },
    weights = { 2000, 4500, 2500 },
    minSize = 20,
    maxSize = 80,
    minDist = 50,
    maxDist = 250,
    computation = 60,
    minModule = 2,
    baseDuration = 500,
    euPerTick = 30720,
    minDrone = 3,
    maxDrone = 6,
    weight = 200
  },
  ["Tengam"] = {
    materials = { "Dilithium", "Orundum", "Vanadium", "Ytterbium", "TengamRaw" },
    weights = { 100, 1650, 3500, 2250, 2500 },
    minSize = 5,
    maxSize = 100,
    minDist = 20,
    maxDist = 100,
    computation = 120,
    minModule = 3,
    baseDuration = 500,
    euPerTick = 30720,
    minDrone = 10,
    maxDrone = 13,
    weight = 50
  },
  ["Thaumium Dusts"] = {
    materials = { "Thaumium", "Void" },
    weights = { 6000, 4000 },
    minSize = 20,
    maxSize = 50,
    minDist = 10,
    maxDist = 70,
    computation = 120,
    minModule = 1,
    baseDuration = 600,
    euPerTick = 30720,
    minDrone = 3,
    maxDrone = 6,
    weight = 150
  },
  ["Tin"] = {
    materials = { "Cassiterite", "CassiteriteSand", "Tin", "Asbestos" },
    weights = { 2000, 1500, 6000, 500 },
    minSize = 50,
    maxSize = 200,
    minDist = 2,
    maxDist = 100,
    computation = 10,
    minModule = 1,
    baseDuration = 50,
    euPerTick = 7680,
    minDrone = 1,
    maxDrone = 5,
    weight = 400
  },
  ["Tungsten-Titanium"] = {
    materials = { "Tungsten", "Titanium", "Neodymium", "Molybdenum", "Tungstate" },
    weights = { 3000, 3000, 2000, 1500, 500 },
    minSize = 30,
    maxSize = 70,
    minDist = 60,
    maxDist = 200,
    computation = 120,
    minModule = 1,
    baseDuration = 500,
    euPerTick = 30720,
    minDrone = 1,
    maxDrone = 6,
    weight = 100
  },
  ["Uranium-Plutonium"] = {
    materials = { "Uranium238", "Uranium235", "Plutonium239", "Plutonium241", "Thorianite" },
    weights = { 3000, 2450, 2450, 2000, 100 },
    minSize = 40,
    maxSize = 180,
    minDist = 30,
    maxDist = 70,
    computation = 120,
    minModule = 1,
    baseDuration = 400,
    euPerTick = 30720,
    minDrone = 3,
    maxDrone = 7,
    weight = 150
  }
}

--------------------------------------------------------------------------------
-- 7. OPTIMIZATION MATRIX
-- Pre-computed optimal distance setting per [moduleTier][asteroid][droneKey],
-- derived from the Space Elevator Calculator spreadsheet.
-- "Optimal" means the distance that maximises the target asteroid's selection
-- probability by minimising the total weight of competing asteroids in range.
-- Broker calculates actual probability at runtime:
--   P = asteroid.weight / sum(weight of all qualifying asteroids at distance)
-- A qualifying asteroid must satisfy: distance in [minDist,maxDist],
-- droneTier in [minDrone,maxDrone], and minModule <= module tier.
-- Missing entries mean that drone tier cannot mine this asteroid.
--------------------------------------------------------------------------------
config.optimizationMatrix = {
  ["MK-I"] = {
    ["Adamantium"]          = { ev = 101, iv = 5, luv = 5, zpm = 5 },
    ["Aluminium"]           = { mv = 13, hv = 5, ev = 5 },
    ["Aluminium-LanthLine"] = { mv = 101, hv = 101, ev = 101, iv = 101, luv = 101, zpm = 41 },
    ["Ardite/Cobalt"]       = { ev = 71, iv = 41, luv = 41, zpm = 30, uv = 30, uhv = 30 },
    ["Basic Magic"]         = { hv = 13, ev = 8, iv = 8, luv = 8 },
    ["Blue"]                = { hv = 181, ev = 181, iv = 181, luv = 181, zpm = 181, uv = 20 },
    ["Chrome"]              = { mv = 13, hv = 13, ev = 13, iv = 13, luv = 13 },
    ["Clay"]                = { lv = 41, mv = 41, hv = 71, ev = 71, iv = 25, luv = 25 },
    ["Coal"]                = { lv = 1, mv = 1, hv = 1, ev = 1, iv = 1, luv = 1, zpm = 1 },
    ["Copper"]              = { lv = 3, mv = 3, hv = 3, ev = 3, iv = 3, luv = 3 },
    ["Everglades"]          = { zpm = 201, uv = 201, uhv = 201 },
    ["Gem Ores"]            = { lv = 17, mv = 17, hv = 17, ev = 17, iv = 17, luv = 17 },
    ["Iron"]                = { lv = 151, mv = 151, hv = 1, ev = 1, iv = 1, luv = 1, zpm = 1 },
    ["Lead"]                = { lv = 101, mv = 121, hv = 121, ev = 121, iv = 121, luv = 5, zpm = 5, uv = 5 },
    ["Lutetium"]            = { iv = 201, luv = 201, zpm = 231, uv = 231, uhv = 231 },
    ["Magnesium"]           = { ev = 181, iv = 181, luv = 181, zpm = 181, uv = 10, uhv = 10 },
    ["Mysterious Crystal"]  = { iv = 101, luv = 101, zpm = 101, uv = 101, uhv = 101, uev = 65, uiv = 65, umv = 65, uxv = 65 },
    ["Naquadah"]            = { iv = 121, luv = 121, zpm = 121, uv = 50 },
    ["Nickel"]              = { lv = 13, mv = 13, hv = 5, ev = 5, iv = 5 },
    ["Niobium"]             = { iv = 151, luv = 151, zpm = 151, uv = 151, uhv = 30 },
    ["Phosphate"]           = { iv = 241, luv = 241, zpm = 241, uv = 241, uhv = 241, uev = 60, uiv = 60 },
    ["PlatLine Ore"]        = { hv = 13, ev = 13, iv = 13, luv = 13, zpm = 10 },
    ["Quartz"]              = { mv = 101, hv = 101, ev = 101, iv = 101, luv = 25, zpm = 20 },
    ["Salt"]                = { lv = 201, mv = 201, hv = 201, ev = 201, iv = 241 },
    ["Thaumium Dusts"]      = { hv = 13, ev = 13, iv = 13, luv = 13 },
    ["Tin"]                 = { lv = 2, mv = 2, hv = 2, ev = 2, iv = 2 },
    ["Tungsten-Titanium"]   = { lv = 181, mv = 181, hv = 181, ev = 181, iv = 181, luv = 181 },
    ["Uranium-Plutonium"]   = { hv = 51, ev = 51, iv = 41, luv = 41, zpm = 30 }
  },
  ["MK-II"] = {
    ["Adamantium"]          = { ev = 101, iv = 5, luv = 5, zpm = 5 },
    ["Aluminium"]           = { mv = 13, hv = 5, ev = 5 },
    ["Aluminium-LanthLine"] = { mv = 101, hv = 101, ev = 101, iv = 101, luv = 41, zpm = 41 },
    ["Ardite/Cobalt"]       = { ev = 71, iv = 41, luv = 41, zpm = 30, uv = 30, uhv = 30 },
    ["Basic Magic"]         = { hv = 13, ev = 8, iv = 8, luv = 8 },
    ["Blue"]                = { hv = 181, ev = 181, iv = 181, luv = 181, zpm = 181, uv = 20 },
    ["Cheese"]              = { iv = 181, luv = 181, zpm = 181, uv = 161, uhv = 161, uev = 121, uiv = 121, umv = 121, uxv = 121 },
    ["Chrome"]              = { mv = 13, hv = 13, ev = 13, iv = 13, luv = 13 },
    ["Clay"]                = { lv = 41, mv = 41, hv = 71, ev = 25, iv = 25, luv = 25 },
    ["Coal"]                = { lv = 1, mv = 1, hv = 1, ev = 1, iv = 1, luv = 1, zpm = 1 },
    ["Copper"]              = { lv = 3, mv = 3, hv = 3, ev = 3, iv = 3, luv = 3 },
    ["Cosmic"]              = { zpm = 91, uv = 61, uhv = 61, uev = 61, uiv = 61, umv = 61, uxv = 61 },
    ["Draconic"]            = { luv = 181, zpm = 181, uv = 161, uhv = 161 },
    ["Europium"]            = { zpm = 41, uv = 40, uhv = 40, uev = 40, uiv = 40, umv = 40, uxv = 40 },
    ["Everglades"]          = { zpm = 201, uv = 201, uhv = 201 },
    ["Gem Ores"]            = { lv = 17, mv = 17, hv = 17, ev = 17, iv = 17, luv = 17 },
    ["Holmium/Samarium"]    = { zpm = 40, uv = 40, uhv = 40, uev = 40, uiv = 40, umv = 40, uxv = 40 },
    ["Indium"]              = { iv = 51, luv = 51, zpm = 51, uv = 50, uhv = 50, uev = 50 },
    ["Infinity Catalyst"]   = { uv = 91, uhv = 91, uev = 91, uiv = 91, umv = 91, uxv = 91 },
    ["Iron"]                = { lv = 151, mv = 151, hv = 1, ev = 1, iv = 1, luv = 1, zpm = 1 },
    ["Lanthanum"]           = { iv = 201, luv = 201, zpm = 201, uv = 201, uhv = 201, uev = 30, uiv = 30 },
    ["Lead"]                = { lv = 101, mv = 121, hv = 121, ev = 121, iv = 5, luv = 5, zpm = 5, uv = 5 },
    ["Lutetium"]            = { iv = 231, luv = 231, zpm = 231, uv = 231, uhv = 231 },
    ["Magnesium"]           = { ev = 181, iv = 181, luv = 181, zpm = 181, uv = 10, uhv = 10 },
    ["Mysterious Crystal"]  = { iv = 101, luv = 101, zpm = 101, uv = 101, uhv = 101, uev = 101, uiv = 101, umv = 101, uxv = 101 },
    ["Naquadah"]            = { iv = 121, luv = 121, zpm = 121, uv = 121 },
    ["Nickel"]              = { lv = 13, mv = 13, hv = 5, ev = 5, iv = 5 },
    ["Niobium"]             = { iv = 151, luv = 151, zpm = 151, uv = 30, uhv = 30 },
    ["Phosphate"]           = { iv = 241, luv = 241, zpm = 241, uv = 241, uhv = 241, uev = 231, uiv = 231 },
    ["PlatLine Ore"]        = { hv = 13, ev = 13, iv = 13, luv = 13, zpm = 10 },
    ["Quartz"]              = { mv = 101, hv = 101, ev = 101, iv = 25, luv = 25, zpm = 20 },
    ["Salt"]                = { lv = 201, mv = 201, hv = 201, ev = 201, iv = 241 },
    ["Silicon"]             = { hv = 201, ev = 201, iv = 241, luv = 241 },
    ["Thaumium Dusts"]      = { hv = 13, ev = 13, iv = 13, luv = 13 },
    ["Tin"]                 = { lv = 2, mv = 2, hv = 2, ev = 2, iv = 2 },
    ["Tungsten-Titanium"]   = { lv = 181, mv = 181, hv = 181, ev = 181, iv = 181, luv = 181 },
    ["Uranium-Plutonium"]   = { hv = 41, ev = 41, iv = 41, luv = 41, zpm = 30 }
  },
  ["MK-III"] = {
    ["Adamantium"]          = { ev = 101, iv = 5, luv = 5, zpm = 5 },
    ["Aluminium"]           = { mv = 13, hv = 5, ev = 5 },
    ["Aluminium-LanthLine"] = { mv = 101, hv = 101, ev = 101, iv = 101, luv = 41, zpm = 41 },
    ["Ardite/Cobalt"]       = { ev = 71, iv = 41, luv = 41, zpm = 30, uv = 30, uhv = 30 },
    ["Basic Magic"]         = { hv = 13, ev = 8, iv = 8, luv = 8 },
    ["Blue"]                = { hv = 181, ev = 181, iv = 181, luv = 181, zpm = 181, uv = 20 },
    ["Cheese"]              = { iv = 181, luv = 181, zpm = 181, uv = 161, uhv = 161, uev = 121, uiv = 121, umv = 121, uxv = 121 },
    ["Chrome"]              = { mv = 13, hv = 13, ev = 13, iv = 13, luv = 13 },
    ["Clay"]                = { lv = 41, mv = 41, hv = 71, ev = 25, iv = 25, luv = 25 },
    ["Coal"]                = { lv = 1, mv = 1, hv = 1, ev = 1, iv = 1, luv = 1, zpm = 1 },
    ["Copper"]              = { lv = 3, mv = 3, hv = 3, ev = 3, iv = 3, luv = 3 },
    ["Cosmic"]              = { zpm = 91, uv = 61, uhv = 61, uev = 61, uiv = 61, umv = 61, uxv = 61 },
    ["Draconic"]            = { luv = 181, zpm = 181, uv = 161, uhv = 161 },
    ["Draconic Core"]       = { uhv = 161, uev = 121, uiv = 121 },
    ["Europium"]            = { zpm = 41, uv = 40, uhv = 40, uev = 40, uiv = 40, umv = 40, uxv = 40 },
    ["Everglades"]          = { zpm = 201, uv = 201, uhv = 201 },
    ["Gem Ores"]            = { lv = 17, mv = 17, hv = 17, ev = 17, iv = 17, luv = 17 },
    ["Holmium/Samarium"]    = { uv = 40, uhv = 40, uev = 40, uiv = 40, umv = 40, uxv = 40 },
    ["Ichorium"]            = { uhv = 91, uev = 81, uiv = 81, umv = 81, uxv = 81 },
    ["Indium"]              = { iv = 51, luv = 51, zpm = 51, uv = 50, uhv = 50, uev = 50 },
    ["Infinity Catalyst"]   = { uv = 91, uhv = 91, uev = 81, uiv = 81, umv = 81, uxv = 81 },
    ["Iron"]                = { lv = 151, mv = 151, hv = 1, ev = 1, iv = 1, luv = 1, zpm = 1 },
    ["Lanthanum"]           = { iv = 201, luv = 201, zpm = 201, uv = 201, uhv = 201, uev = 30, uiv = 30 },
    ["Lead"]                = { lv = 101, mv = 121, hv = 121, ev = 121, iv = 5, luv = 5, zpm = 5, uv = 5 },
    ["Lutetium"]            = { iv = 231, luv = 231, zpm = 231, uv = 231, uhv = 231 },
    ["Magnesium"]           = { ev = 181, iv = 181, luv = 181, zpm = 181, uv = 10, uhv = 10 },
    ["Mysterious Crystal"]  = { iv = 101, luv = 101, zpm = 101, uv = 101, uhv = 101, uev = 101, uiv = 101, umv = 101, uxv = 101 },
    ["Naquadah"]            = { iv = 121, luv = 121, zpm = 121, uv = 121 },
    ["Nickel"]              = { lv = 13, mv = 13, hv = 5, ev = 5, iv = 5 },
    ["Niobium"]             = { iv = 151, luv = 151, zpm = 151, uv = 30, uhv = 30 },
    ["Phosphate"]           = { iv = 241, luv = 241, zpm = 241, uv = 241, uhv = 241, uev = 231, uiv = 231 },
    ["PlatLine Dust"]       = { zpm = 181, uv = 25, uhv = 25, uev = 25 },
    ["PlatLine Ore"]        = { hv = 13, ev = 13, iv = 13, luv = 13, zpm = 10 },
    ["Quartz"]              = { mv = 101, hv = 101, ev = 101, iv = 25, luv = 25, zpm = 20 },
    ["Salt"]                = { lv = 201, mv = 201, hv = 201, ev = 201, iv = 241 },
    ["Silicon"]             = { hv = 201, ev = 201, iv = 241, luv = 241 },
    ["Tengam"]              = { uev = 20, uiv = 20, umv = 20, uxv = 20 },
    ["Thaumium Dusts"]      = { hv = 13, ev = 13, iv = 13, luv = 13 },
    ["Tin"]                 = { lv = 2, mv = 2, hv = 2, ev = 2, iv = 2 },
    ["Tungsten-Titanium"]   = { lv = 181, mv = 181, hv = 181, ev = 181, iv = 181, luv = 181 },
    ["Uranium-Plutonium"]   = { hv = 41, ev = 41, iv = 41, luv = 41, zpm = 30 }
  }
}

--------------------------------------------------------------------------------
-- 7b. ASTEROID OUTPUTS  (generated -- do not hand-edit)
--
-- Read out of the RUNNING GAME by the asteroiddump mod. Every label is a
-- string the game produced through ItemStack.getDisplayName, so it matches
-- the ME network exactly. Nothing here is derived or guessed.
--
--   drops      what the module actually spits out. Use for the module's item
--              filter. Mostly ore, which processing eats on arrival -- its
--              stock never accumulates, so do not track it.
--   main       what you get from processing those drops: macerator, washer,
--              thermal centrifuge, sifter, chemical bath, EM separator.
--   processed  what you get from breaking the main outputs down further, in a
--              centrifuge or electrolyzer.
--
-- chance is out of 10000 and is an INDEPENDENT roll per drop, not a share of
-- a distribution -- spaceOreAsteroid totals 29000, so ~2.9 items per run.
--
-- Half-processed stages (Crushed/Purified/Centrifuged/Impure Pile) are left
-- out: real items, but they only exist between two machines.
--------------------------------------------------------------------------------
config.asteroidOutputs = {
  ["Adamantium"] = {   -- adamantiumAsteroid, drones 3..6, module tier 1
    drops = {
      { item = "Adamantium Ore",                            chance =  2500 },
      { item = "Bismuth Ore",                               chance =  2000 },
      { item = "Antimony Ore",                              chance =  2000 },
      { item = "Gallium Ore",                               chance =  2000 },
      { item = "Lithium Ore",                               chance =  1500 },
    },
    main = {
      { item = "Adamantium Dust",                           via = "macerator"                  },
      { item = "Antimony Dust",                             via = "simple_washer"              },
      { item = "Bismuth Dust",                              via = "macerator"                  },
      { item = "Endstone Dust",                             via = "macerator"                  },
      { item = "Fiery Steel Dust",                          via = "chemical_bath"              },
      { item = "Gallium Dust",                              via = "macerator"                  },
      { item = "Iron Dust",                                 via = "thermal_centrifuge"         },
      { item = "Lithium Dust",                              via = "macerator"                  },
      { item = "Quartz Sand",                               via = "macerator"                  },
      { item = "Stone Dust",                                via = "ore_washer"                 },
      { item = "Zinc Dust",                                 via = "macerator"                  },
    },
    processed = {
      { item = "Biotite Dust",                              via = "centrifuge"                 },
      { item = "Marble Dust",                               via = "centrifuge"                 },
      { item = "Metal Mixture Dust",                        via = "centrifuge"                 },
      { item = "Platinum Metallic Powder Dust",             via = "centrifuge"                 },
      { item = "Potassium Feldspar Dust",                   via = "centrifuge"                 },
      { item = "Quartzite Dust",                            via = "centrifuge"                 },
      { item = "Sand",                                      via = "centrifuge"                 },
      { item = "Silicon Dioxide Dust",                      via = "electrolyzer"               },
      { item = "Sodalite Dust",                             via = "centrifuge"                 },
      { item = "Tungstate Dust",                            via = "centrifuge"                 },
    },
  },
  ["Aluminium"] = {   -- aluminiumAsteroid, drones 1..3, module tier 1
    drops = {
      { item = "Aluminium Ore",                             chance =  5000 },
      { item = "Bauxite Ore",                               chance =  3500 },
      { item = "Rutile Ore",                                chance =  1500 },
    },
    main = {
      { item = "Bauxite Dust",                              via = "macerator"                  },
      { item = "Endstone Dust",                             via = "macerator"                  },
      { item = "Fiery Steel Dust",                          via = "chemical_bath"              },
      { item = "Gallium Dust",                              via = "macerator"                  },
      { item = "Grossular Dust",                            via = "macerator"                  },
      { item = "Quartz Sand",                               via = "macerator"                  },
      { item = "Rutile Dust",                               via = "macerator"                  },
      { item = "Small Pile of Rutile Dust",                 via = "electromagnetic_separator"  },
      { item = "Stone Dust",                                via = "ore_washer"                 },
      { item = "Zirconium Nugget",                          via = "electromagnetic_separator"  },
    },
    processed = {
      { item = "Alumina Dust",                              via = "centrifuge"                 },
      { item = "Aluminium Dust",                            via = "electrolyzer"               },
      { item = "Biotite Dust",                              via = "centrifuge"                 },
      { item = "Calcite Dust",                              via = "centrifuge"                 },
      { item = "Calcium Dust",                              via = "electrolyzer"               },
      { item = "Carbon Dust",                               via = "electrolyzer"               },
      { item = "Gold Dust",                                 via = "centrifuge"                 },
      { item = "Iron Dust",                                 via = "centrifuge"                 },
      { item = "Marble Dust",                               via = "centrifuge"                 },
      { item = "Metal Mixture Dust",                        via = "centrifuge"                 },
      { item = "Oxygen Cell",                               via = "electrolyzer"               },
      { item = "Platinum Metallic Powder Dust",             via = "centrifuge"                 },
      { item = "Potassium Feldspar Dust",                   via = "centrifuge"                 },
      { item = "Quartzite Dust",                            via = "centrifuge"                 },
      { item = "Quicklime Dust",                            via = "centrifuge"                 },
      { item = "Sand",                                      via = "centrifuge"                 },
      { item = "Silicon Dioxide Dust",                      via = "electrolyzer"               },
      { item = "Sodalite Dust",                             via = "centrifuge"                 },
      { item = "Tungstate Dust",                            via = "centrifuge"                 },
      { item = "Vanadium Dust",                             via = "centrifuge"                 },
    },
  },
  ["Aluminium-LanthLine"] = {   -- aluminiumLanthlineAsteroid, drones 1..6, module tier 1
    drops = {
      { item = "Aluminium Ore",                             chance =  3500 },
      { item = "Bauxite Ore",                               chance =  1500 },
      { item = "Monazite Ore",                              chance =  2500 },
      { item = "Bastnasite Ore",                            chance =  2500 },
    },
    main = {
      { item = "Bastnasite Dust",                           via = "simple_washer"              },
      { item = "Bauxite Dust",                              via = "macerator"                  },
      { item = "Endstone Dust",                             via = "macerator"                  },
      { item = "Fiery Steel Dust",                          via = "chemical_bath"              },
      { item = "Gallium Dust",                              via = "macerator"                  },
      { item = "Grossular Dust",                            via = "macerator"                  },
      { item = "Monazite",                                  via = "sifter"                     },
      { item = "Monazite Dust",                             via = "simple_washer"              },
      { item = "Neodymium Dust",                            via = "macerator"                  },
      { item = "Quartz Sand",                               via = "macerator"                  },
      { item = "Rare Earth",                                via = "thermal_centrifuge"         },
      { item = "Rutile Dust",                               via = "thermal_centrifuge"         },
      { item = "Small Pile of Rutile Dust",                 via = "electromagnetic_separator"  },
      { item = "Stone Dust",                                via = "ore_washer"                 },
      { item = "Thorium Dust",                              via = "macerator"                  },
      { item = "Zirconium Nugget",                          via = "electromagnetic_separator"  },
    },
    processed = {
      { item = "Alumina Dust",                              via = "centrifuge"                 },
      { item = "Aluminium Dust",                            via = "electrolyzer"               },
      { item = "Biotite Dust",                              via = "centrifuge"                 },
      { item = "Calcite Dust",                              via = "centrifuge"                 },
      { item = "Calcium Dust",                              via = "electrolyzer"               },
      { item = "Carbon Dust",                               via = "electrolyzer"               },
      { item = "Gold Dust",                                 via = "centrifuge"                 },
      { item = "Iron Dust",                                 via = "centrifuge"                 },
      { item = "Marble Dust",                               via = "centrifuge"                 },
      { item = "Metal Mixture Dust",                        via = "centrifuge"                 },
      { item = "Oxygen Cell",                               via = "electrolyzer"               },
      { item = "Platinum Metallic Powder Dust",             via = "centrifuge"                 },
      { item = "Potassium Feldspar Dust",                   via = "centrifuge"                 },
      { item = "Quartzite Dust",                            via = "centrifuge"                 },
      { item = "Quicklime Dust",                            via = "centrifuge"                 },
      { item = "Sand",                                      via = "centrifuge"                 },
      { item = "Silicon Dioxide Dust",                      via = "electrolyzer"               },
      { item = "Sodalite Dust",                             via = "centrifuge"                 },
      { item = "Thorium 232 Dust",                          via = "centrifuge"                 },
      { item = "Tungstate Dust",                            via = "centrifuge"                 },
      { item = "Vanadium Dust",                             via = "centrifuge"                 },
    },
  },
  ["Ardite/Cobalt"] = {   -- arditeCobaltAsteroid, drones 3..8, module tier 1
    drops = {
      { item = "Cobalt Ore",                                chance =  3750 },
      { item = "Ardite Ore",                                chance =  3750 },
      { item = "Manyullyn Ore",                             chance =  2500 },
    },
    main = {
      { item = "Ardite Dust",                               via = "macerator"                  },
      { item = "Cobalt Dust",                               via = "chemical_bath"              },
      { item = "Cobaltite Dust",                            via = "macerator"                  },
      { item = "Manyullyn Dust",                            via = "macerator"                  },
      { item = "Stone Dust",                                via = "macerator"                  },
    },
    processed = {
      { item = "Alumina Dust",                              via = "electrolyzer"               },
      { item = "Aluminium Dust",                            via = "electrolyzer"               },
      { item = "Arsenic Dust",                              via = "electrolyzer"               },
      { item = "Banded Iron Dust",                          via = "centrifuge"                 },
      { item = "Barite Dust",                               via = "centrifuge"                 },
      { item = "Bauxite Dust",                              via = "centrifuge"                 },
      { item = "Biotite Dust",                              via = "centrifuge"                 },
      { item = "Calcite Dust",                              via = "centrifuge"                 },
      { item = "Chromite Dust",                             via = "centrifuge"                 },
      { item = "Ilmenite Dust",                             via = "centrifuge"                 },
      { item = "Magnesium Dust",                            via = "centrifuge"                 },
      { item = "Marble Dust",                               via = "centrifuge"                 },
      { item = "Metal Mixture Dust",                        via = "centrifuge"                 },
      { item = "Oxygen Cell",                               via = "electrolyzer"               },
      { item = "Potassium Dust",                            via = "electrolyzer"               },
      { item = "Potassium Feldspar Dust",                   via = "centrifuge"                 },
      { item = "Pyrolusite Dust",                           via = "centrifuge"                 },
      { item = "Quartzite Dust",                            via = "centrifuge"                 },
      { item = "Raw Silicon Dust",                          via = "electrolyzer"               },
      { item = "Silicon Dioxide Dust",                      via = "electrolyzer"               },
      { item = "Sodalite Dust",                             via = "centrifuge"                 },
      { item = "Sodium Dust",                               via = "electrolyzer"               },
      { item = "Sulfur Dust",                               via = "electrolyzer"               },
    },
  },
  ["Basic Magic"] = {   -- basicMagicAsteroid, drones 2..5, module tier 1
    drops = {
      { item = "Infused Gold Ore",                          chance =  3500 },
      { item = "Shadow Metal Ore",                          chance =  3500 },
      { item = "Aer Infused Stone",                         chance =   500 },
      { item = "Terra Infused Stone",                       chance =   500 },
      { item = "Ignis Infused Stone",                       chance =   500 },
      { item = "Aqua Infused Stone",                        chance =   500 },
      { item = "Perditio Infused Stone",                    chance =   500 },
      { item = "Ordo Infused Stone",                        chance =   500 },
    },
    main = {
      { item = "Aer Crystal Powder",                        via = "macerator"                  },
      { item = "Air Shard",                                 via = "macerator"                  },
      { item = "Aqua Crystal Powder",                       via = "macerator"                  },
      { item = "Earth Shard",                               via = "macerator"                  },
      { item = "Endstone Dust",                             via = "macerator"                  },
      { item = "Entropy Shard",                             via = "macerator"                  },
      { item = "Fire Shard",                                via = "macerator"                  },
      { item = "Gold Dust",                                 via = "macerator"                  },
      { item = "Ignis Crystal Powder",                      via = "macerator"                  },
      { item = "Infused Gold Dust",                         via = "simple_washer"              },
      { item = "Order Shard",                               via = "macerator"                  },
      { item = "Ordo Crystal Powder",                       via = "macerator"                  },
      { item = "Perditio Crystal Powder",                   via = "macerator"                  },
      { item = "Quartz Sand",                               via = "macerator"                  },
      { item = "Shadow Metal Dust",                         via = "macerator"                  },
      { item = "Stone Dust",                                via = "ore_washer"                 },
      { item = "Terra Crystal Powder",                      via = "macerator"                  },
      { item = "Water Shard",                               via = "macerator"                  },
    },
    processed = {
      { item = "Biotite Dust",                              via = "centrifuge"                 },
      { item = "Marble Dust",                               via = "centrifuge"                 },
      { item = "Metal Mixture Dust",                        via = "centrifuge"                 },
      { item = "Platinum Metallic Powder Dust",             via = "centrifuge"                 },
      { item = "Potassium Feldspar Dust",                   via = "centrifuge"                 },
      { item = "Quartzite Dust",                            via = "centrifuge"                 },
      { item = "Sand",                                      via = "centrifuge"                 },
      { item = "Silicon Dioxide Dust",                      via = "electrolyzer"               },
      { item = "Sodalite Dust",                             via = "centrifuge"                 },
      { item = "Tungstate Dust",                            via = "centrifuge"                 },
    },
  },
  ["Blue"] = {   -- blueAsteroid, drones 2..7, module tier 1
    drops = {
      { item = "Lapis Ore",                                 chance =  6000 },
      { item = "Calcite Ore",                               chance =  2000 },
      { item = "Lazurite Ore",                              chance =  1000 },
      { item = "Sodalite Ore",                              chance =  1000 },
    },
    main = {
      { item = "Andradite Dust",                            via = "macerator"                  },
      { item = "Calcite Dust",                              via = "simple_washer"              },
      { item = "Endstone Dust",                             via = "macerator"                  },
      { item = "Fiery Steel Dust",                          via = "chemical_bath"              },
      { item = "Lapis Dust",                                via = "thermal_centrifuge"         },
      { item = "Lapis Lazuli",                              via = "sifter"                     },
      { item = "Lazurite",                                  via = "macerator"                  },
      { item = "Lazurite Dust",                             via = "macerator"                  },
      { item = "Malachite Dust",                            via = "thermal_centrifuge"         },
      { item = "Pyrite Dust",                               via = "macerator"                  },
      { item = "Quartz Sand",                               via = "macerator"                  },
      { item = "Sodalite",                                  via = "macerator"                  },
      { item = "Sodalite Dust",                             via = "thermal_centrifuge"         },
      { item = "Stone Dust",                                via = "ore_washer"                 },
    },
    processed = {
      { item = "Alumina Dust",                              via = "centrifuge"                 },
      { item = "Aluminium Dust",                            via = "electrolyzer"               },
      { item = "Biotite Dust",                              via = "centrifuge"                 },
      { item = "Calcium Dust",                              via = "electrolyzer"               },
      { item = "Carbon Dust",                               via = "electrolyzer"               },
      { item = "Copper Dust",                               via = "electrolyzer"               },
      { item = "Gold Dust",                                 via = "centrifuge"                 },
      { item = "Iron Dust",                                 via = "centrifuge"                 },
      { item = "Marble Dust",                               via = "centrifuge"                 },
      { item = "Metal Mixture Dust",                        via = "centrifuge"                 },
      { item = "Oxygen Cell",                               via = "electrolyzer"               },
      { item = "Platinum Metallic Powder Dust",             via = "centrifuge"                 },
      { item = "Potassium Feldspar Dust",                   via = "centrifuge"                 },
      { item = "Quartzite Dust",                            via = "centrifuge"                 },
      { item = "Quicklime Dust",                            via = "centrifuge"                 },
      { item = "Raw Silicon Dust",                          via = "electrolyzer"               },
      { item = "Rutile Dust",                               via = "centrifuge"                 },
      { item = "Sand",                                      via = "centrifuge"                 },
      { item = "Silicon Dioxide Dust",                      via = "electrolyzer"               },
      { item = "Sodium Dust",                               via = "electrolyzer"               },
      { item = "Tungstate Dust",                            via = "centrifuge"                 },
      { item = "Vanadium Dust",                             via = "centrifuge"                 },
    },
  },
  ["Cheese"] = {   -- cheeseAsteroid, drones 4..12, module tier 2
    drops = {
      { item = "Cheese Ore",                                chance = 10000 },
    },
    main = {
      { item = "Cheese Powder",                             via = "macerator"                  },
      { item = "Endstone Dust",                             via = "macerator"                  },
      { item = "Quartz Sand",                               via = "macerator"                  },
      { item = "Stone Dust",                                via = "ore_washer"                 },
    },
    processed = {
      { item = "Biotite Dust",                              via = "centrifuge"                 },
      { item = "Marble Dust",                               via = "centrifuge"                 },
      { item = "Metal Mixture Dust",                        via = "centrifuge"                 },
      { item = "Platinum Metallic Powder Dust",             via = "centrifuge"                 },
      { item = "Potassium Feldspar Dust",                   via = "centrifuge"                 },
      { item = "Quartzite Dust",                            via = "centrifuge"                 },
      { item = "Sand",                                      via = "centrifuge"                 },
      { item = "Silicon Dioxide Dust",                      via = "electrolyzer"               },
      { item = "Sodalite Dust",                             via = "centrifuge"                 },
      { item = "Tungstate Dust",                            via = "centrifuge"                 },
    },
  },
  ["Chrome"] = {   -- chromeAsteroid, drones 1..5, module tier 1
    drops = {
      { item = "Chrome Ore",                                chance =  5000 },
      { item = "Ruby Ore",                                  chance =  3000 },
      { item = "Chromite Ore",                              chance =  2000 },
    },
    main = {
      { item = "Chipped Ruby",                              via = "sifter"                     },
      { item = "Chrome Dust",                               via = "macerator"                  },
      { item = "Chromite Dust",                             via = "simple_washer"              },
      { item = "Endstone Dust",                             via = "macerator"                  },
      { item = "Exquisite Ruby",                            via = "sifter"                     },
      { item = "Fiery Steel Dust",                          via = "chemical_bath"              },
      { item = "Flawed Ruby",                               via = "sifter"                     },
      { item = "Flawless Ruby",                             via = "sifter"                     },
      { item = "Iron Dust",                                 via = "macerator"                  },
      { item = "Magnesium Dust",                            via = "thermal_centrifuge"         },
      { item = "Quartz Sand",                               via = "macerator"                  },
      { item = "Red Garnet Dust",                           via = "thermal_centrifuge"         },
      { item = "Ruby",                                      via = "sifter"                     },
      { item = "Ruby Dust",                                 via = "simple_washer"              },
      { item = "Stone Dust",                                via = "ore_washer"                 },
    },
    processed = {
      { item = "Almandine Dust",                            via = "centrifuge"                 },
      { item = "Biotite Dust",                              via = "centrifuge"                 },
      { item = "Marble Dust",                               via = "centrifuge"                 },
      { item = "Metal Mixture Dust",                        via = "centrifuge"                 },
      { item = "Platinum Metallic Powder Dust",             via = "centrifuge"                 },
      { item = "Potassium Feldspar Dust",                   via = "centrifuge"                 },
      { item = "Pyrope Dust",                               via = "centrifuge"                 },
      { item = "Quartzite Dust",                            via = "centrifuge"                 },
      { item = "Sand",                                      via = "centrifuge"                 },
      { item = "Silicon Dioxide Dust",                      via = "electrolyzer"               },
      { item = "Sodalite Dust",                             via = "centrifuge"                 },
      { item = "Spessartine Dust",                          via = "centrifuge"                 },
      { item = "Tungstate Dust",                            via = "centrifuge"                 },
    },
  },
  ["Clay"] = {   -- clayAsteroid, drones 0..5, module tier 1
    drops = {
      { item = "Clay",                                      chance = 10000 },
    },
    main = {
      { item = "Clay Dust",                                 via = "macerator"                  },
      { item = "Silicon Dioxide Dust",                      via = "thermal_centrifuge"         },
      { item = "Sodium Hydroxide Dust",                     via = "chemical_bath"              },
    },
    processed = {
      { item = "Alumina Dust",                              via = "electrolyzer"               },
      { item = "Aluminium Dust",                            via = "electrolyzer"               },
      { item = "Lithium Dust",                              via = "electrolyzer"               },
      { item = "Sodium Dust",                               via = "electrolyzer"               },
    },
  },
  ["Coal"] = {   -- coalAsteroid, drones 0..6, module tier 1
    drops = {
      { item = "Coal Ore",                                  chance =  7000 },
      { item = "Lignite Coal Ore",                          chance =  1000 },
      { item = "Graphite Ore",                              chance =  2000 },
    },
    main = {
      { item = "Carbon Dust",                               via = "macerator"                  },
      { item = "Coal",                                      via = "macerator"                  },
      { item = "Coal Dust",                                 via = "macerator"                  },
      { item = "Endstone Dust",                             via = "macerator"                  },
      { item = "Graphite Dust",                             via = "simple_washer"              },
      { item = "Hydrated Coal Dust",                        via = "chemical_bath"              },
      { item = "Lignite Coal",                              via = "macerator"                  },
      { item = "Lignite Coal Dust",                         via = "macerator"                  },
      { item = "Quartz Sand",                               via = "macerator"                  },
      { item = "Stone Dust",                                via = "ore_washer"                 },
      { item = "Thorium Dust",                              via = "thermal_centrifuge"         },
    },
    processed = {
      { item = "Biotite Dust",                              via = "centrifuge"                 },
      { item = "Marble Dust",                               via = "centrifuge"                 },
      { item = "Metal Mixture Dust",                        via = "centrifuge"                 },
      { item = "Platinum Metallic Powder Dust",             via = "centrifuge"                 },
      { item = "Potassium Feldspar Dust",                   via = "centrifuge"                 },
      { item = "Quartzite Dust",                            via = "centrifuge"                 },
      { item = "Sand",                                      via = "centrifuge"                 },
      { item = "Silicon Dioxide Dust",                      via = "electrolyzer"               },
      { item = "Sodalite Dust",                             via = "centrifuge"                 },
      { item = "Thorium 232 Dust",                          via = "centrifuge"                 },
      { item = "Tungstate Dust",                            via = "centrifuge"                 },
    },
  },
  ["Copper"] = {   -- copperAsteroid, drones 0..5, module tier 1
    drops = {
      { item = "Copper Ore",                                chance =  5000 },
      { item = "Chalcopyrite Ore",                          chance =  3000 },
      { item = "Malachite Ore",                             chance =  2000 },
    },
    main = {
      { item = "Brown Limonite Dust",                       via = "thermal_centrifuge"         },
      { item = "Cadmium Dust",                              via = "macerator"                  },
      { item = "Calcite Dust",                              via = "macerator"                  },
      { item = "Chalcopyrite Dust",                         via = "simple_washer"              },
      { item = "Cobalt Dust",                               via = "macerator"                  },
      { item = "Copper Dust",                               via = "macerator"                  },
      { item = "Endstone Dust",                             via = "macerator"                  },
      { item = "Fiery Steel Dust",                          via = "chemical_bath"              },
      { item = "Gold Dust",                                 via = "thermal_centrifuge"         },
      { item = "Malachite",                                 via = "sifter"                     },
      { item = "Malachite Dust",                            via = "simple_washer"              },
      { item = "Nickel Dust",                               via = "macerator"                  },
      { item = "Pyrite Dust",                               via = "macerator"                  },
      { item = "Quartz Sand",                               via = "macerator"                  },
      { item = "Stone Dust",                                via = "ore_washer"                 },
    },
    processed = {
      { item = "Biotite Dust",                              via = "centrifuge"                 },
      { item = "Iron Dust",                                 via = "electrolyzer"               },
      { item = "Marble Dust",                               via = "centrifuge"                 },
      { item = "Metal Mixture Dust",                        via = "centrifuge"                 },
      { item = "Oxygen Cell",                               via = "centrifuge"                 },
      { item = "Platinum Metallic Powder Dust",             via = "centrifuge"                 },
      { item = "Potassium Feldspar Dust",                   via = "centrifuge"                 },
      { item = "Quartzite Dust",                            via = "centrifuge"                 },
      { item = "Sand",                                      via = "centrifuge"                 },
      { item = "Silicon Dioxide Dust",                      via = "electrolyzer"               },
      { item = "Sodalite Dust",                             via = "centrifuge"                 },
      { item = "Sulfur Dust",                               via = "electrolyzer"               },
      { item = "Tungstate Dust",                            via = "centrifuge"                 },
    },
  },
  ["Cosmic"] = {   -- cosmicAsteroid, drones 6..12, module tier 2
    drops = {
      { item = "Cosmic Neutronium Ore",                     chance =  2500 },
      { item = "Neutronium Ore",                            chance =  2500 },
      { item = "Black Plutonium Ore",                       chance =  2500 },
      { item = "Bedrockium Ore",                            chance =  2500 },
    },
    main = {
      { item = "Bedrockium Dust",                           via = "macerator"                  },
      { item = "Black Plutonium Dust",                      via = "macerator"                  },
      { item = "Cosmic Neutronium Dust",                    via = "macerator"                  },
      { item = "Endstone Dust",                             via = "macerator"                  },
      { item = "Neutronium Dust",                           via = "macerator"                  },
      { item = "Neutronium Nanoparticles",                  via = "macerator"                  },
      { item = "Quartz Sand",                               via = "macerator"                  },
      { item = "Stone Dust",                                via = "ore_washer"                 },
    },
    processed = {
      { item = "Biotite Dust",                              via = "centrifuge"                 },
      { item = "Marble Dust",                               via = "centrifuge"                 },
      { item = "Metal Mixture Dust",                        via = "centrifuge"                 },
      { item = "Pile of Cosmic Neutrons",                   via = "centrifuge"                 },
      { item = "Platinum Metallic Powder Dust",             via = "centrifuge"                 },
      { item = "Potassium Feldspar Dust",                   via = "centrifuge"                 },
      { item = "Quartzite Dust",                            via = "centrifuge"                 },
      { item = "Sand",                                      via = "centrifuge"                 },
      { item = "Silicon Dioxide Dust",                      via = "electrolyzer"               },
      { item = "Sodalite Dust",                             via = "centrifuge"                 },
      { item = "Tungstate Dust",                            via = "centrifuge"                 },
    },
  },
  ["Draconic"] = {   -- draconicAsteroid, drones 5..8, module tier 2
    drops = {
      { item = "Draconium Ore",                             chance =  6500 },
      { item = "Awakened Draconium Ore",                    chance =  2500 },
      { item = "Fluxed Electrum Ore",                       chance =  1000 },
    },
    main = {
      { item = "Awakened Draconium Dust",                   via = "macerator"                  },
      { item = "Draconium Dust",                            via = "macerator"                  },
      { item = "Endstone Dust",                             via = "macerator"                  },
      { item = "Fluxed Electrum Dust",                      via = "macerator"                  },
      { item = "Quartz Sand",                               via = "macerator"                  },
      { item = "Stone Dust",                                via = "ore_washer"                 },
    },
    processed = {
      { item = "Biotite Dust",                              via = "centrifuge"                 },
      { item = "Marble Dust",                               via = "centrifuge"                 },
      { item = "Metal Mixture Dust",                        via = "centrifuge"                 },
      { item = "Platinum Metallic Powder Dust",             via = "centrifuge"                 },
      { item = "Potassium Feldspar Dust",                   via = "centrifuge"                 },
      { item = "Quartzite Dust",                            via = "centrifuge"                 },
      { item = "Sand",                                      via = "centrifuge"                 },
      { item = "Silicon Dioxide Dust",                      via = "electrolyzer"               },
      { item = "Sodalite Dust",                             via = "centrifuge"                 },
      { item = "Tungstate Dust",                            via = "centrifuge"                 },
    },
  },
  ["Draconic Core"] = {   -- draconicCoreRuin, drones 8..10, module tier 3
    drops = {
      { item = "Draconic Core Schematic",                   chance =   100 },
      { item = "Draconic Core",                             chance =   100 },
      { item = "Zero Point Module",                         chance =  9800 },
    },
    main = {
      { item = "Draconic Core",                             via = "dropped directly"           },
      { item = "Draconic Core Schematic",                   via = "dropped directly"           },
      { item = "Zero Point Module",                         via = "dropped directly"           },
    },
    processed = {
    },
  },
  ["Europium"] = {   -- europiumAsteroid, drones 6..12, module tier 2
    drops = {
      { item = "Ledox Ore",                                 chance =  4000 },
      { item = "Callisto Ice Ore",                          chance =  4000 },
      { item = "Borax Ore",                                 chance =  1500 },
      { item = "Europium Ore",                              chance =   500 },
    },
    main = {
      { item = "Borax Dust",                                via = "macerator"                  },
      { item = "Callisto Ice Dust",                         via = "macerator"                  },
      { item = "Endstone Dust",                             via = "macerator"                  },
      { item = "Europium Dust",                             via = "macerator"                  },
      { item = "Ledox Dust",                                via = "macerator"                  },
      { item = "Quartz Sand",                               via = "macerator"                  },
      { item = "Sodium Hydroxide Dust",                     via = "chemical_bath"              },
      { item = "Stone Dust",                                via = "ore_washer"                 },
    },
    processed = {
      { item = "Biotite Dust",                              via = "centrifuge"                 },
      { item = "Boron Dust",                                via = "electrolyzer"               },
      { item = "Hydrogen Cell",                             via = "electrolyzer"               },
      { item = "Marble Dust",                               via = "centrifuge"                 },
      { item = "Metal Mixture Dust",                        via = "centrifuge"                 },
      { item = "Oxygen Cell",                               via = "electrolyzer"               },
      { item = "Platinum Metallic Powder Dust",             via = "centrifuge"                 },
      { item = "Potassium Feldspar Dust",                   via = "centrifuge"                 },
      { item = "Quartzite Dust",                            via = "centrifuge"                 },
      { item = "Sand",                                      via = "centrifuge"                 },
      { item = "Silicon Dioxide Dust",                      via = "electrolyzer"               },
      { item = "Sodalite Dust",                             via = "centrifuge"                 },
      { item = "Sodium Dust",                               via = "electrolyzer"               },
      { item = "Tungstate Dust",                            via = "centrifuge"                 },
      { item = "Water Cell",                                via = "electrolyzer"               },
    },
  },
  ["Everglades"] = {   -- evergladesAsteroid, drones 6..8, module tier 1
    drops = {
      { item = "Koboldite Ore",                             chance =   600 },
      { item = "Crocoite Ore",                              chance =   400 },
      { item = "Gadolinite (Y) Ore",                        chance =  1500 },
      { item = "Lepersonnite Ore",                          chance =  1500 },
      { item = "Zircon Ore",                                chance =  1000 },
      { item = "Lautarite Ore",                             chance =   400 },
      { item = "Honeaite Ore",                              chance =  1000 },
      { item = "Alburnite Ore",                             chance =   600 },
      { item = "Rare Earth (I) Ore",                        chance =  1000 },
      { item = "Rare Earth (II) Ore",                       chance =  1000 },
      { item = "Rare Earth (III) Ore",                      chance =  1000 },
    },
    main = {
      { item = "Alburnite Dust",                            via = "simple_washer"              },
      { item = "Calcium Dust",                              via = "macerator"                  },
      { item = "Cerium-Rich Mixture Dust",                  via = "macerator"                  },
      { item = "Chrome Dust",                               via = "thermal_centrifuge"         },
      { item = "Crocoite Dust",                             via = "simple_washer"              },
      { item = "Erbium Dust",                               via = "thermal_centrifuge"         },
      { item = "Gadolinite (Y) Dust",                       via = "simple_washer"              },
      { item = "Germanium Dust",                            via = "thermal_centrifuge"         },
      { item = "Gold Dust",                                 via = "macerator"                  },
      { item = "Honeaite Dust",                             via = "simple_washer"              },
      { item = "Impure Alburnite Dust",                     via = "macerator"                  },
      { item = "Impure Crocoite Dust",                      via = "macerator"                  },
      { item = "Impure Gadolinite (Y) Dust",                via = "macerator"                  },
      { item = "Impure Honeaite Dust",                      via = "macerator"                  },
      { item = "Impure Koboldite Dust",                     via = "macerator"                  },
      { item = "Impure Lautarite Dust",                     via = "macerator"                  },
      { item = "Impure Lepersonnite Dust",                  via = "macerator"                  },
      { item = "Impure Rare Earth (I) Dust",                via = "macerator"                  },
      { item = "Impure Rare Earth (II) Dust",               via = "macerator"                  },
      { item = "Impure Rare Earth (III) Dust",              via = "macerator"                  },
      { item = "Impure Zircon Dust",                        via = "macerator"                  },
      { item = "Iodine Dust",                               via = "thermal_centrifuge"         },
      { item = "Koboldite Dust",                            via = "simple_washer"              },
      { item = "Lautarite Dust",                            via = "simple_washer"              },
      { item = "Lead Dust",                                 via = "macerator"                  },
      { item = "Lepersonnite Dust",                         via = "simple_washer"              },
      { item = "Neodymium Dust",                            via = "thermal_centrifuge"         },
      { item = "Nether Quartz Dust",                        via = "macerator"                  },
      { item = "Nickel Dust",                               via = "macerator"                  },
      { item = "Rare Earth (I) Dust",                       via = "simple_washer"              },
      { item = "Rare Earth (II) Dust",                      via = "simple_washer"              },
      { item = "Rare Earth (III) Dust",                     via = "simple_washer"              },
      { item = "Raw Silicon Dust",                          via = "thermal_centrifuge"         },
      { item = "Runite Dust",                               via = "macerator"                  },
      { item = "Stone Dust",                                via = "macerator"                  },
      { item = "Thallium Dust",                             via = "thermal_centrifuge"         },
      { item = "Thaumium Dust",                             via = "thermal_centrifuge"         },
      { item = "Ytterbium Dust",                            via = "thermal_centrifuge"         },
      { item = "Yttrium Dust",                              via = "thermal_centrifuge"         },
      { item = "Zircon Dust",                               via = "simple_washer"              },
      { item = "Zirconium Dust",                            via = "macerator"                  },
    },
    processed = {
      { item = "Alumina Dust",                              via = "electrolyzer"               },
      { item = "Aluminium Dust",                            via = "electrolyzer"               },
      { item = "Banded Iron Dust",                          via = "centrifuge"                 },
      { item = "Barite Dust",                               via = "centrifuge"                 },
      { item = "Bauxite Dust",                              via = "centrifuge"                 },
      { item = "Biotite Dust",                              via = "centrifuge"                 },
      { item = "Calcite Dust",                              via = "centrifuge"                 },
      { item = "Chromite Dust",                             via = "centrifuge"                 },
      { item = "Ilmenite Dust",                             via = "centrifuge"                 },
      { item = "Magnesium Dust",                            via = "centrifuge"                 },
      { item = "Marble Dust",                               via = "centrifuge"                 },
      { item = "Metal Mixture Dust",                        via = "centrifuge"                 },
      { item = "Oxygen Cell",                               via = "electrolyzer"               },
      { item = "Potassium Dust",                            via = "electrolyzer"               },
      { item = "Potassium Feldspar Dust",                   via = "centrifuge"                 },
      { item = "Pyrolusite Dust",                           via = "centrifuge"                 },
      { item = "Quartzite Dust",                            via = "centrifuge"                 },
      { item = "Silicon Dioxide Dust",                      via = "electrolyzer"               },
      { item = "Sodalite Dust",                             via = "centrifuge"                 },
      { item = "Sodium Dust",                               via = "electrolyzer"               },
    },
  },
  ["Gem Ores"] = {   -- gemAsteroid, drones 0..5, module tier 1
    drops = {
      { item = "Ruby Ore",                                  chance =  1500 },
      { item = "Emerald Ore",                               chance =  1500 },
      { item = "Sapphire Ore",                              chance =  1500 },
      { item = "Green Sapphire Ore",                        chance =  1500 },
      { item = "Diamond Ore",                               chance =   750 },
      { item = "Opal Ore",                                  chance =   750 },
      { item = "Amethyst Ore",                              chance =   750 },
      { item = "Topaz Ore",                                 chance =  1000 },
      { item = "Blue Topaz Ore",                            chance =   500 },
      { item = "Bauxite Ore",                               chance =   500 },
      { item = "Vinteum Ore",                               chance =   400 },
      { item = "Nether Star Ore",                           chance =   100 },
    },
    main = {
      { item = "Alumina Dust",                              via = "macerator"                  },
      { item = "Amethyst",                                  via = "macerator"                  },
      { item = "Amethyst Dust",                             via = "macerator"                  },
      { item = "Bauxite Dust",                              via = "simple_washer"              },
      { item = "Beryllium Dust",                            via = "macerator"                  },
      { item = "Blue Topaz",                                via = "macerator"                  },
      { item = "Blue Topaz Dust",                           via = "macerator"                  },
      { item = "Chipped Amethyst",                          via = "sifter"                     },
      { item = "Chipped Blue Topaz",                        via = "sifter"                     },
      { item = "Chipped Diamond",                           via = "sifter"                     },
      { item = "Chipped Emerald",                           via = "sifter"                     },
      { item = "Chipped Green Sapphire",                    via = "sifter"                     },
      { item = "Chipped Opal",                              via = "sifter"                     },
      { item = "Chipped Ruby",                              via = "sifter"                     },
      { item = "Chipped Sapphire",                          via = "sifter"                     },
      { item = "Chipped Topaz",                             via = "sifter"                     },
      { item = "Chrome Dust",                               via = "macerator"                  },
      { item = "Diamond",                                   via = "sifter"                     },
      { item = "Diamond Dust",                              via = "simple_washer"              },
      { item = "Emerald",                                   via = "sifter"                     },
      { item = "Emerald Dust",                              via = "simple_washer"              },
      { item = "Endstone Dust",                             via = "macerator"                  },
      { item = "Exquisite Amethyst",                        via = "sifter"                     },
      { item = "Exquisite Blue Topaz",                      via = "sifter"                     },
      { item = "Exquisite Diamond",                         via = "sifter"                     },
      { item = "Exquisite Emerald",                         via = "sifter"                     },
      { item = "Exquisite Green Sapphire",                  via = "sifter"                     },
      { item = "Exquisite Opal",                            via = "sifter"                     },
      { item = "Exquisite Ruby",                            via = "sifter"                     },
      { item = "Exquisite Sapphire",                        via = "sifter"                     },
      { item = "Exquisite Topaz",                           via = "sifter"                     },
      { item = "Fiery Steel Dust",                          via = "chemical_bath"              },
      { item = "Flawed Amethyst",                           via = "sifter"                     },
      { item = "Flawed Blue Topaz",                         via = "sifter"                     },
      { item = "Flawed Diamond",                            via = "sifter"                     },
      { item = "Flawed Emerald",                            via = "sifter"                     },
      { item = "Flawed Green Sapphire",                     via = "sifter"                     },
      { item = "Flawed Opal",                               via = "sifter"                     },
      { item = "Flawed Ruby",                               via = "sifter"                     },
      { item = "Flawed Sapphire",                           via = "sifter"                     },
      { item = "Flawed Topaz",                              via = "sifter"                     },
      { item = "Flawless Amethyst",                         via = "sifter"                     },
      { item = "Flawless Blue Topaz",                       via = "sifter"                     },
      { item = "Flawless Diamond",                          via = "sifter"                     },
      { item = "Flawless Emerald",                          via = "sifter"                     },
      { item = "Flawless Green Sapphire",                   via = "sifter"                     },
      { item = "Flawless Opal",                             via = "sifter"                     },
      { item = "Flawless Ruby",                             via = "sifter"                     },
      { item = "Flawless Sapphire",                         via = "sifter"                     },
      { item = "Flawless Topaz",                            via = "sifter"                     },
      { item = "Gallium Dust",                              via = "macerator"                  },
      { item = "Graphite Dust",                             via = "macerator"                  },
      { item = "Green Sapphire",                            via = "sifter"                     },
      { item = "Green Sapphire Dust",                       via = "thermal_centrifuge"         },
      { item = "Grossular Dust",                            via = "macerator"                  },
      { item = "Nether Star",                               via = "macerator"                  },
      { item = "Nether Star Dust",                          via = "macerator"                  },
      { item = "Opal",                                      via = "sifter"                     },
      { item = "Opal Dust",                                 via = "simple_washer"              },
      { item = "Quantum Star",                              via = "chemical_bath"              },
      { item = "Quartz Sand",                               via = "macerator"                  },
      { item = "Red Garnet Dust",                           via = "thermal_centrifuge"         },
      { item = "Ruby",                                      via = "sifter"                     },
      { item = "Ruby Dust",                                 via = "simple_washer"              },
      { item = "Rutile Dust",                               via = "thermal_centrifuge"         },
      { item = "Sapphire",                                  via = "sifter"                     },
      { item = "Sapphire Dust",                             via = "thermal_centrifuge"         },
      { item = "Small Pile of Rutile Dust",                 via = "electromagnetic_separator"  },
      { item = "Stone Dust",                                via = "ore_washer"                 },
      { item = "Tanzanite",                                 via = "macerator"                  },
      { item = "Tanzanite Dust",                            via = "macerator"                  },
      { item = "Topaz",                                     via = "macerator"                  },
      { item = "Topaz Dust",                                via = "macerator"                  },
      { item = "Vinteum",                                   via = "macerator"                  },
      { item = "Vinteum Dust",                              via = "macerator"                  },
      { item = "Zirconium Nugget",                          via = "electromagnetic_separator"  },
    },
    processed = {
      { item = "Almandine Dust",                            via = "centrifuge"                 },
      { item = "Aluminium Dust",                            via = "electrolyzer"               },
      { item = "Biotite Dust",                              via = "centrifuge"                 },
      { item = "Calcite Dust",                              via = "centrifuge"                 },
      { item = "Calcium Dust",                              via = "electrolyzer"               },
      { item = "Carbon Dust",                               via = "electrolyzer"               },
      { item = "Gold Dust",                                 via = "centrifuge"                 },
      { item = "Hydrogen Cell",                             via = "electrolyzer"               },
      { item = "Iron Dust",                                 via = "centrifuge"                 },
      { item = "Marble Dust",                               via = "centrifuge"                 },
      { item = "Metal Mixture Dust",                        via = "centrifuge"                 },
      { item = "Oxygen Cell",                               via = "electrolyzer"               },
      { item = "Platinum Metallic Powder Dust",             via = "centrifuge"                 },
      { item = "Potassium Feldspar Dust",                   via = "centrifuge"                 },
      { item = "Pyrope Dust",                               via = "centrifuge"                 },
      { item = "Quartzite Dust",                            via = "centrifuge"                 },
      { item = "Quicklime Dust",                            via = "centrifuge"                 },
      { item = "Sand",                                      via = "centrifuge"                 },
      { item = "Silicon Dioxide Dust",                      via = "electrolyzer"               },
      { item = "Sodalite Dust",                             via = "centrifuge"                 },
      { item = "Spessartine Dust",                          via = "centrifuge"                 },
      { item = "Thaumium Dust",                             via = "centrifuge"                 },
      { item = "Tungstate Dust",                            via = "centrifuge"                 },
      { item = "Vanadium Dust",                             via = "centrifuge"                 },
    },
  },
  ["Holmium/Samarium"] = {   -- holmiumSamariumAsteroid, drones 7..12, module tier 2
    drops = {
      { item = "Holmium Ore",                               chance =  2000 },
      { item = "Samarium Ore",                              chance =  3000 },
      { item = "Tiberium Ore",                              chance =  3000 },
      { item = "Strontium Ore",                             chance =  2000 },
    },
    main = {
      { item = "Chipped Tiberium",                          via = "sifter"                     },
      { item = "Exquisite Tiberium",                        via = "sifter"                     },
      { item = "Flawed Tiberium",                           via = "sifter"                     },
      { item = "Flawless Tiberium",                         via = "sifter"                     },
      { item = "Holmium Dust",                              via = "macerator"                  },
      { item = "Samarium Ore Concentrate Dust",             via = "macerator"                  },
      { item = "Stone Dust",                                via = "macerator"                  },
      { item = "Strontium Dust",                            via = "macerator"                  },
      { item = "Tiberium",                                  via = "macerator"                  },
      { item = "Tiberium Dust",                             via = "macerator"                  },
    },
    processed = {
      { item = "Alumina Dust",                              via = "electrolyzer"               },
      { item = "Aluminium Dust",                            via = "electrolyzer"               },
      { item = "Banded Iron Dust",                          via = "centrifuge"                 },
      { item = "Barite Dust",                               via = "centrifuge"                 },
      { item = "Bauxite Dust",                              via = "centrifuge"                 },
      { item = "Biotite Dust",                              via = "centrifuge"                 },
      { item = "Calcite Dust",                              via = "centrifuge"                 },
      { item = "Chromite Dust",                             via = "centrifuge"                 },
      { item = "Ilmenite Dust",                             via = "centrifuge"                 },
      { item = "Magnesium Dust",                            via = "centrifuge"                 },
      { item = "Marble Dust",                               via = "centrifuge"                 },
      { item = "Metal Mixture Dust",                        via = "centrifuge"                 },
      { item = "Oxygen Cell",                               via = "electrolyzer"               },
      { item = "Potassium Dust",                            via = "electrolyzer"               },
      { item = "Potassium Feldspar Dust",                   via = "centrifuge"                 },
      { item = "Pyrolusite Dust",                           via = "centrifuge"                 },
      { item = "Quartzite Dust",                            via = "centrifuge"                 },
      { item = "Raw Silicon Dust",                          via = "electrolyzer"               },
      { item = "Silicon Dioxide Dust",                      via = "electrolyzer"               },
      { item = "Sodalite Dust",                             via = "centrifuge"                 },
      { item = "Sodium Dust",                               via = "electrolyzer"               },
    },
  },
  ["Ichorium"] = {   -- ichoriumAsteroid, drones 9..12, module tier 3
    drops = {
      { item = "Shadow Iron Ore",                           chance =  4500 },
      { item = "Meteoric Iron Ore",                         chance =  3000 },
      { item = "Ichorium Ore",                              chance =  1500 },
      { item = "Desh Ore",                                  chance =   500 },
      { item = "Americium Ore",                             chance =   500 },
    },
    main = {
      { item = "Americium Dust",                            via = "macerator"                  },
      { item = "Desh Dust",                                 via = "macerator"                  },
      { item = "Endstone Dust",                             via = "macerator"                  },
      { item = "Fiery Steel Dust",                          via = "chemical_bath"              },
      { item = "Ichorium Dust",                             via = "macerator"                  },
      { item = "Iridium Metal Residue Dust",                via = "macerator"                  },
      { item = "Iron Dust",                                 via = "macerator"                  },
      { item = "Meteoric Iron Dust",                        via = "simple_washer"              },
      { item = "Nickel Dust",                               via = "thermal_centrifuge"         },
      { item = "Platinum Metallic Powder Dust",             via = "chemical_bath"              },
      { item = "Quartz Sand",                               via = "macerator"                  },
      { item = "Shadow Iron Dust",                          via = "simple_washer"              },
      { item = "Stone Dust",                                via = "ore_washer"                 },
    },
    processed = {
      { item = "Biotite Dust",                              via = "centrifuge"                 },
      { item = "Marble Dust",                               via = "centrifuge"                 },
      { item = "Metal Mixture Dust",                        via = "centrifuge"                 },
      { item = "Potassium Feldspar Dust",                   via = "centrifuge"                 },
      { item = "Quartzite Dust",                            via = "centrifuge"                 },
      { item = "Sand",                                      via = "centrifuge"                 },
      { item = "Silicon Dioxide Dust",                      via = "electrolyzer"               },
      { item = "Sodalite Dust",                             via = "centrifuge"                 },
      { item = "Tungstate Dust",                            via = "centrifuge"                 },
    },
  },
  ["Indium"] = {   -- indiumAsteroid, drones 4..9, module tier 2
    drops = {
      { item = "Indium Ore",                                chance =  6000 },
      { item = "Sphalerite Ore",                            chance =  2000 },
      { item = "Zinc Ore",                                  chance =  1000 },
      { item = "Cadmium Ore",                               chance =  1000 },
    },
    main = {
      { item = "Cadmium Dust",                              via = "macerator"                  },
      { item = "Endstone Dust",                             via = "macerator"                  },
      { item = "Gallium Dust",                              via = "thermal_centrifuge"         },
      { item = "Indium Dust",                               via = "macerator"                  },
      { item = "Quartz Sand",                               via = "macerator"                  },
      { item = "Sphalerite Dust",                           via = "simple_washer"              },
      { item = "Stone Dust",                                via = "ore_washer"                 },
      { item = "Tin Dust",                                  via = "macerator"                  },
      { item = "Yellow Garnet",                             via = "macerator"                  },
      { item = "Yellow Garnet Dust",                        via = "macerator"                  },
      { item = "Zinc Dust",                                 via = "chemical_bath"              },
    },
    processed = {
      { item = "Andradite Dust",                            via = "centrifuge"                 },
      { item = "Biotite Dust",                              via = "centrifuge"                 },
      { item = "Grossular Dust",                            via = "centrifuge"                 },
      { item = "Marble Dust",                               via = "centrifuge"                 },
      { item = "Metal Mixture Dust",                        via = "centrifuge"                 },
      { item = "Platinum Metallic Powder Dust",             via = "centrifuge"                 },
      { item = "Potassium Feldspar Dust",                   via = "centrifuge"                 },
      { item = "Quartzite Dust",                            via = "centrifuge"                 },
      { item = "Sand",                                      via = "centrifuge"                 },
      { item = "Silicon Dioxide Dust",                      via = "electrolyzer"               },
      { item = "Sodalite Dust",                             via = "centrifuge"                 },
      { item = "Tungstate Dust",                            via = "centrifuge"                 },
      { item = "Uvarovite Dust",                            via = "centrifuge"                 },
    },
  },
  ["Infinity Catalyst"] = {   -- infinityCatalystAsteroid, drones 7..12, module tier 2
    drops = {
      { item = "Infinity Catalyst Ore",                     chance =  5000 },
      { item = "Cosmic Neutronium Ore",                     chance =  3000 },
      { item = "Neutronium Ore",                            chance =  2000 },
    },
    main = {
      { item = "Cosmic Neutronium Dust",                    via = "macerator"                  },
      { item = "Endstone Dust",                             via = "macerator"                  },
      { item = "Infinity Catalyst Dust",                    via = "macerator"                  },
      { item = "Neutronium Dust",                           via = "macerator"                  },
      { item = "Neutronium Nanoparticles",                  via = "macerator"                  },
      { item = "Quartz Sand",                               via = "macerator"                  },
      { item = "Stone Dust",                                via = "ore_washer"                 },
    },
    processed = {
      { item = "Biotite Dust",                              via = "centrifuge"                 },
      { item = "Marble Dust",                               via = "centrifuge"                 },
      { item = "Metal Mixture Dust",                        via = "centrifuge"                 },
      { item = "Platinum Metallic Powder Dust",             via = "centrifuge"                 },
      { item = "Potassium Feldspar Dust",                   via = "centrifuge"                 },
      { item = "Quartzite Dust",                            via = "centrifuge"                 },
      { item = "Sand",                                      via = "centrifuge"                 },
      { item = "Silicon Dioxide Dust",                      via = "electrolyzer"               },
      { item = "Sodalite Dust",                             via = "centrifuge"                 },
      { item = "Tungstate Dust",                            via = "centrifuge"                 },
    },
  },
  ["Iron"] = {   -- ironAsteroid, drones 0..6, module tier 1
    drops = {
      { item = "Iron Ore",                                  chance =  4000 },
      { item = "Gold Ore",                                  chance =  2000 },
      { item = "Magnetite Ore",                             chance =  1000 },
      { item = "Pyrite Ore",                                chance =  1000 },
      { item = "Basaltic Mineral Sand",                     chance =   500 },
      { item = "Granitic Mineral Sand",                     chance =   500 },
    },
    main = {
      { item = "Basalt Dust",                               via = "macerator"                  },
      { item = "Basaltic Mineral Sand",                     via = "simple_washer"              },
      { item = "Black Granite Dust",                        via = "macerator"                  },
      { item = "Copper Dust",                               via = "macerator"                  },
      { item = "Endstone Dust",                             via = "macerator"                  },
      { item = "Fiery Steel Dust",                          via = "chemical_bath"              },
      { item = "Gold Dust",                                 via = "chemical_bath"              },
      { item = "Granitic Mineral Sand",                     via = "simple_washer"              },
      { item = "Ground Basaltic Mineral Sand",              via = "macerator"                  },
      { item = "Ground Granitic Mineral Sand",              via = "macerator"                  },
      { item = "Iron Dust",                                 via = "macerator"                  },
      { item = "Magnetite Dust",                            via = "thermal_centrifuge"         },
      { item = "Nickel Dust",                               via = "macerator"                  },
      { item = "Pyrite Dust",                               via = "simple_washer"              },
      { item = "Quartz Sand",                               via = "macerator"                  },
      { item = "Small Pile of Zircon Dust",                 via = "electromagnetic_separator"  },
      { item = "Stone Dust",                                via = "ore_washer"                 },
      { item = "Sulfur Dust",                               via = "macerator"                  },
      { item = "Tin Dust",                                  via = "thermal_centrifuge"         },
      { item = "Tiny Pile of Zircon Dust",                  via = "electromagnetic_separator"  },
      { item = "Tricalcium Phosphate Dust",                 via = "thermal_centrifuge"         },
    },
    processed = {
      { item = "Alumina Dust",                              via = "electrolyzer"               },
      { item = "Ashes",                                     via = "centrifuge"                 },
      { item = "Biotite Dust",                              via = "centrifuge"                 },
      { item = "Calcite Dust",                              via = "centrifuge"                 },
      { item = "Calcium Dust",                              via = "centrifuge"                 },
      { item = "Carbon Dust",                               via = "electrolyzer"               },
      { item = "Dark Ashes",                                via = "centrifuge"                 },
      { item = "Flint Dust",                                via = "centrifuge"                 },
      { item = "Magnesium Dust",                            via = "electrolyzer"               },
      { item = "Marble Dust",                               via = "centrifuge"                 },
      { item = "Metal Mixture Dust",                        via = "centrifuge"                 },
      { item = "Olivine Dust",                              via = "centrifuge"                 },
      { item = "Oxygen Cell",                               via = "electrolyzer"               },
      { item = "Phosphate Dust",                            via = "centrifuge"                 },
      { item = "Platinum Metallic Powder Dust",             via = "centrifuge"                 },
      { item = "Potassium Dust",                            via = "electrolyzer"               },
      { item = "Potassium Feldspar Dust",                   via = "centrifuge"                 },
      { item = "Quartzite Dust",                            via = "centrifuge"                 },
      { item = "Raw Silicon Dust",                          via = "electrolyzer"               },
      { item = "Sand",                                      via = "centrifuge"                 },
      { item = "Silicon Dioxide Dust",                      via = "centrifuge"                 },
      { item = "Sodalite Dust",                             via = "centrifuge"                 },
      { item = "Tungstate Dust",                            via = "centrifuge"                 },
    },
  },
  ["Lanthanum"] = {   -- lanthanumAsteroid, drones 4..10, module tier 2
    drops = {
      { item = "Trinium Ore",                               chance =  1500 },
      { item = "Lanthanum Ore",                             chance =  2000 },
      { item = "Orundum Ore",                               chance =  3000 },
      { item = "Silver Ore",                                chance =  3500 },
    },
    main = {
      { item = "Chipped Orundum",                           via = "sifter"                     },
      { item = "Exquisite Orundum",                         via = "sifter"                     },
      { item = "Flawed Orundum",                            via = "sifter"                     },
      { item = "Flawless Orundum",                          via = "sifter"                     },
      { item = "Lanthanum Dust",                            via = "macerator"                  },
      { item = "Lead Dust",                                 via = "macerator"                  },
      { item = "Orundum",                                   via = "macerator"                  },
      { item = "Orundum Dust",                              via = "macerator"                  },
      { item = "Silver Dust",                               via = "chemical_bath"              },
      { item = "Stone Dust",                                via = "macerator"                  },
      { item = "Sulfur Dust",                               via = "thermal_centrifuge"         },
      { item = "Trinium Dust",                              via = "macerator"                  },
    },
    processed = {
      { item = "Alumina Dust",                              via = "electrolyzer"               },
      { item = "Aluminium Dust",                            via = "electrolyzer"               },
      { item = "Banded Iron Dust",                          via = "centrifuge"                 },
      { item = "Barite Dust",                               via = "centrifuge"                 },
      { item = "Bauxite Dust",                              via = "centrifuge"                 },
      { item = "Biotite Dust",                              via = "centrifuge"                 },
      { item = "Calcite Dust",                              via = "centrifuge"                 },
      { item = "Chromite Dust",                             via = "centrifuge"                 },
      { item = "Ilmenite Dust",                             via = "centrifuge"                 },
      { item = "Magnesium Dust",                            via = "centrifuge"                 },
      { item = "Marble Dust",                               via = "centrifuge"                 },
      { item = "Metal Mixture Dust",                        via = "centrifuge"                 },
      { item = "Oxygen Cell",                               via = "electrolyzer"               },
      { item = "Potassium Dust",                            via = "electrolyzer"               },
      { item = "Potassium Feldspar Dust",                   via = "centrifuge"                 },
      { item = "Pyrolusite Dust",                           via = "centrifuge"                 },
      { item = "Quartzite Dust",                            via = "centrifuge"                 },
      { item = "Raw Silicon Dust",                          via = "electrolyzer"               },
      { item = "Silicon Dioxide Dust",                      via = "electrolyzer"               },
      { item = "Sodalite Dust",                             via = "centrifuge"                 },
      { item = "Sodium Dust",                               via = "electrolyzer"               },
    },
  },
  ["Lead"] = {   -- leadAsteroid, drones 0..7, module tier 1
    drops = {
      { item = "Lead Ore",                                  chance =  3000 },
      { item = "Arsenic Ore",                               chance =  2500 },
      { item = "Barium Ore",                                chance =  2500 },
      { item = "Lepidolite Ore",                            chance =  2000 },
    },
    main = {
      { item = "Arsenic Dust",                              via = "macerator"                  },
      { item = "Barium Dust",                               via = "macerator"                  },
      { item = "Caesium Dust",                              via = "thermal_centrifuge"         },
      { item = "Cryolite Dust",                             via = "chemical_bath"              },
      { item = "Endstone Dust",                             via = "macerator"                  },
      { item = "Lead Dust",                                 via = "simple_washer"              },
      { item = "Lepidolite Dust",                           via = "simple_washer"              },
      { item = "Lithium Chloride Dust",                     via = "chemical_bath"              },
      { item = "Lithium Dust",                              via = "macerator"                  },
      { item = "Quartz Sand",                               via = "macerator"                  },
      { item = "Rock Salt",                                 via = "chemical_bath"              },
      { item = "Silver Dust",                               via = "macerator"                  },
      { item = "Stone Dust",                                via = "ore_washer"                 },
      { item = "Sulfur Dust",                               via = "thermal_centrifuge"         },
    },
    processed = {
      { item = "Biotite Dust",                              via = "centrifuge"                 },
      { item = "Marble Dust",                               via = "centrifuge"                 },
      { item = "Metal Mixture Dust",                        via = "centrifuge"                 },
      { item = "Platinum Metallic Powder Dust",             via = "centrifuge"                 },
      { item = "Potassium Feldspar Dust",                   via = "centrifuge"                 },
      { item = "Quartzite Dust",                            via = "centrifuge"                 },
      { item = "Sand",                                      via = "centrifuge"                 },
      { item = "Silicon Dioxide Dust",                      via = "electrolyzer"               },
      { item = "Sodalite Dust",                             via = "centrifuge"                 },
      { item = "Tungstate Dust",                            via = "centrifuge"                 },
    },
  },
  ["Lutetium"] = {   -- lutetiumAsteroid, drones 4..8, module tier 1
    drops = {
      { item = "Tellurium Ore",                             chance =  1500 },
      { item = "Thulium Ore",                               chance =  1000 },
      { item = "Tantalum Ore",                              chance =  1500 },
      { item = "Lutetium Ore",                              chance =   500 },
      { item = "Redstone Ore",                              chance =  5500 },
    },
    main = {
      { item = "Cinnabar Dust",                             via = "macerator"                  },
      { item = "Endstone Dust",                             via = "macerator"                  },
      { item = "Glowstone Dust",                            via = "macerator"                  },
      { item = "Lutetium Dust",                             via = "macerator"                  },
      { item = "Quartz Sand",                               via = "macerator"                  },
      { item = "Rare Earth",                                via = "thermal_centrifuge"         },
      { item = "Redstone",                                  via = "simple_washer"              },
      { item = "Stone Dust",                                via = "ore_washer"                 },
      { item = "Tantalum Dust",                             via = "macerator"                  },
      { item = "Tellurium Dust",                            via = "macerator"                  },
      { item = "Thulium Dust",                              via = "macerator"                  },
    },
    processed = {
      { item = "Biotite Dust",                              via = "centrifuge"                 },
      { item = "Marble Dust",                               via = "centrifuge"                 },
      { item = "Metal Mixture Dust",                        via = "centrifuge"                 },
      { item = "Platinum Metallic Powder Dust",             via = "centrifuge"                 },
      { item = "Potassium Feldspar Dust",                   via = "centrifuge"                 },
      { item = "Quartzite Dust",                            via = "centrifuge"                 },
      { item = "Sand",                                      via = "centrifuge"                 },
      { item = "Silicon Dioxide Dust",                      via = "electrolyzer"               },
      { item = "Sodalite Dust",                             via = "centrifuge"                 },
      { item = "Sulfur Dust",                               via = "centrifuge"                 },
      { item = "Tungstate Dust",                            via = "centrifuge"                 },
    },
  },
  ["Magnesium"] = {   -- magnesiumAsteroid, drones 3..8, module tier 1
    drops = {
      { item = "Magnesium Ore",                             chance =  4000 },
      { item = "Manganese Ore",                             chance =  3000 },
      { item = "Fluorspar Ore",                             chance =  3000 },
    },
    main = {
      { item = "Chipped Fluorspar",                         via = "sifter"                     },
      { item = "Chrome Dust",                               via = "macerator"                  },
      { item = "Exquisite Fluorspar",                       via = "sifter"                     },
      { item = "Fiery Steel Dust",                          via = "chemical_bath"              },
      { item = "Flawed Fluorspar",                          via = "sifter"                     },
      { item = "Flawless Fluorspar",                        via = "sifter"                     },
      { item = "Fluorspar",                                 via = "macerator"                  },
      { item = "Fluorspar Dust",                            via = "macerator"                  },
      { item = "Iron Dust",                                 via = "thermal_centrifuge"         },
      { item = "Magnesium Dust",                            via = "simple_washer"              },
      { item = "Manganese Dust",                            via = "simple_washer"              },
      { item = "Olivine",                                   via = "macerator"                  },
      { item = "Olivine Dust",                              via = "macerator"                  },
      { item = "Stone Dust",                                via = "macerator"                  },
    },
    processed = {
      { item = "Alumina Dust",                              via = "electrolyzer"               },
      { item = "Aluminium Dust",                            via = "electrolyzer"               },
      { item = "Banded Iron Dust",                          via = "centrifuge"                 },
      { item = "Barite Dust",                               via = "centrifuge"                 },
      { item = "Bauxite Dust",                              via = "centrifuge"                 },
      { item = "Biotite Dust",                              via = "centrifuge"                 },
      { item = "Calcite Dust",                              via = "centrifuge"                 },
      { item = "Calcium Dust",                              via = "electrolyzer"               },
      { item = "Chromite Dust",                             via = "centrifuge"                 },
      { item = "Ilmenite Dust",                             via = "centrifuge"                 },
      { item = "Marble Dust",                               via = "centrifuge"                 },
      { item = "Metal Mixture Dust",                        via = "centrifuge"                 },
      { item = "Oxygen Cell",                               via = "electrolyzer"               },
      { item = "Potassium Dust",                            via = "electrolyzer"               },
      { item = "Potassium Feldspar Dust",                   via = "centrifuge"                 },
      { item = "Pyrolusite Dust",                           via = "centrifuge"                 },
      { item = "Quartzite Dust",                            via = "centrifuge"                 },
      { item = "Raw Silicon Dust",                          via = "electrolyzer"               },
      { item = "Silicon Dioxide Dust",                      via = "electrolyzer"               },
      { item = "Sodalite Dust",                             via = "centrifuge"                 },
      { item = "Sodium Dust",                               via = "electrolyzer"               },
    },
  },
  ["Mysterious Crystal"] = {   -- mysteriousCrystalAsteroid, drones 4..12, module tier 1
    drops = {
      { item = "Mysterious Crystal Ore",                    chance =  7400 },
      { item = "Mytryl Ore",                                chance =  2000 },
      { item = "Oriharukon Ore",                            chance =   500 },
      { item = "Endium Ore",                                chance =    98 },
      { item = "End Powder Ore",                            chance =     2 },
    },
    main = {
      { item = "End Powder",                                via = "macerator"                  },
      { item = "Endium Dust",                               via = "macerator"                  },
      { item = "Endstone Dust",                             via = "macerator"                  },
      { item = "Mysterious Crystal Dust",                   via = "macerator"                  },
      { item = "Mytryl Dust",                               via = "simple_washer"              },
      { item = "Oriharukon Dust",                           via = "macerator"                  },
      { item = "Quartz Sand",                               via = "macerator"                  },
      { item = "Samarium Ore Concentrate Dust",             via = "macerator"                  },
      { item = "Stone Dust",                                via = "ore_washer"                 },
      { item = "Zinc Dust",                                 via = "thermal_centrifuge"         },
    },
    processed = {
      { item = "Biotite Dust",                              via = "centrifuge"                 },
      { item = "Marble Dust",                               via = "centrifuge"                 },
      { item = "Metal Mixture Dust",                        via = "centrifuge"                 },
      { item = "Platinum Metallic Powder Dust",             via = "centrifuge"                 },
      { item = "Potassium Feldspar Dust",                   via = "centrifuge"                 },
      { item = "Quartzite Dust",                            via = "centrifuge"                 },
      { item = "Sand",                                      via = "centrifuge"                 },
      { item = "Silicon Dioxide Dust",                      via = "electrolyzer"               },
      { item = "Small Pile of Endium Dust",                 via = "centrifuge"                 },
      { item = "Sodalite Dust",                             via = "centrifuge"                 },
      { item = "Tiny Pile of Endereye Dust",                via = "centrifuge"                 },
      { item = "Tungstate Dust",                            via = "centrifuge"                 },
    },
  },
  ["Naquadah"] = {   -- naquadahAsteroid, drones 4..7, module tier 1
    drops = {
      { item = "Naquadah Oxide Mixture Ore",                chance =  4000 },
      { item = "Enriched-Naquadah Oxide Mixture Ore",       chance =  3500 },
      { item = "Naquadria Oxide Mixture Ore",               chance =  2500 },
    },
    main = {
      { item = "Enriched-Naquadah Oxide Mixture Dust",      via = "macerator"                  },
      { item = "Naquadah Oxide Mixture Dust",               via = "macerator"                  },
      { item = "Naquadria Oxide Mixture Dust",              via = "macerator"                  },
      { item = "Stone Dust",                                via = "macerator"                  },
    },
    processed = {
      { item = "Alumina Dust",                              via = "electrolyzer"               },
      { item = "Aluminium Dust",                            via = "electrolyzer"               },
      { item = "Banded Iron Dust",                          via = "centrifuge"                 },
      { item = "Barite Dust",                               via = "centrifuge"                 },
      { item = "Bauxite Dust",                              via = "centrifuge"                 },
      { item = "Biotite Dust",                              via = "centrifuge"                 },
      { item = "Calcite Dust",                              via = "centrifuge"                 },
      { item = "Chromite Dust",                             via = "centrifuge"                 },
      { item = "Ilmenite Dust",                             via = "centrifuge"                 },
      { item = "Indium Phosphate Dust",                     via = "centrifuge"                 },
      { item = "Low Quality Naquadria Phosphate Dust",      via = "centrifuge"                 },
      { item = "Magnesium Dust",                            via = "centrifuge"                 },
      { item = "Marble Dust",                               via = "centrifuge"                 },
      { item = "Metal Mixture Dust",                        via = "centrifuge"                 },
      { item = "Oxygen Cell",                               via = "electrolyzer"               },
      { item = "Potassium Dust",                            via = "electrolyzer"               },
      { item = "Potassium Feldspar Dust",                   via = "centrifuge"                 },
      { item = "Pyrolusite Dust",                           via = "centrifuge"                 },
      { item = "Quartzite Dust",                            via = "centrifuge"                 },
      { item = "Raw Silicon Dust",                          via = "electrolyzer"               },
      { item = "Silicon Dioxide Dust",                      via = "electrolyzer"               },
      { item = "Sodalite Dust",                             via = "centrifuge"                 },
      { item = "Sodium Dust",                               via = "electrolyzer"               },
    },
  },
  ["Nether Ores"] = {   -- NetherOreAsteroid, drones 3..6, module tier 1
    drops = {
      { item = "Nether Quartz Ore",                         chance =  3000 },
      { item = "Sulfur Ore",                                chance =  3000 },
      { item = "Certus Quartz Ore",                         chance =  2000 },
      { item = "Quartzite Ore",                             chance =  1500 },
      { item = "Firestone Ore",                             chance =   500 },
    },
    main = {
      { item = "Barite Dust",                               via = "thermal_centrifuge"         },
      { item = "Barium Dust",                               via = "chemical_bath"              },
      { item = "Certus Quartz",                             via = "macerator"                  },
      { item = "Certus Quartz Dust",                        via = "macerator"                  },
      { item = "Firestone Dust",                            via = "macerator"                  },
      { item = "Hydrated Coal Dust",                        via = "chemical_bath"              },
      { item = "Nether Quartz",                             via = "sifter"                     },
      { item = "Nether Quartz Dust",                        via = "simple_washer"              },
      { item = "Netherrack Dust",                           via = "macerator"                  },
      { item = "Quartzite",                                 via = "macerator"                  },
      { item = "Quartzite Dust",                            via = "macerator"                  },
      { item = "Raw Firestone",                             via = "macerator"                  },
      { item = "Stone Dust",                                via = "ore_washer"                 },
      { item = "Sulfur Dust",                               via = "macerator"                  },
      { item = "Tiberium",                                  via = "chemical_bath"              },
      { item = "Tiberium Dust",                             via = "macerator"                  },
    },
    processed = {
      { item = "Biotite Dust",                              via = "centrifuge"                 },
      { item = "Carbon Dust",                               via = "electrolyzer"               },
      { item = "Coal Dust",                                 via = "centrifuge"                 },
      { item = "Gold Dust",                                 via = "centrifuge"                 },
      { item = "Marble Dust",                               via = "centrifuge"                 },
      { item = "Metal Mixture Dust",                        via = "centrifuge"                 },
      { item = "Potassium Feldspar Dust",                   via = "centrifuge"                 },
      { item = "Pyrite Dust",                               via = "centrifuge"                 },
      { item = "Raw Silicon Dust",                          via = "centrifuge"                 },
      { item = "Redstone",                                  via = "centrifuge"                 },
      { item = "Ruby Dust",                                 via = "centrifuge"                 },
      { item = "Sodalite Dust",                             via = "centrifuge"                 },
    },
  },
  ["Nickel"] = {   -- nickelAsteroid, drones 0..4, module tier 1
    drops = {
      { item = "Nickel Ore",                                chance =  4000 },
      { item = "Pentlandite Ore",                           chance =  3000 },
      { item = "Garnierite Ore",                            chance =  3000 },
    },
    main = {
      { item = "Cobalt Dust",                               via = "macerator"                  },
      { item = "Endstone Dust",                             via = "macerator"                  },
      { item = "Fiery Steel Dust",                          via = "chemical_bath"              },
      { item = "Garnierite Dust",                           via = "simple_washer"              },
      { item = "Iron Dust",                                 via = "macerator"                  },
      { item = "Nickel Dust",                               via = "macerator"                  },
      { item = "Pentlandite Dust",                          via = "simple_washer"              },
      { item = "Platinum Metallic Powder Dust",             via = "thermal_centrifuge"         },
      { item = "Quartz Sand",                               via = "macerator"                  },
      { item = "Stone Dust",                                via = "ore_washer"                 },
      { item = "Sulfur Dust",                               via = "thermal_centrifuge"         },
    },
    processed = {
      { item = "Biotite Dust",                              via = "centrifuge"                 },
      { item = "Marble Dust",                               via = "centrifuge"                 },
      { item = "Metal Mixture Dust",                        via = "centrifuge"                 },
      { item = "Potassium Feldspar Dust",                   via = "centrifuge"                 },
      { item = "Quartzite Dust",                            via = "centrifuge"                 },
      { item = "Sand",                                      via = "centrifuge"                 },
      { item = "Silicon Dioxide Dust",                      via = "electrolyzer"               },
      { item = "Sodalite Dust",                             via = "centrifuge"                 },
      { item = "Tungstate Dust",                            via = "centrifuge"                 },
    },
  },
  ["Niobium"] = {   -- niobiumAsteroid, drones 4..8, module tier 1
    drops = {
      { item = "Niobium Ore",                               chance =  3000 },
      { item = "Quantium Ore",                              chance =  2000 },
      { item = "Ytterbium Ore",                             chance =  1500 },
      { item = "Yttrium Ore",                               chance =  3500 },
    },
    main = {
      { item = "Endstone Dust",                             via = "macerator"                  },
      { item = "Niobium Dust",                              via = "macerator"                  },
      { item = "Quantium Dust",                             via = "macerator"                  },
      { item = "Quartz Sand",                               via = "macerator"                  },
      { item = "Stone Dust",                                via = "ore_washer"                 },
      { item = "Ytterbium Dust",                            via = "macerator"                  },
      { item = "Yttrium Dust",                              via = "macerator"                  },
    },
    processed = {
      { item = "Biotite Dust",                              via = "centrifuge"                 },
      { item = "Marble Dust",                               via = "centrifuge"                 },
      { item = "Metal Mixture Dust",                        via = "centrifuge"                 },
      { item = "Platinum Metallic Powder Dust",             via = "centrifuge"                 },
      { item = "Potassium Feldspar Dust",                   via = "centrifuge"                 },
      { item = "Quartzite Dust",                            via = "centrifuge"                 },
      { item = "Sand",                                      via = "centrifuge"                 },
      { item = "Silicon Dioxide Dust",                      via = "electrolyzer"               },
      { item = "Sodalite Dust",                             via = "centrifuge"                 },
      { item = "Tungstate Dust",                            via = "centrifuge"                 },
    },
  },
  ["Phosphate"] = {   -- phosphateAsteroid, drones 4..10, module tier 1
    drops = {
      { item = "Phosphate Ore",                             chance =  4500 },
      { item = "Tricalcium Phosphate Ore",                  chance =  2500 },
      { item = "Sulfur Ore",                                chance =  3000 },
      { item = "Apatite Ore",                               chance =  3000 },
    },
    main = {
      { item = "Apatite",                                   via = "macerator"                  },
      { item = "Apatite Dust",                              via = "macerator"                  },
      { item = "Endstone Dust",                             via = "macerator"                  },
      { item = "Phosphate Dust",                            via = "thermal_centrifuge"         },
      { item = "Phosphorus Dust",                           via = "macerator"                  },
      { item = "Pyrochlore Dust",                           via = "macerator"                  },
      { item = "Quartz Sand",                               via = "macerator"                  },
      { item = "Stone Dust",                                via = "ore_washer"                 },
      { item = "Sulfur Dust",                               via = "macerator"                  },
      { item = "Tricalcium Phosphate",                      via = "macerator"                  },
      { item = "Tricalcium Phosphate Dust",                 via = "macerator"                  },
    },
    processed = {
      { item = "Biotite Dust",                              via = "centrifuge"                 },
      { item = "Calcium Dust",                              via = "electrolyzer"               },
      { item = "Marble Dust",                               via = "centrifuge"                 },
      { item = "Metal Mixture Dust",                        via = "centrifuge"                 },
      { item = "Platinum Metallic Powder Dust",             via = "centrifuge"                 },
      { item = "Potassium Feldspar Dust",                   via = "centrifuge"                 },
      { item = "Quartzite Dust",                            via = "centrifuge"                 },
      { item = "Sand",                                      via = "centrifuge"                 },
      { item = "Silicon Dioxide Dust",                      via = "electrolyzer"               },
      { item = "Sodalite Dust",                             via = "centrifuge"                 },
      { item = "Tungstate Dust",                            via = "centrifuge"                 },
    },
  },
  ["PlatLine Dust"] = {   -- platlinePureAsteroid, drones 6..9, module tier 3
    drops = {
      { item = "Platinum Dust",                             chance =  3800 },
      { item = "Palladium Dust",                            chance =  2000 },
      { item = "Iridium Dust",                              chance =  1500 },
      { item = "Osmium Dust",                               chance =   500 },
      { item = "Ruthenium Dust",                            chance =  1200 },
      { item = "Rhodium Dust",                              chance =  1000 },
    },
    main = {
      { item = "Iridium Dust",                              via = "dropped directly"           },
      { item = "Osmium Dust",                               via = "dropped directly"           },
      { item = "Palladium Dust",                            via = "dropped directly"           },
      { item = "Platinum Dust",                             via = "dropped directly"           },
      { item = "Rhodium Dust",                              via = "dropped directly"           },
      { item = "Ruthenium Dust",                            via = "dropped directly"           },
    },
    processed = {
    },
  },
  ["PlatLine Ore"] = {   -- platlineOreAsteroid, drones 2..6, module tier 1
    drops = {
      { item = "Platinum Ore",                              chance =  6000 },
      { item = "Palladium Ore",                             chance =  2000 },
      { item = "Iridium Ore",                               chance =  1500 },
      { item = "Osmium Ore",                                chance =   500 },
    },
    main = {
      { item = "Endstone Dust",                             via = "macerator"                  },
      { item = "Iridium Metal Residue Dust",                via = "macerator"                  },
      { item = "Nickel Dust",                               via = "macerator"                  },
      { item = "Palladium Metallic Powder Dust",            via = "macerator"                  },
      { item = "Platinum Metallic Powder Dust",             via = "macerator"                  },
      { item = "Quartz Sand",                               via = "macerator"                  },
      { item = "Rarest Metal Residue Dust",                 via = "thermal_centrifuge"         },
      { item = "Stone Dust",                                via = "ore_washer"                 },
    },
    processed = {
      { item = "Biotite Dust",                              via = "centrifuge"                 },
      { item = "Marble Dust",                               via = "centrifuge"                 },
      { item = "Metal Mixture Dust",                        via = "centrifuge"                 },
      { item = "Potassium Feldspar Dust",                   via = "centrifuge"                 },
      { item = "Quartzite Dust",                            via = "centrifuge"                 },
      { item = "Sand",                                      via = "centrifuge"                 },
      { item = "Silicon Dioxide Dust",                      via = "electrolyzer"               },
      { item = "Sodalite Dust",                             via = "centrifuge"                 },
      { item = "Tungstate Dust",                            via = "centrifuge"                 },
    },
  },
  ["Quartz"] = {   -- quartzAsteroid, drones 1..6, module tier 1
    drops = {
      { item = "Quartzite Ore",                             chance =  3000 },
      { item = "Certus Quartz Ore",                         chance =  2250 },
      { item = "Nether Quartz Ore",                         chance =  2250 },
      { item = "Vanadium Ore",                              chance =  2500 },
    },
    main = {
      { item = "Barite Dust",                               via = "thermal_centrifuge"         },
      { item = "Barium Dust",                               via = "chemical_bath"              },
      { item = "Certus Quartz",                             via = "macerator"                  },
      { item = "Certus Quartz Dust",                        via = "macerator"                  },
      { item = "Endstone Dust",                             via = "macerator"                  },
      { item = "Hydrated Coal Dust",                        via = "chemical_bath"              },
      { item = "Nether Quartz",                             via = "sifter"                     },
      { item = "Nether Quartz Dust",                        via = "simple_washer"              },
      { item = "Netherrack Dust",                           via = "macerator"                  },
      { item = "Quartz Sand",                               via = "macerator"                  },
      { item = "Quartzite",                                 via = "macerator"                  },
      { item = "Quartzite Dust",                            via = "macerator"                  },
      { item = "Stone Dust",                                via = "ore_washer"                 },
      { item = "Vanadium Dust",                             via = "macerator"                  },
    },
    processed = {
      { item = "Biotite Dust",                              via = "centrifuge"                 },
      { item = "Carbon Dust",                               via = "electrolyzer"               },
      { item = "Coal Dust",                                 via = "centrifuge"                 },
      { item = "Gold Dust",                                 via = "centrifuge"                 },
      { item = "Marble Dust",                               via = "centrifuge"                 },
      { item = "Metal Mixture Dust",                        via = "centrifuge"                 },
      { item = "Platinum Metallic Powder Dust",             via = "centrifuge"                 },
      { item = "Potassium Feldspar Dust",                   via = "centrifuge"                 },
      { item = "Pyrite Dust",                               via = "centrifuge"                 },
      { item = "Raw Silicon Dust",                          via = "centrifuge"                 },
      { item = "Redstone",                                  via = "centrifuge"                 },
      { item = "Ruby Dust",                                 via = "centrifuge"                 },
      { item = "Sand",                                      via = "centrifuge"                 },
      { item = "Silicon Dioxide Dust",                      via = "electrolyzer"               },
      { item = "Sodalite Dust",                             via = "centrifuge"                 },
      { item = "Sulfur Dust",                               via = "centrifuge"                 },
      { item = "Tungstate Dust",                            via = "centrifuge"                 },
    },
  },
  ["Salt"] = {   -- saltAsteroid, drones 0..4, module tier 1
    drops = {
      { item = "Salt Ore",                                  chance =  4000 },
      { item = "Rock Salt Ore",                             chance =  2000 },
      { item = "Saltpeter Ore",                             chance =  4000 },
    },
    main = {
      { item = "Borax Dust",                                via = "thermal_centrifuge"         },
      { item = "Chipped Rock Salt",                         via = "sifter"                     },
      { item = "Chipped Salt",                              via = "sifter"                     },
      { item = "Endstone Dust",                             via = "macerator"                  },
      { item = "Exquisite Rock Salt",                       via = "sifter"                     },
      { item = "Exquisite Salt",                            via = "sifter"                     },
      { item = "Flawed Rock Salt",                          via = "sifter"                     },
      { item = "Flawed Salt",                               via = "sifter"                     },
      { item = "Flawless Rock Salt",                        via = "sifter"                     },
      { item = "Flawless Salt",                             via = "sifter"                     },
      { item = "Quartz Sand",                               via = "macerator"                  },
      { item = "Rock Salt",                                 via = "macerator"                  },
      { item = "Salt",                                      via = "macerator"                  },
      { item = "Saltpeter Dust",                            via = "macerator"                  },
      { item = "Stone Dust",                                via = "ore_washer"                 },
    },
    processed = {
      { item = "Biotite Dust",                              via = "centrifuge"                 },
      { item = "Boron Dust",                                via = "electrolyzer"               },
      { item = "Marble Dust",                               via = "centrifuge"                 },
      { item = "Metal Mixture Dust",                        via = "centrifuge"                 },
      { item = "Oxygen Cell",                               via = "electrolyzer"               },
      { item = "Platinum Metallic Powder Dust",             via = "centrifuge"                 },
      { item = "Potassium Dust",                            via = "electrolyzer"               },
      { item = "Potassium Feldspar Dust",                   via = "centrifuge"                 },
      { item = "Quartzite Dust",                            via = "centrifuge"                 },
      { item = "Sand",                                      via = "centrifuge"                 },
      { item = "Silicon Dioxide Dust",                      via = "electrolyzer"               },
      { item = "Sodalite Dust",                             via = "centrifuge"                 },
      { item = "Sodium Dust",                               via = "electrolyzer"               },
      { item = "Tungstate Dust",                            via = "centrifuge"                 },
      { item = "Water Cell",                                via = "electrolyzer"               },
    },
  },
  ["Silicon"] = {   -- siliconAsteroid, drones 2..5, module tier 2
    drops = {
      { item = "Mica Ore",                                  chance =  2000 },
      { item = "Raw Silicon Ore",                           chance =  4500 },
      { item = "Silicon Solar Grade (Poly SI) Ore",         chance =  2500 },
    },
    main = {
      { item = "Endstone Dust",                             via = "macerator"                  },
      { item = "Mica Dust",                                 via = "macerator"                  },
      { item = "Quartz Sand",                               via = "macerator"                  },
      { item = "Raw Silicon Dust",                          via = "macerator"                  },
      { item = "Silicon Solar Grade (Poly SI) Dust",        via = "macerator"                  },
      { item = "Stone Dust",                                via = "ore_washer"                 },
    },
    processed = {
      { item = "Alumina Dust",                              via = "electrolyzer"               },
      { item = "Aluminium Dust",                            via = "electrolyzer"               },
      { item = "Biotite Dust",                              via = "centrifuge"                 },
      { item = "Marble Dust",                               via = "centrifuge"                 },
      { item = "Metal Mixture Dust",                        via = "centrifuge"                 },
      { item = "Oxygen Cell",                               via = "electrolyzer"               },
      { item = "Platinum Metallic Powder Dust",             via = "centrifuge"                 },
      { item = "Potassium Dust",                            via = "electrolyzer"               },
      { item = "Potassium Feldspar Dust",                   via = "centrifuge"                 },
      { item = "Quartzite Dust",                            via = "centrifuge"                 },
      { item = "Sand",                                      via = "centrifuge"                 },
      { item = "Silicon Dioxide Dust",                      via = "electrolyzer"               },
      { item = "Sodalite Dust",                             via = "centrifuge"                 },
      { item = "Tungstate Dust",                            via = "centrifuge"                 },
    },
  },
  ["Space Ores"] = {   -- spaceOreAsteroid, drones 5..7, module tier 1
    drops = {
      { item = "Meteoric Iron Ore",                         chance =  2000 },
      { item = "Deep Iron Ore",                             chance =  2000 },
      { item = "Mytryl Ore",                                chance =  2000 },
      { item = "Black Plutonium Ore",                       chance =  1000 },
      { item = "Callisto Ice Ore",                          chance =  2000 },
      { item = "Ledox Ore",                                 chance =  2000 },
      { item = "Alduorite Ore",                             chance =  3000 },
      { item = "Rubracium Ore",                             chance =  3000 },
      { item = "Vulcanite Ore",                             chance =  3000 },
      { item = "Vyroxeres Ore",                             chance =  3000 },
      { item = "Ceruclase Ore",                             chance =  3000 },
      { item = "Orichalcum Ore",                            chance =  3000 },
    },
    main = {
      { item = "Alduorite Dust",                            via = "macerator"                  },
      { item = "Black Plutonium Dust",                      via = "macerator"                  },
      { item = "Callisto Ice Dust",                         via = "macerator"                  },
      { item = "Ceruclase Dust",                            via = "macerator"                  },
      { item = "Deep Iron Dust",                            via = "simple_washer"              },
      { item = "Endstone Dust",                             via = "macerator"                  },
      { item = "Fiery Steel Dust",                          via = "chemical_bath"              },
      { item = "Iridium Metal Residue Dust",                via = "macerator"                  },
      { item = "Iron Dust",                                 via = "macerator"                  },
      { item = "Ledox Dust",                                via = "macerator"                  },
      { item = "Meteoric Iron Dust",                        via = "simple_washer"              },
      { item = "Mytryl Dust",                               via = "simple_washer"              },
      { item = "Nickel Dust",                               via = "thermal_centrifuge"         },
      { item = "Orichalcum Dust",                           via = "macerator"                  },
      { item = "Platinum Metallic Powder Dust",             via = "chemical_bath"              },
      { item = "Quartz Sand",                               via = "macerator"                  },
      { item = "Rubracium Dust",                            via = "simple_washer"              },
      { item = "Samarium Ore Concentrate Dust",             via = "macerator"                  },
      { item = "Stone Dust",                                via = "ore_washer"                 },
      { item = "Trinium Dust",                              via = "macerator"                  },
      { item = "Vulcanite Dust",                            via = "macerator"                  },
      { item = "Vyroxeres Dust",                            via = "macerator"                  },
      { item = "Zinc Dust",                                 via = "thermal_centrifuge"         },
    },
    processed = {
      { item = "Biotite Dust",                              via = "centrifuge"                 },
      { item = "Marble Dust",                               via = "centrifuge"                 },
      { item = "Metal Mixture Dust",                        via = "centrifuge"                 },
      { item = "Pile of Cosmic Neutrons",                   via = "centrifuge"                 },
      { item = "Potassium Feldspar Dust",                   via = "centrifuge"                 },
      { item = "Quartzite Dust",                            via = "centrifuge"                 },
      { item = "Sand",                                      via = "centrifuge"                 },
      { item = "Silicon Dioxide Dust",                      via = "electrolyzer"               },
      { item = "Sodalite Dust",                             via = "centrifuge"                 },
      { item = "Tungstate Dust",                            via = "centrifuge"                 },
    },
  },
  ["Tengam"] = {   -- tengamAsteroid, drones 9..12, module tier 3
    drops = {
      { item = "Dilithium Ore",                             chance =   100 },
      { item = "Orundum Ore",                               chance =  1650 },
      { item = "Vanadium Ore",                              chance =  3500 },
      { item = "Ytterbium Ore",                             chance =  2250 },
      { item = "Raw Tengam Ore",                            chance =  2500 },
    },
    main = {
      { item = "Chipped Orundum",                           via = "sifter"                     },
      { item = "Dilithium",                                 via = "macerator"                  },
      { item = "Dilithium Dust",                            via = "macerator"                  },
      { item = "Exquisite Orundum",                         via = "sifter"                     },
      { item = "Flawed Orundum",                            via = "sifter"                     },
      { item = "Flawless Orundum",                          via = "sifter"                     },
      { item = "Magnetic Neodymium Dust",                   via = "macerator"                  },
      { item = "Magnetic Samarium Dust",                    via = "thermal_centrifuge"         },
      { item = "Orundum",                                   via = "macerator"                  },
      { item = "Orundum Dust",                              via = "macerator"                  },
      { item = "Raw Tengam Dust",                           via = "simple_washer"              },
      { item = "Stone Dust",                                via = "macerator"                  },
      { item = "Vanadium Dust",                             via = "macerator"                  },
      { item = "Ytterbium Dust",                            via = "macerator"                  },
    },
    processed = {
      { item = "Alumina Dust",                              via = "electrolyzer"               },
      { item = "Aluminium Dust",                            via = "electrolyzer"               },
      { item = "Banded Iron Dust",                          via = "centrifuge"                 },
      { item = "Barite Dust",                               via = "centrifuge"                 },
      { item = "Bauxite Dust",                              via = "centrifuge"                 },
      { item = "Biotite Dust",                              via = "centrifuge"                 },
      { item = "Calcite Dust",                              via = "centrifuge"                 },
      { item = "Chromite Dust",                             via = "centrifuge"                 },
      { item = "Ilmenite Dust",                             via = "centrifuge"                 },
      { item = "Magnesium Dust",                            via = "centrifuge"                 },
      { item = "Marble Dust",                               via = "centrifuge"                 },
      { item = "Metal Mixture Dust",                        via = "centrifuge"                 },
      { item = "Neodymium Dust",                            via = "electrolyzer"               },
      { item = "Oxygen Cell",                               via = "electrolyzer"               },
      { item = "Potassium Dust",                            via = "electrolyzer"               },
      { item = "Potassium Feldspar Dust",                   via = "centrifuge"                 },
      { item = "Pyrolusite Dust",                           via = "centrifuge"                 },
      { item = "Quartzite Dust",                            via = "centrifuge"                 },
      { item = "Raw Silicon Dust",                          via = "electrolyzer"               },
      { item = "Samarium Dust",                             via = "electrolyzer"               },
      { item = "Silicon Dioxide Dust",                      via = "electrolyzer"               },
      { item = "Sodalite Dust",                             via = "centrifuge"                 },
      { item = "Sodium Dust",                               via = "electrolyzer"               },
    },
  },
  ["Thaumium Dusts"] = {   -- thaumiumAsteroid, drones 2..5, module tier 1
    drops = {
      { item = "Thaumium Dust",                             chance =  6000 },
      { item = "Void Metal Dust",                           chance =  4000 },
    },
    main = {
      { item = "Thaumium Dust",                             via = "dropped directly"           },
      { item = "Void Metal Dust",                           via = "dropped directly"           },
    },
    processed = {
    },
  },
  ["Tin"] = {   -- tinAsteroid, drones 0..4, module tier 1
    drops = {
      { item = "Cassiterite Ore",                           chance =  2000 },
      { item = "Cassiterite Sand",                          chance =  1500 },
      { item = "Tin Ore",                                   chance =  6000 },
      { item = "Asbestos Ore",                              chance =   500 },
    },
    main = {
      { item = "Asbestos Dust",                             via = "macerator"                  },
      { item = "Cassiterite Dust",                          via = "simple_washer"              },
      { item = "Cassiterite Sand",                          via = "simple_washer"              },
      { item = "Endstone Dust",                             via = "macerator"                  },
      { item = "Fiery Steel Dust",                          via = "chemical_bath"              },
      { item = "Ground Cassiterite Sand",                   via = "macerator"                  },
      { item = "Iron Dust",                                 via = "macerator"                  },
      { item = "Quartz Sand",                               via = "macerator"                  },
      { item = "Silicon Dioxide Dust",                      via = "thermal_centrifuge"         },
      { item = "Small Pile of Zircon Dust",                 via = "electromagnetic_separator"  },
      { item = "Stone Dust",                                via = "ore_washer"                 },
      { item = "Tin Dust",                                  via = "macerator"                  },
      { item = "Tiny Pile of Zircon Dust",                  via = "electromagnetic_separator"  },
      { item = "Zinc Dust",                                 via = "thermal_centrifuge"         },
      { item = "Zirconium Dust",                            via = "sifter"                     },
    },
    processed = {
      { item = "Biotite Dust",                              via = "centrifuge"                 },
      { item = "Magnesium Dust",                            via = "electrolyzer"               },
      { item = "Marble Dust",                               via = "centrifuge"                 },
      { item = "Metal Mixture Dust",                        via = "centrifuge"                 },
      { item = "Oxygen Cell",                               via = "electrolyzer"               },
      { item = "Platinum Metallic Powder Dust",             via = "centrifuge"                 },
      { item = "Potassium Feldspar Dust",                   via = "centrifuge"                 },
      { item = "Quartzite Dust",                            via = "centrifuge"                 },
      { item = "Raw Silicon Dust",                          via = "electrolyzer"               },
      { item = "Sand",                                      via = "centrifuge"                 },
      { item = "Sodalite Dust",                             via = "centrifuge"                 },
      { item = "Tungstate Dust",                            via = "centrifuge"                 },
    },
  },
  ["Tungsten-Titanium"] = {   -- tungstenTitaniumAsteroid, drones 0..5, module tier 1
    drops = {
      { item = "Tungsten Ore",                              chance =  3000 },
      { item = "Titanium Ore",                              chance =  3000 },
      { item = "Neodymium Ore",                             chance =  2000 },
      { item = "Molybdenum Ore",                            chance =  1500 },
      { item = "Tungstate Ore",                             chance =   500 },
    },
    main = {
      { item = "Almandine Dust",                            via = "macerator"                  },
      { item = "Endstone Dust",                             via = "macerator"                  },
      { item = "Fiery Steel Dust",                          via = "chemical_bath"              },
      { item = "Lithium Dust",                              via = "macerator"                  },
      { item = "Manganese Dust",                            via = "macerator"                  },
      { item = "Molybdenum Dust",                           via = "macerator"                  },
      { item = "Monazite",                                  via = "macerator"                  },
      { item = "Monazite Dust",                             via = "macerator"                  },
      { item = "Neodymium Dust",                            via = "simple_washer"              },
      { item = "Quartz Sand",                               via = "macerator"                  },
      { item = "Rare Earth",                                via = "thermal_centrifuge"         },
      { item = "Silver Dust",                               via = "thermal_centrifuge"         },
      { item = "Stone Dust",                                via = "ore_washer"                 },
      { item = "Titanium Dust",                             via = "simple_washer"              },
      { item = "Tungsten Dust",                             via = "simple_washer"              },
    },
    processed = {
      { item = "Alumina Dust",                              via = "centrifuge"                 },
      { item = "Aluminium Dust",                            via = "electrolyzer"               },
      { item = "Biotite Dust",                              via = "centrifuge"                 },
      { item = "Calcite Dust",                              via = "centrifuge"                 },
      { item = "Calcium Dust",                              via = "electrolyzer"               },
      { item = "Carbon Dust",                               via = "electrolyzer"               },
      { item = "Chrome Dust",                               via = "centrifuge"                 },
      { item = "Gold Dust",                                 via = "centrifuge"                 },
      { item = "Iron Dust",                                 via = "centrifuge"                 },
      { item = "Marble Dust",                               via = "centrifuge"                 },
      { item = "Metal Mixture Dust",                        via = "centrifuge"                 },
      { item = "Phosphate Dust",                            via = "electrolyzer"               },
      { item = "Platinum Metallic Powder Dust",             via = "centrifuge"                 },
      { item = "Potassium Feldspar Dust",                   via = "centrifuge"                 },
      { item = "Quartzite Dust",                            via = "centrifuge"                 },
      { item = "Sand",                                      via = "centrifuge"                 },
      { item = "Silicon Dioxide Dust",                      via = "electrolyzer"               },
      { item = "Sodalite Dust",                             via = "centrifuge"                 },
      { item = "Tungstate Dust",                            via = "centrifuge"                 },
      { item = "Vanadium Dust",                             via = "centrifuge"                 },
    },
  },
  ["Uranium-Plutonium"] = {   -- uraniumPlutoniumAsteroid, drones 2..6, module tier 1
    drops = {
      { item = "Uranium 238 Ore",                           chance =  3000 },
      { item = "Uranium 235 Ore",                           chance =  2450 },
      { item = "Plutonium 239 Ore",                         chance =  2450 },
      { item = "Plutonium 241 Ore",                         chance =  2000 },
      { item = "Thorianite Ore",                            chance =   100 },
    },
    main = {
      { item = "Lead Dust",                                 via = "macerator"                  },
      { item = "Plutonium 241 Dust",                        via = "macerator"                  },
      { item = "Radium 226 Dust",                           via = "sifter"                     },
      { item = "Stone Dust",                                via = "macerator"                  },
      { item = "Thorianite Dust",                           via = "simple_washer"              },
      { item = "Thorium Dust",                              via = "macerator"                  },
      { item = "Uranium 235 Dust",                          via = "macerator"                  },
      { item = "Uranium 238 Dust",                          via = "macerator"                  },
    },
    processed = {
      { item = "Alumina Dust",                              via = "electrolyzer"               },
      { item = "Aluminium Dust",                            via = "electrolyzer"               },
      { item = "Banded Iron Dust",                          via = "centrifuge"                 },
      { item = "Barite Dust",                               via = "centrifuge"                 },
      { item = "Bauxite Dust",                              via = "centrifuge"                 },
      { item = "Biotite Dust",                              via = "centrifuge"                 },
      { item = "Calcite Dust",                              via = "centrifuge"                 },
      { item = "Chromite Dust",                             via = "centrifuge"                 },
      { item = "Ilmenite Dust",                             via = "centrifuge"                 },
      { item = "Magnesium Dust",                            via = "centrifuge"                 },
      { item = "Marble Dust",                               via = "centrifuge"                 },
      { item = "Metal Mixture Dust",                        via = "centrifuge"                 },
      { item = "Oxygen Cell",                               via = "electrolyzer"               },
      { item = "Plutonium 239 Dust",                        via = "centrifuge"                 },
      { item = "Potassium Dust",                            via = "electrolyzer"               },
      { item = "Potassium Feldspar Dust",                   via = "centrifuge"                 },
      { item = "Pyrolusite Dust",                           via = "centrifuge"                 },
      { item = "Quartzite Dust",                            via = "centrifuge"                 },
      { item = "Raw Silicon Dust",                          via = "electrolyzer"               },
      { item = "Silicon Dioxide Dust",                      via = "electrolyzer"               },
      { item = "Sodalite Dust",                             via = "centrifuge"                 },
      { item = "Sodium Dust",                               via = "electrolyzer"               },
      { item = "Thorium 232 Dust",                          via = "centrifuge"                 },
      { item = "Tiny Pile of Plutonium 241 Dust",           via = "centrifuge"                 },
      { item = "Tiny Pile of Uranium 238 Dust",             via = "centrifuge"                 },
    },
  },
}

--------------------------------------------------------------------------------
-- 8. DUST TARGET REGISTRY
-- Maps each tracked dust/item name to its source asteroid and a priority value.
-- Broker uses this to resolve: "dust X is low → mine asteroid Y".
-- Multiple dusts can share the same asteroid (e.g. all Cosmic outputs).
-- Add or remove entries freely; only items listed in config.conditions
-- will actually trigger mining jobs.
--
-- PRIORITY — how it works (read this before tuning the numbers):
--   * LOWER number = HIGHER priority = mined first. (0 beats 1 beats 10.)
--     Think "1st place, 2nd place" — #1 is most important.
--   * Convention used here: 0 = highest, up to 10 = lowest. It's just a
--     convention — the broker only compares relatively, so any integers work,
--     but keeping to 0–10 stays readable.
--   * No priority set on an entry?  It defaults to 99 (sinks to the bottom).
--   * Priority ONLY matters in "Rarity" boot mode (mine most-important first,
--     ties broken by fill level). In the default "Threshold" mode priority is
--     IGNORED — the broker just mines whatever is furthest below its target.
--     So if you want these numbers to do anything, pick Rarity at startup.
--------------------------------------------------------------------------------
config.dustTargets = {
  -- === TOP TIER — MK-III EXCLUSIVES (UIV+ DRONE REQUIRED) ===
  ["Ichorium Dust"]           = { asteroid = "Ichorium", priority = 1 },
  ["Draconic Core"]             = { asteroid = "Draconic Core", priority = 1 },   -- was: Draconic Core Dust -> Draconic Core
  ["Raw Tengam Dust"]         = { asteroid = "Tengam", priority = 1 },
  -- "PlatLine Dust" was listed here as an item. It is not one: it is the
  -- asteroid's own name. platlinePureAsteroid uses OrePrefixes.dust over
  -- Platinum/Palladium/Iridium/Osmium/Ruthenium/Rhodium, and Ruthenium and
  -- Rhodium are what it yields that PlatLine Ore does not -- neither had an
  -- entry, so that MK-III asteroid was unreachable.
  ["Ruthenium Dust"]          = { asteroid = "PlatLine Dust", priority = 1 },
  ["Rhodium Dust"]            = { asteroid = "PlatLine Dust", priority = 2 },

  -- === EXOTICS — UHV ERA AND ABOVE ===
  ["Mysterious Crystal Dust"] = { asteroid = "Mysterious Crystal", priority = 1 },
  ["Cosmic Neutronium Dust"]  = { asteroid = "Cosmic", priority = 1 },
  ["Draconium Dust"]          = { asteroid = "Draconic", priority = 1 },
  ["Awakened Draconium Dust"] = { asteroid = "Draconic", priority = 2 },
  ["Fluxed Electrum Dust"]    = { asteroid = "Cosmic", priority = 2 },
  ["Neutronium Dust"]         = { asteroid = "Cosmic", priority = 3 },
  ["Bedrockium Dust"]         = { asteroid = "Cosmic", priority = 4 },
  ["Black Plutonium Dust"]    = { asteroid = "Cosmic", priority = 5 },
  ["Infinity Catalyst Dust"]  = { asteroid = "Infinity Catalyst", priority = 1 },
  --  ["Staballoy Dust"] = { asteroid = "Everglades", priority = 1 },
  --  ["Kleinite Dust"] = { asteroid = "Draconic", priority = 3 },

  -- === RARE EARTH & LANTHANIDE PROCESSING LINE ===
  ["Trinium Dust"]            = { asteroid = "Lanthanum", priority = 1 },
  ["Lanthanum Dust"]          = { asteroid = "Lanthanum", priority = 2 },
  --  ["Cerium Dust"] = { asteroid = "Aluminium-LanthLine", priority = 3 },
  --  ["Praseodymium Dust"] = { asteroid = "Lanthanum", priority = 3 },
  ["Neodymium Dust"]          = { asteroid = "Aluminium-LanthLine", priority = 4 },
  --  ["Promethium Dust"] = { asteroid = "Lanthanum", priority = 4 },
  ["Samarium Dust"]           = { asteroid = "Holmium/Samarium", priority = 1 },
  ["Europium Dust"]           = { asteroid = "Europium", priority = 3 },
  --  ["Gadolinium Dust"] = { asteroid = "Everglades", priority = 5 },
  --  ["Terbium Dust"] = { asteroid = "Everglades", priority = 6 },
  --  ["Dysprosium Dust"] = { asteroid = "Holmium/Samarium", priority = 3 },
  ["Holmium Dust"]            = { asteroid = "Holmium/Samarium", priority = 2 },
  ["Erbium Dust"]             = { asteroid = "Holmium/Samarium", priority = 4 },
  ["Thulium Dust"]            = { asteroid = "Holmium/Samarium", priority = 5 },
  ["Ytterbium Dust"]          = { asteroid = "Holmium/Samarium", priority = 6 },
  ["Lutetium Dust"]           = { asteroid = "Lutetium", priority = 1 },

  -- === RARE EARTH INTERMEDIATE PRODUCTS ===
  ["Rare Earth (I) Dust"]       = { asteroid = "Everglades", priority = 2 },   -- was: Rare Earth I Dust -> Aluminium-LanthLine
  ["Rare Earth (II) Dust"]      = { asteroid = "Everglades", priority = 2 },   -- was: Rare Earth II Dust -> Holmium/Samarium
  ["Rare Earth (III) Dust"]     = { asteroid = "Everglades", priority = 3 },   -- was: Rare Earth III Dust -> Everglades
  ["Rare Earth (I) Ore"]        = { asteroid = "Everglades", priority = 2 },   -- was: Rare Earth I Ore -> Aluminium-LanthLine
  ["Rare Earth (II) Ore"]       = { asteroid = "Everglades", priority = 2 },   -- was: Rare Earth II Ore -> Holmium/Samarium
  ["Rare Earth (III) Ore"]      = { asteroid = "Everglades", priority = 3 },   -- was: Rare Earth III Ore -> Everglades

  -- === METALLIC RESOURCES — STANDARD PROCESSING ORES ===
  ["Adamantium Dust"]         = { asteroid = "Adamantium", priority = 1 },
  ["Bismuth Dust"]            = { asteroid = "Adamantium", priority = 2 },
  ["Antimony Dust"]           = { asteroid = "Adamantium", priority = 3 },
  ["Gallium Dust"]            = { asteroid = "Adamantium", priority = 4 },
  ["Lithium Dust"]            = { asteroid = "Adamantium", priority = 5 },
  ["Aluminium Dust"]          = { asteroid = "Aluminium", priority = 1 },
  ["Bauxite Dust"]            = { asteroid = "Aluminium", priority = 2 },
  ["Rutile Dust"]             = { asteroid = "Aluminium", priority = 3 },
  ["Crushed Monazite Ore"]    = { asteroid = "Aluminium-LanthLine", priority = 1 },
  ["Crushed Bastnasite Ore"]  = { asteroid = "Aluminium-LanthLine", priority = 2 },
  ["Cobalt Dust"]             = { asteroid = "Ardite/Cobalt", priority = 1 },
  ["Ardite Dust"]             = { asteroid = "Ardite/Cobalt", priority = 2 },
  ["Manyullyn Dust"]          = { asteroid = "Ardite/Cobalt", priority = 3 },
  ["Chrome Dust"]             = { asteroid = "Chrome", priority = 1 },
  ["Ruby Dust"]               = { asteroid = "Chrome", priority = 2 },
  ["Copper Dust"]             = { asteroid = "Copper", priority = 1 },
  ["Nickel Dust"]             = { asteroid = "Nickel", priority = 1 },
  ["Iron Dust"]               = { asteroid = "Iron", priority = 1 },
  ["Lead Dust"]               = { asteroid = "Lead", priority = 1 },
  ["Tin Dust"]                = { asteroid = "Tin", priority = 1 },
  ["Zinc Dust"]               = { asteroid = "Copper", priority = 2 },
  --  ["Invar Dust"] = { asteroid = "Nickel", priority = 2 },
  ["Platinum Ore"]            = { asteroid = "PlatLine Ore", priority = 1 },
  ["Palladium Dust"]          = { asteroid = "PlatLine Ore", priority = 2 },
  ["Osmium Dust"]             = { asteroid = "PlatLine Ore", priority = 3 },
  ["Tiberium Dust"]           = { asteroid = "Holmium/Samarium", priority = 4 },
  ["Iridium Dust"]            = { asteroid = "PlatLine Ore", priority = 4 },
  --  ["Galena Dust"] = { asteroid = "Lead", priority = 4 },
  ["Sphalerite Dust"]         = { asteroid = "Copper", priority = 3 },
  ["Pyrite Dust"]             = { asteroid = "Iron", priority = 2 },
  ["Bauxite Ore"]             = { asteroid = "Aluminium", priority = 2 },
  ["Monazite Ore"]            = { asteroid = "Aluminium-LanthLine", priority = 1 },
  ["Bastnasite Ore"]          = { asteroid = "Aluminium-LanthLine", priority = 2 },
  --  ["Soldering Alloy Dust"] = { asteroid = "Lead", priority = 2 },
  --  ["Battery Alloy Dust"] = { asteroid = "Lead", priority = 3 },

  -- === INDUSTRIAL MATERIALS, THAUMCRAFT & GEM ORES ===
  ["Clay"]                      = { asteroid = "Clay", priority = 1 },   -- was: Clay Block -> Clay
  ["Magnesium Dust"]          = { asteroid = "Magnesium", priority = 1 },
  ["Niobium Dust"]            = { asteroid = "Niobium", priority = 1 },
  ["Phosphate Dust"]          = { asteroid = "Phosphate", priority = 1 },
  --  ["Quartz Dust"] = { asteroid = "Quartz", priority = 1 },
  ["Salt"]                    = { asteroid = "Salt", priority = 1 },
  ["Saltpeter Dust"]          = { asteroid = "Salt", priority = 2 },
  --  ["Silicon Dust"] = { asteroid = "Silicon", priority = 1 },
  ["Thaumium Dust"]           = { asteroid = "Thaumium Dusts", priority = 1 },
  ["Tungsten Dust"]           = { asteroid = "Tungsten-Titanium", priority = 1 },
  ["Manganese Dust"]          = { asteroid = "Tungsten-Titanium", priority = 2 },
  ["Titanium Dust"]           = { asteroid = "Tungsten-Titanium", priority = 3 },
  ["Coal Dust"]               = { asteroid = "Coal", priority = 10 },
  ["Graphite Dust"]           = { asteroid = "Coal", priority = 10 },
  --  ["Graphene Dust"] = { asteroid = "Coal", priority = 10 },
  ["Diamond"]                 = { asteroid = "Gem Ores", priority = 1 },
  ["Nether Star"]             = { asteroid = "Gem Ores", priority = 2 },
  ["Diamond Dust"]            = { asteroid = "Gem Ores", priority = 3 },
  ["Emerald Dust"]            = { asteroid = "Gem Ores", priority = 4 },
  ["Certus Quartz Dust"]      = { asteroid = "Quartz", priority = 5 },
  ["Nether Quartz Dust"]      = { asteroid = "Quartz", priority = 6 },
  ["Sapphire Dust"]           = { asteroid = "Gem Ores", priority = 7 },
  ["Green Sapphire Dust"]     = { asteroid = "Gem Ores", priority = 8 },
  ["Olivine Dust"]            = { asteroid = "Gem Ores", priority = 9 },
  ["Ledox Dust"]              = { asteroid = "Europium", priority = 1 },
  ["Callisto Ice Dust"]       = { asteroid = "Europium", priority = 2 },
  ["Borax Dust"]              = { asteroid = "Europium", priority = 4 },

  -- === NUCLEAR MATERIALS & NAQUADAH LINE ===
  ["Uranium 235 Dust"]        = { asteroid = "Uranium-Plutonium", priority = 2 },
  ["Uranium 238 Dust"]        = { asteroid = "Uranium-Plutonium", priority = 1 },
  ["Plutonium 239 Dust"]      = { asteroid = "Uranium-Plutonium", priority = 3 },
  ["Thorium Dust"]            = { asteroid = "Uranium-Plutonium", priority = 4 },
  --  ["Naquadah Dust"] = { asteroid = "Naquadah", priority = 1 },
  --  ["Enriched Naquadah Dust"] = { asteroid = "Naquadah", priority = 2 },
  --  ["Naquadria Dust"] = { asteroid = "Naquadah", priority = 3 },
  -- === UNVERIFIED, DISABLED ===
  -- The commented entries above were in the shipped config but the game never
  -- produced them: asteroiddump walked every asteroid and every ore-processing
  -- recipe and saw none of these labels, on any asteroid.
  --
  -- They are not necessarily wrong. Alloys (Invar, Battery Alloy, Soldering
  -- Alloy, Graphene, Staballoy, Kleinite) and the rare-earth chemical line
  -- (Cerium, Praseodymium, Promethium, Dysprosium, Gadolinium, Terbium) sit
  -- past the ore-processing graph the mod walks, so their absence proves
  -- nothing either way. What it does mean is that nobody has confirmed the
  -- labels, and a wrong label fails silently as a permanent 0%.
  --
  -- If you actually produce one of these, add it in the editor (press E, open
  -- its asteroid, press A) and check the spelling with verify_items first. It
  -- will be written to user_config.lua, which this file never overwrites.
}

--------------------------------------------------------------------------------
-- 9. MODULE ITEM FILTER BLACKLIST
-- High-volume junk ores that clog the ME output bus with no useful yield.
-- Load these into each mining module's built-in filter as a blacklist.
-- End-dimension variants of common ores are particularly prolific and
-- should always be excluded.
--------------------------------------------------------------------------------
config.blacklist = {
  "Cheese Ore",
  "Oilsands Ore",
  "Fluorspar Ore",
  "End Copper Ore",
  "End Malachite Ore",
  "End Chalcopyrite Ore",
  "End Iron Ore",
  "End Pyrite Ore",
  "End Basaltic Mineral Sand Ore",
  "End Granitic Mineral Sand Ore",
  "End Coal Ore",
  "End Lignite Coal Ore"
}

--------------------------------------------------------------------------------
-- 10. DUST STOCK THRESHOLDS
-- Target quantities to maintain in the dust storage ME subnet.
-- Broker triggers a mining job when stock < amountToMaintain.
-- Asteroid is resolved via dustTargets[itemName].asteroid.
-- After each job run the broker waits config.pipelineCheckDelay seconds
-- for the ore processing pipeline to catch up before re-evaluating.
--------------------------------------------------------------------------------
config.conditions = {
  --  { itemName = "Ichorium Dust",           amountToMaintain = qty("5m")  },
  --  { itemName = "Draconic Core Dust",      amountToMaintain = qty("5m")  },
  --  { itemName = "Raw Tengam Dust",         amountToMaintain = qty("5m")  }, -- Requires MK-III modules
  --  { itemName = "Mysterious Crystal Dust", amountToMaintain = qty("5m")  },
  --  { itemName = "Cosmic Neutronium Dust",  amountToMaintain = qty("5m")  },
  --  { itemName = "Trinium Dust",            amountToMaintain = qty("5m")  },
  --  { itemName = "Adamantium Dust",         amountToMaintain = qty("5m")  },
  --  { itemName = "Aluminium Dust",          amountToMaintain = qty("5m")  },
  --  { itemName = "Bauxite Dust",            amountToMaintain = qty("5m")  },
  --  { itemName = "Crushed Monazite Ore",    amountToMaintain = qty("5m")  },
  --  { itemName = "Cobalt Dust",             amountToMaintain = qty("5m")  },
  --  { itemName = "Ardite Dust",             amountToMaintain = qty("5m")  },
  --  { itemName = "Lapis Dust",              amountToMaintain = qty("5m")  },
  --  { itemName = "Chrome Dust",             amountToMaintain = qty("5m")  },
  --  { itemName = "Clay Block",              amountToMaintain = qty("5m")  },
  --  { itemName = "Copper Dust",             amountToMaintain = qty("5m")  },
  { itemName = "Diamond",                 amountToMaintain = qty("10m") },
  --  { itemName = "Nether Star",             amountToMaintain = qty("10m") },
  --  { itemName = "Callisto Ice Dust",       amountToMaintain = qty("5m")  },
  --  { itemName = "Europium Dust",           amountToMaintain = qty("5m")  },
  --  { itemName = "Gadolinite-Y Dust",       amountToMaintain = qty("5m")  },
  --  { itemName = "Lutetium Dust",           amountToMaintain = qty("5m")  },
  --  { itemName = "Naquadah Dust",           amountToMaintain = qty("5m")  },
  --  { itemName = "Nickel Dust",             amountToMaintain = qty("5m")  },
  --  { itemName = "Phosphate Dust",          amountToMaintain = qty("5m")  },
  --  { itemName = "Nether Quartz Dust",      amountToMaintain = qty("5m")  },
  --  { itemName = "Salt",                    amountToMaintain = qty("5m")  },
  --  { itemName = "Raw Silicon Dust",        amountToMaintain = qty("5m")  },
  --  { itemName = "Infinity Catalyst Dust",  amountToMaintain = qty("10m") },
  --  { itemName = "Tungsten Dust",           amountToMaintain = qty("5m")  },
  --  { itemName = "Uranium 238 Dust",        amountToMaintain = qty("5m")  },
  --  { itemName = "Saltpeter Dust",          amountToMaintain = qty("5m")  },
  --  { itemName = "Osmium Dust",             amountToMaintain = qty("5m")  },
  --  { itemName = "Tiberium Dust",           amountToMaintain = qty("5m")  },
  --  { itemName = "Mica Dust",               amountToMaintain = qty("5m")  },
  --  { itemName = "Fluorspar Dust",          amountToMaintain = qty("5m")  },
  --  { itemName = "Antimony Dust",           amountToMaintain = qty("5m")  },
  --  { itemName = "Gallium Dust",            amountToMaintain = qty("5m")  },
  --  { itemName = "Lead Dust",               amountToMaintain = qty("5m")  },
  --  { itemName = "Bedrockium Dust",         amountToMaintain = qty("5m")  },
  --  { itemName = "Awakened Draconium Dust", amountToMaintain = qty("5m")  },
  --  { itemName = "Draconium Dust",          amountToMaintain = qty("5m")  },
  --  { itemName = "Neutronium Dust",         amountToMaintain = qty("5m")  },
  --  { itemName = "Black Plutonium Dust",    amountToMaintain = qty("5m")  },
  --  { itemName = "Rock Salt",               amountToMaintain = qty("5m")  },
  --  { itemName = "Palladium Dust",          amountToMaintain = qty("5m")  },
}

--------------------------------------------------------------------------------
-- 11. NETWORK & RUNTIME SETTINGS
--------------------------------------------------------------------------------
config.ports = {
  telemetry = 2026, -- inbound to broker: telem nodes + job nodes → broker
  command   = 2027, -- outbound from broker: broker → job nodes
  hardware  = 2025  -- outbound from broker: broker → hw telem node
}
-- Why the hardware node gets its own port instead of listening on `command`:
-- the DUST_WATCHLIST broadcast carries every tracked dust item, and the hw node
-- is the most memory-constrained machine in the fleet (it does not even load
-- this file). Sharing a port would make it unserialize that packet every 30s
-- only to discard it. 2025 was already opened by hw_telem for a query protocol
-- that never got a client, so this costs nothing new.
--
-- NOTE: hw_telem.lua hardcodes 2025 -- it does not load this file. Changing the
-- number here without changing it there silently stops drill auto-crafting.

-- Seconds to wait after a job run before re-checking dust levels.
-- Accounts for ore processing pipeline delay (ore → ore factory → dust storage).
config.pipelineCheckDelay = 30

-- How many modules may work the same asteroid at once.
--
--   nil     automatic (default): half the modules plus one while SEVERAL
--           asteroids are wanted, and no limit at all when only one is -- the
--           cap divides the fleet between competing needs, and with a single
--           target there is nothing to divide and nothing to protect.
--   <n>     pin it to n modules.
--   "all"   never limit; one asteroid may take the whole fleet.
--
-- Raise or pin this only if you want a specific split. Lowering it idles
-- modules, which only helps when you are deliberately reserving capacity.
config.asteroidCap = nil

-- How many drill tips and rods to stock per module load, in ITEMS.
--
-- These are totals across the input bus, not per slot. A slot holds one stack
-- (64), so anything above that is spread over additional bus slots -- slot 1 is
-- the drone, and tips and rods fill from slot 2 onwards. The bus needs enough
-- free slots for the total you ask for, and the loader stops filling when it
-- runs out of room rather than failing.
--
-- 128 is two stacks each, which halves how often a module stops to reload. Drop
-- back to 64 if a module ever refuses to run with consumables spread over more
-- than one slot.
--
-- The broker will not dispatch unless at least this many kits are in stock, so
-- raising it also raises the dispatch floor -- keep config.drillPar comfortably
-- above it.
config.tipsPerLoad = 128
config.rodsPerLoad = 128

-- How much has to be in the bus before the module STARTS. The rest of the
-- buffer above is filled while it is already mining.
--
-- Waiting for the full 128 of each meant 256 items through the ME before a drill
-- that was ready to work would turn on, and six modules do that at once. One
-- stack is one interface configuration slot, which is the fastest delivery the
-- ME can make.
--
-- Set these equal to tipsPerLoad/rodsPerLoad to go back to filling completely
-- before starting.
config.tipsToStart = 64
config.rodsToStart = 64

-- How long after a module starts the broker may keep finishing its buffer.
--
-- Only unpinned modules use this, and only until the buffer is complete. It is
-- a backstop: without it, a module the ME cannot supply would be topped up for
-- its entire run, and a module that is always topped up never runs dry, never
-- reaches DONE, and is never re-dispatched -- which quietly pins it to whatever
-- asteroid it first picked up. Pinned modules top up forever by design.
config.topUpWindow = 30

-- FAST RELOAD -- skip the unload when the next job wants the same hardware.
--
-- Most re-dispatches send a module back to the same asteroid with the same drone
-- and drill. Returning the drone and leftover consumables to the ME and then
-- asking for identical items back costs the whole round trip, and it is what
-- creates the wait at the start of the next load: the network has to absorb what
-- we just pushed into the interface before it can stock anything new.
--
-- With this on, a finished module HOLDS its contents, and dispatch decides. Same
-- drone and drill -> keep everything, top up what is short, restart. Different
-- -> unload exactly as before.
--
-- holdTimeout returns the contents if nothing claims the module, since a held
-- drone is invisible to every other module until it is given back. Dispatch
-- normally claims it within a fraction of a second.
--
-- Off by default: it is the most invasive change to the load path, and the
-- failure mode if the broker is wrong about what a module holds would be arming
-- a module with the wrong hardware. The loader verifies the drone before
-- committing, so that should fail loudly rather than silently -- but prove it on
-- your setup before leaving it on.
config.fastReload  = false
config.holdTimeout = 10

-- How many modules may be LOADING at the same time. 0 = no limit.
--
-- Loads do not really run in parallel: they share one computer's component-call
-- budget, which OpenComputers meters at roughly one indirect call per tick.
-- Measured in game, a module loading alone took 3 seconds and the same load
-- alongside five siblings took 22-30 -- the work was not slower, it was queued.
--
-- Since the total budget is the same either way, staggering means early modules
-- start mining sooner and the last one is no worse off.
--
-- Set to 0 (no limit) because the reason for the cap has since gone away. Loads
-- were ~90 metered calls each when it was introduced; after the loader and the
-- restock path stopped reading inventories one slot at a time they are ~39, and
-- six at once now finish in 2-7s rather than 22-37s. Staggering cheap loads only
-- delays the modules waiting for a slot.
--
-- Put it back to 2 or 3 if load times climb again -- that would mean something
-- has started competing for the call budget once more.
config.maxConcurrentLoads = 0

-- How often to ask a running module whether it has finished.
--
-- Each check is a component call, so a constant fast rate is expensive: nine
-- modules at four checks a second spend 36 calls a second on a question that is
-- answered "no" for nearly the whole run, competing with the loads for the same
-- budget.
--
-- The broker learns how long each module runs for (it stops when consumables
-- run out, so this is very consistent) and checks lazily until the end is near.
--
-- Run length is not constant -- a recipe cycle varies from a few seconds to
-- fifteen, and a run is several cycles -- so the broker does not try to predict
-- when a run will end. It remembers the SHORTEST run each module has done for
-- its current asteroid, drill and parallel count, and checks lazily only within
-- a fraction of that: a window the module has demonstrably never finished in.
--
--   runPollIdle      seconds between checks inside that safe window.
--                    0 = check at the fast rate throughout, the old behaviour.
--   runSafeFraction  how much of the shortest observed run counts as safe.
--                    Lower is more cautious and costs more calls.
config.runPollIdle     = 3.0
config.runSafeFraction = 0.8

-- Par levels for drill consumables. The broker publishes this table to the hw
-- telem node (DRILL_PAR on config.ports.hardware); the node compares it against
-- its own live ME scan and auto-crafts anything below par.
--
-- Only materials listed here are ever ordered -- an explicit list, so adding a
-- drill material to the game does not silently start an expensive craft.
--
-- All nine are listed because all nine are dispatchable: the gate in
-- tryDispatch() is config.drills, which has every material. (config.drillRegistry
-- looks like it gates this but is dead -- nothing reads it since the loader moved
-- to label-based lookup. Do not use it to decide what belongs here.) A tier left
-- out of this table still dispatches and still burns kits; it just never gets
-- restocked, which is the silent stall this whole feature exists to remove.
--
-- Be aware what the top three cost. 256 Infinity or Transcendent Metal drill
-- tips is a large unattended resource commitment. Lower those pars, or drop them
-- to false in user_config.lua, if you would rather approve those crafts by hand.
--
-- Levels are scaled to what each material costs to make rather than held flat.
-- A flat number is wrong at both ends: a shallow buffer of Steel is nothing on
-- a mature base, while the same figure in Transcendent Metal is an enormous
-- unattended craft.
--
-- Two numbers per material, and they do different jobs:
--
--   tips / rods  the stock FLOOR. Fall below it and a craft is requested.
--   batch        the REQUEST SIZE. Always sent whole, never the shortfall.
--
-- Requesting the exact shortfall meant a material sitting just under its floor
-- produced a trickle -- ask for 4096, be 196 short, order 196. Ordering a full
-- batch instead means every request is worth the crafting CPU it occupies.
--
-- The trade is overshoot: floor 4096 with batch 4096 means stock at 4095 orders
-- another 4096 and lands near 8191 before settling. Lower the batch if you would
-- rather hold less, or lower the floor if you would rather craft less often.
--
-- Values are in ITEMS. One module refill is config.tipsPerLoad of each, which
-- ships at 128, so 4096 is 32 refills. How long a refill lasts depends on the
-- module: the recipe burns 4 tips and 4 rods per parallel per cycle, and
-- maxParallels is 2/4/8 for MK-I/II/III -- so on an MK-II a refill covers 8
-- cycles, making 4096 roughly 256 cycles of buffer.
--
-- (This paragraph said 64 and "4 cycles" while tipsPerLoad was already 128, so
-- every number derived from it was out by half.)
--
-- Keep every floor at or above 64 or a module can stall on the kits < 64
-- dispatch floor while nominally sitting at par.
--
-- If the network has no crafting pattern for a listed item, the node reports it
-- as "nopattern" and it shows up red on both dashboards -- a missing pattern is
-- meant to be loud, since the failure it replaces (a module that silently never
-- loads) is the hardest thing in this system to diagnose.
config.drillPar = {
  -- tips/rods = the stock floor: drop below it and a craft is requested.
  -- batch     = how many are requested when that happens, for tips and rods
  --             alike. It is NOT the shortfall -- a full batch goes out even if
  --             you are only a few short, so requests are always worth making.
  steel             = { tips = 4096, rods = 4096, batch = 4096 },
  titanium          = { tips = 4096, rods = 4096, batch = 4096 },
  tungstensteel     = { tips = 4096, rods = 4096, batch = 4096 },
  naquadah          = { tips = 2048, rods = 2048, batch = 2048 },
  naquadahAlloy     = { tips = 2048, rods = 2048, batch = 2048 },
  neutronium        = { tips = 1024, rods = 1024, batch = 1024 },
  -- Tiers 11-14 (MK-XI UIV and up). Held low deliberately: these are the ones
  -- where an unattended craft is genuinely expensive, and par is only published
  -- once you own a drone that uses them anyway.
  cosmicNeutronium  = { tips =  256, rods =  256, batch =  256 },
  infinity          = { tips =  256, rods =  256, batch =  256 },
  transcendentMetal = { tips =  256, rods =  256, batch =  256 },
}

-- How many drill crafts the hw node may have in flight at once.
--
-- Match this to your AE2 crafting CPUs in the staging network. AE2 cancels a
-- request outright when no CPU is free, so firing every shortfall at once on a
-- one-CPU network means one craft starts and the rest come back rejected --
-- which read as hard failures on both dashboards and re-fired every retry.
-- Shortfalls beyond this limit wait quietly as "queued" instead.
--
-- Setting this HIGHER than your CPU count is the failure mode to avoid: the
-- surplus requests are rejected on arrival and show as REJECTED. Setting it
-- lower only makes restocking slower, so when in doubt round down.
config.drillCraftSlots = 2

-- ---------------------------------------------------------------------------
-- LOGGING (see logger.lua)
-- Disabled by default: ERROR/WARN lines still go to the log file so you can
-- diagnose problems, but nothing spams the screen and nothing hits the network.
-- Set enabled = true to also capture INFO/DEBUG, or to use the loki/console
-- backends.
-- ---------------------------------------------------------------------------
config.logging = {
  enabled      = false,  -- master switch
  backend      = "file", -- "file" | "console" | "loki"
  file         = "/tmp/spacemining.log",
  maxFileBytes = 65536,  -- log file is capped at this size
  -- Only used when backend == "loki":
  lokiHost     = "127.0.0.1",
  lokiPort     = 3100,
  -- Optional: set a real Unix epoch (seconds) to anchor timestamps if you have
  -- a way to fetch it; otherwise timestamps are uptime-relative.
  bootUnixTime = 0,
}

--------------------------------------------------------------------------------
-- USER OVERLAY
--
-- Everything above this line is SHIPPED data: hand-maintained tables plus the
-- generated asteroidOutputs block. It gets regenerated and updated wholesale,
-- so nothing you change in game may live here -- it would be overwritten the
-- next time this file is refreshed.
--
-- Your choices live in /home/user_config.lua instead, which only the in-game
-- editor (press E on the broker) ever writes. One writer per file, so the two
-- can never clobber each other.
--
-- The overlay is optional. With no user_config.lua present the shipped
-- defaults are used exactly as before.
--
--   conditions   REPLACED by yours if present -- what you track is entirely
--                your call, not something a shipped default should fight.
--   dustTargets  MERGED over the shipped table, so new mappings you add are
--                added and existing ones can be corrected, while everything you
--                have not touched keeps following updates to this file.
--   drillPar     MERGED per material, same reasoning: a par you tuned for one
--                drill wins, while the materials you never touched keep
--                following the shipped defaults. Set a material to false to
--                stop ordering it entirely.
--------------------------------------------------------------------------------

-- Snapshot before merging so the editor can tell which entries are genuinely
-- yours and only persist those. Without this it could not distinguish a shipped
-- mapping from one you added, and would have to write all 100-odd back out --
-- freezing them and masking every future correction.
config.shippedDustTargets = {}
for item, t in pairs(config.dustTargets) do
  config.shippedDustTargets[item] = { asteroid = t.asteroid, priority = t.priority }
end

do
  local ok, user = pcall(dofile, "/home/user_config.lua")
  if ok and type(user) == "table" then
    if type(user.dustTargets) == "table" then
      for item, t in pairs(user.dustTargets) do
        config.dustTargets[item] = { asteroid = t.asteroid, priority = t.priority }
      end
    end
    if type(user.conditions) == "table" and #user.conditions > 0 then
      config.conditions = user.conditions
    end
    if type(user.drillPar) == "table" then
      for key, p in pairs(user.drillPar) do
        -- `false` is how you switch a shipped material off. Writing nil into a
        -- table you are iterating elsewhere is fine here, but false would leak
        -- through to the broadcast as a non-table, so drop the key outright.
        if p == false then
          config.drillPar[key] = nil
        elseif type(p) == "table" then
          config.drillPar[key] = { tips = p.tips, rods = p.rods, batch = p.batch }
        end
      end
    end
  end
end

return config
