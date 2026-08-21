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
  -- TODO: scan these with find_item.lua and add them to enable higher drone tiers.
  -- Until added, dispatch skips any tier that maps to an unregistered drill.
  --   cosmicNeutronium, infinity, transcendentMetal
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
  ["Draconic Core Dust"]      = { asteroid = "Draconic Core", priority = 1 },
  ["Tengam Dust"]             = { asteroid = "Tengam", priority = 1 },
  ["PlatLine Dust"]           = { asteroid = "PlatLine Dust", priority = 1 },

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
  ["Staballoy Dust"]          = { asteroid = "Everglades", priority = 1 },
  ["Kleinite Dust"]           = { asteroid = "Draconic", priority = 3 },

  -- === RARE EARTH & LANTHANIDE PROCESSING LINE ===
  ["Trinium Dust"]            = { asteroid = "Lanthanum", priority = 1 },
  ["Lanthanum Dust"]          = { asteroid = "Lanthanum", priority = 2 },
  ["Cerium Dust"]             = { asteroid = "Aluminium-LanthLine", priority = 3 },
  ["Praseodymium Dust"]       = { asteroid = "Lanthanum", priority = 3 },
  ["Neodymium Dust"]          = { asteroid = "Aluminium-LanthLine", priority = 4 },
  ["Promethium Dust"]         = { asteroid = "Lanthanum", priority = 4 },
  ["Samarium Dust"]           = { asteroid = "Holmium/Samarium", priority = 1 },
  ["Europium Dust"]           = { asteroid = "Europium", priority = 3 },
  ["Gadolinium Dust"]         = { asteroid = "Everglades", priority = 5 },
  ["Terbium Dust"]            = { asteroid = "Everglades", priority = 6 },
  ["Dysprosium Dust"]         = { asteroid = "Holmium/Samarium", priority = 3 },
  ["Holmium Dust"]            = { asteroid = "Holmium/Samarium", priority = 2 },
  ["Erbium Dust"]             = { asteroid = "Holmium/Samarium", priority = 4 },
  ["Thulium Dust"]            = { asteroid = "Holmium/Samarium", priority = 5 },
  ["Ytterbium Dust"]          = { asteroid = "Holmium/Samarium", priority = 6 },
  ["Lutetium Dust"]           = { asteroid = "Lutetium", priority = 1 },

  -- === RARE EARTH INTERMEDIATE PRODUCTS ===
  ["Rare Earth I Dust"]       = { asteroid = "Aluminium-LanthLine", priority = 2 },
  ["Rare Earth II Dust"]      = { asteroid = "Holmium/Samarium", priority = 2 },
  ["Rare Earth III Dust"]     = { asteroid = "Everglades", priority = 3 },
  ["Rare Earth I Ore"]        = { asteroid = "Aluminium-LanthLine", priority = 2 },
  ["Rare Earth II Ore"]       = { asteroid = "Holmium/Samarium", priority = 2 },
  ["Rare Earth III Ore"]      = { asteroid = "Everglades", priority = 3 },

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
  ["Invar Dust"]              = { asteroid = "Nickel", priority = 2 },
  ["Platinum Ore"]            = { asteroid = "PlatLine Ore", priority = 1 },
  ["Palladium Dust"]          = { asteroid = "PlatLine Ore", priority = 2 },
  ["Osmium Dust"]             = { asteroid = "PlatLine Ore", priority = 3 },
  ["Tiberium Dust"]           = { asteroid = "Holmium/Samarium", priority = 4 },
  ["Iridium Dust"]            = { asteroid = "PlatLine Ore", priority = 4 },
  ["Galena Dust"]             = { asteroid = "Lead", priority = 4 },
  ["Sphalerite Dust"]         = { asteroid = "Copper", priority = 3 },
  ["Pyrite Dust"]             = { asteroid = "Iron", priority = 2 },
  ["Bauxite Ore"]             = { asteroid = "Aluminium", priority = 2 },
  ["Monazite Ore"]            = { asteroid = "Aluminium-LanthLine", priority = 1 },
  ["Bastnasite Ore"]          = { asteroid = "Aluminium-LanthLine", priority = 2 },
  ["Soldering Alloy Dust"]    = { asteroid = "Lead", priority = 2 },
  ["Battery Alloy Dust"]      = { asteroid = "Lead", priority = 3 },

  -- === INDUSTRIAL MATERIALS, THAUMCRAFT & GEM ORES ===
  ["Clay Block"]              = { asteroid = "Clay", priority = 1 },
  ["Magnesium Dust"]          = { asteroid = "Magnesium", priority = 1 },
  ["Niobium Dust"]            = { asteroid = "Niobium", priority = 1 },
  ["Phosphate Dust"]          = { asteroid = "Phosphate", priority = 1 },
  ["Quartz Dust"]             = { asteroid = "Quartz", priority = 1 },
  ["Salt"]                    = { asteroid = "Salt", priority = 1 },
  ["Saltpeter Dust"]          = { asteroid = "Salt", priority = 2 },
  ["Silicon Dust"]            = { asteroid = "Silicon", priority = 1 },
  ["Thaumium Dust"]           = { asteroid = "Thaumium Dusts", priority = 1 },
  ["Tungsten Dust"]           = { asteroid = "Tungsten-Titanium", priority = 1 },
  ["Manganese Dust"]          = { asteroid = "Tungsten-Titanium", priority = 2 },
  ["Titanium Dust"]           = { asteroid = "Tungsten-Titanium", priority = 3 },
  ["Coal Dust"]               = { asteroid = "Coal", priority = 10 },
  ["Graphite Dust"]           = { asteroid = "Coal", priority = 10 },
  ["Graphene Dust"]           = { asteroid = "Coal", priority = 10 },
  ["Diamond"]                 = { asteroid = "Gem Ores", priority = 1 },
  ["Nether Star"]             = { asteroid = "Gem Ores", priority = 2 },
  ["Diamond Dust"]            = { asteroid = "Gem Ores", priority = 3 },
  ["Emerald Dust"]            = { asteroid = "Gem Ores", priority = 4 },
  ["Certus Quartz Dust"]      = { asteroid = "Gem Ores", priority = 5 },
  ["Nether Quartz Dust"]      = { asteroid = "Gem Ores", priority = 6 },
  ["Sapphire Dust"]           = { asteroid = "Gem Ores", priority = 7 },
  ["Green Sapphire Dust"]     = { asteroid = "Gem Ores", priority = 8 },
  ["Olivine Dust"]            = { asteroid = "Gem Ores", priority = 9 },
  ["Ledox Dust"]              = { asteroid = "Europium", priority = 1 },
  ["Callisto Ice Dust"]       = { asteroid = "Europium", priority = 2 },
  ["Borax Dust"]              = { asteroid = "Europium", priority = 4 },

  -- === NUCLEAR MATERIALS & NAQUADAH LINE ===
  ["Uranium-235 Dust"]        = { asteroid = "Uranium-Plutonium", priority = 2 },
  ["Uranium-238 Dust"]        = { asteroid = "Uranium-Plutonium", priority = 1 },
  ["Plutonium-239 Dust"]      = { asteroid = "Uranium-Plutonium", priority = 3 },
  ["Thorium Dust"]            = { asteroid = "Uranium-Plutonium", priority = 4 },
  ["Naquadah Dust"]           = { asteroid = "Naquadah", priority = 1 },
  ["Enriched Naquadah Dust"]  = { asteroid = "Naquadah", priority = 2 },
  ["Naquadria Dust"]          = { asteroid = "Naquadah", priority = 3 }
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
  --  { itemName = "Tengam Dust",             amountToMaintain = qty("5m")  }, -- Requires MK-III modules
  { itemName = "Mysterious Crystal Dust", amountToMaintain = qty("5m")  },
  { itemName = "Cosmic Neutronium Dust",  amountToMaintain = qty("5m")  },
  { itemName = "Trinium Dust",            amountToMaintain = qty("5m")  },
  { itemName = "Adamantium Dust",         amountToMaintain = qty("5m")  },
  { itemName = "Aluminium Dust",          amountToMaintain = qty("5m")  },
  { itemName = "Bauxite Dust",            amountToMaintain = qty("5m")  },
  --  { itemName = "Crushed Monazite Ore",    amountToMaintain = qty("5m")  },
  { itemName = "Cobalt Dust",             amountToMaintain = qty("5m")  },
  { itemName = "Ardite Dust",             amountToMaintain = qty("5m")  },
  { itemName = "Lapis Dust",              amountToMaintain = qty("5m")  },
  { itemName = "Chrome Dust",             amountToMaintain = qty("5m")  },
  --  { itemName = "Clay Block",              amountToMaintain = qty("5m")  },
  { itemName = "Copper Dust",             amountToMaintain = qty("5m")  },
  { itemName = "Diamond",                 amountToMaintain = qty("10m") },
  { itemName = "Nether Star",             amountToMaintain = qty("10m") },
  --  { itemName = "Callisto Ice Dust",       amountToMaintain = qty("5m")  },
  { itemName = "Europium Dust",           amountToMaintain = qty("5m")  },
  --  { itemName = "Gadolinite-Y Dust",       amountToMaintain = qty("5m")  },
  --  { itemName = "Lutetium Dust",           amountToMaintain = qty("5m")  },
  --  { itemName = "Naquadah Dust",           amountToMaintain = qty("5m")  },
  { itemName = "Nickel Dust",             amountToMaintain = qty("5m")  },
  { itemName = "Phosphate Dust",          amountToMaintain = qty("5m")  },
  { itemName = "Nether Quartz Dust",      amountToMaintain = qty("5m")  },
  { itemName = "Salt",                    amountToMaintain = qty("5m")  },
  { itemName = "Raw Silicon Dust",        amountToMaintain = qty("5m")  },
  { itemName = "Infinity Catalyst Dust",  amountToMaintain = qty("10m") },
  { itemName = "Tungsten Dust",           amountToMaintain = qty("5m")  },
  { itemName = "Uranium 238 Dust",        amountToMaintain = qty("5m")  },
  { itemName = "Saltpeter Dust",          amountToMaintain = qty("5m")  },
  { itemName = "Osmium Dust",             amountToMaintain = qty("5m")  },
  { itemName = "Tiberium Dust",           amountToMaintain = qty("5m")  },
  { itemName = "Mica Dust",               amountToMaintain = qty("5m")  },
  --  { itemName = "Fluorspar Dust",          amountToMaintain = qty("5m")  },
  { itemName = "Antimony Dust",           amountToMaintain = qty("5m")  },
  { itemName = "Gallium Dust",            amountToMaintain = qty("5m")  },
  { itemName = "Lead Dust",               amountToMaintain = qty("5m")  },
  { itemName = "Bedrockium Dust",         amountToMaintain = qty("5m")  },
  { itemName = "Awakened Draconium Dust", amountToMaintain = qty("5m")  },
  { itemName = "Draconium Dust",          amountToMaintain = qty("5m")  },
  { itemName = "Neutronium Dust",         amountToMaintain = qty("5m")  },
  { itemName = "Black Plutonium Dust",    amountToMaintain = qty("5m")  },
  { itemName = "Rock Salt",               amountToMaintain = qty("5m")  },
  { itemName = "Palladium Dust",          amountToMaintain = qty("5m")  },
}

--------------------------------------------------------------------------------
-- 11. NETWORK & RUNTIME SETTINGS
--------------------------------------------------------------------------------
config.ports = {
  telemetry = 2026, -- inbound to broker: telem nodes + job nodes → broker
  command   = 2027  -- outbound from broker: broker → job nodes
}

-- Seconds to wait after a job run before re-checking dust levels.
-- Accounts for ore processing pipeline delay (ore → ore factory → dust storage).
config.pipelineCheckDelay = 30

-- How many drill tips and rods to stock per module load. The loader requests
-- this many from the ME interface; the broker won't dispatch unless at least
-- this many kits are available in stock.
config.tipsPerLoad = 64
config.rodsPerLoad = 64

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

return config
