-- =============================================================================
-- job_node_config.example.lua
--
-- Copy this to /home/job_node_config.lua and fill in YOUR hardware addresses.
-- Use list_components.lua (or detect_module.lua) to find them.
--
-- All addresses may be the short 8-char form or the full UUID; either works.
--
--   nodeId   : a name for this node (any string)
--   dbAddr   : the SHARED OC Database. Each module uses 3 slots:
--              M1 -> 1/2/3, M2 -> 4/5/6, ... A 25-slot DB covers 6 modules;
--              an 81-slot MK3 DB covers up to 27.
--
-- Per module:
--   tier           : "MK-I" | "MK-II" | "MK-III"
--   moduleAddr     : OC Adapter on the Mining Module controller (gt_machine)
--   ifaceAddr      : OC Adapter on the module's ME Interface
--   transposerAddr : Transposer between the ME Interface buffer and the Input Bus
--   interfaceSide  : transposer side facing the ME Interface buffer (0-5)
--   inputBusSide   : transposer side facing the Input Bus (0-5)
--   distanceParam  : setParameters index for distance (usually 0)
--   pinnedAsteroid : (optional) reserve this module to ALWAYS mine one asteroid,
--                    ignoring dust thresholds and the per-asteroid cap. Use the
--                    exact asteroid name from config.asteroids, e.g.
--                    "Infinity Catalyst" to keep a module on Infinity dust.
--                    The module still needs an eligible drone + drill kits in
--                    stock; it stays idle only when those run out.
--
-- Transposer side numbers (OpenComputers sides API):
--   0 = bottom (down)   1 = top (up)
--   2 = north           3 = south
--   4 = west            5 = east
-- The sides depend on your physical build — verify them per module.
-- (detect_module.lua prompts for these and shows this legend.)
-- =============================================================================

return {
  nodeId = "MEDINA-Ring-1",
  dbAddr = "",        -- leave blank: detect_module auto-detects your database
  modules = {
    -- Leave this EMPTY and let detect_module.lua populate it — run it once per
    -- module (connect the module's 3 components, run detect_module, verify, repeat).
    --
    -- For reference, each module entry looks like this (detect_module writes them
    -- for you, so you normally don't edit this by hand):
    --   [1] = {
    --     tier           = "MK-II",
    --     moduleAddr     = "<gt_machine adapter address>",
    --     ifaceAddr      = "<me_interface adapter address>",
    --     transposerAddr = "<transposer address>",
    --     interfaceSide  = 3,   -- 0=down 1=up 2=north 3=south 4=west 5=east
    --     inputBusSide   = 2,
    --     distanceParam  = 0,
    --     -- pinnedAsteroid = "Infinity Catalyst", -- optional: reserve to one asteroid
    --   },
  },
}
