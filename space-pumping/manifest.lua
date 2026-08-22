-- =============================================================================
-- manifest.lua — what install-pump should download
--
-- THE POINT OF THIS FILE: install-pump fetches it FIRST, then downloads whatever
-- it lists. So adding a file to the project only means adding a line here.
--
-- The alternative — a hardcoded list inside install-pump.lua — has a trap in it
-- that bit this project once already. The installer on your disk is a copy from
-- whenever you last ran the wget, so it knows only the files that existed then.
-- Adding editor.lua later meant `install-pump` could never fetch it, and
-- autoPump died on a missing file with no obvious cause. A manifest fixes that
-- for good: the list lives on the server, not in the copy you happen to have.
--
--   program : always refreshed, overwriting whatever is there.
--   keep    : fetched only when absent, because they hold your settings.
-- =============================================================================

return {
  program = {
    "scheduler.lua",
    "logger.lua",
    "pumps.lua",
    "ui.lua",
    "editor.lua",
    "autoPump.lua",
    "diag.lua",
    -- install-pump refreshes itself too, so a future change to the installer
    -- reaches you without a manual wget.
    "install-pump.lua",
  },

  keep = {
    "config.lua",
  },
}
