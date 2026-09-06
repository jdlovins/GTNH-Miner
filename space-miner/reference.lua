-- =============================================================================
-- reference.lua — data nothing loads
--
-- These tables were carved out of config.lua because nothing reads them. They
-- are kept, not deleted, because each one is expensive to re-derive by hand and
-- a plausible future needs it back. They cost nothing here: no node loads this
-- file, so none of it occupies memory on a machine that never wanted it.
--
-- If you need one, `dofile("/home/reference.lua")` and take the field.
--
--   droneRegistry / drillRegistry  Minecraft internal names + damage values.
--       Written for a fingerprint-based loader (db.set(slot, name, damage)).
--       The loader now resolves items by LABEL through iface.store(), so these
--       went unread -- and drillRegistry was actively misleading, since it is
--       missing the top three tiers while all nine dispatch and load fine.
--       Scan new items with verify_items.lua to extend it.
--
--   cycleDefaults  For a job_node running mode=1 (dynamic distance sweep):
--       the module sweeps between (distance - range) and (distance + range) in
--       `step` increments, harvesting a wider spread of asteroid types. Every
--       dispatch path in the system uses static mode (mode=0) at one distance.
--
--   blacklist  High-volume junk ores that clog the ME output bus with no useful
--       yield. Load these into each mining module's built-in item filter as a
--       blacklist -- that is a hardware setting, done in the GUI, which is why
--       no code has ever read this list. End-dimension variants of common ores
--       are particularly prolific and should always be excluded.
-- =============================================================================

local reference = {}

--------------------------------------------------------------------------------
-- 2b. ITEM REGISTRY (internal names for db.set)
-- GTNH 2.9 broke iface.store(); we now write fingerprints via db.set(slot,
-- registryName, damage). These tables map config keys to the Minecraft internal
-- item name + damage value. Scan new items with scan_items.lua to get values.
--------------------------------------------------------------------------------
reference.droneRegistry = {
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

reference.drillRegistry = {
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


--------------------------------------------------------------------------------
-- 5. CYCLE MODE DEFAULTS
-- Used when a job_node sets mode=1 (dynamic distance sweep) on a module.
-- In cycle mode the module sweeps distances between (distance - range) and
-- (distance + range), incrementing by step each pass, harvesting a wider
-- spread of asteroid types. Static mode (mode=0) locks to one distance.
--------------------------------------------------------------------------------
reference.cycleDefaults = {
  defaultMode  = 0,
  defaultRange = 50,
  defaultStep  = 20
}


--------------------------------------------------------------------------------
-- 9. MODULE ITEM FILTER BLACKLIST
-- High-volume junk ores that clog the ME output bus with no useful yield.
-- Load these into each mining module's built-in filter as a blacklist.
-- End-dimension variants of common ores are particularly prolific and
-- should always be excluded.
--------------------------------------------------------------------------------
reference.blacklist = {
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


return reference
