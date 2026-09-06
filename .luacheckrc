-- luacheck configuration for the MEDINA / space-pumping OpenComputers scripts.
--
-- These run inside OpenComputers' Lua 5.2/5.3 sandbox, not on a desktop Lua, so
-- two things are different from a normal project and both are configured here.
--
-- WHAT THIS IS FOR. Every module in this repo is loaded with dofile(), which no
-- static tool can follow, so cross-file checking is not available and never will
-- be. What luacheck buys us is per-file scope analysis -- and that is worth
-- having, because the one class of bug it catches is one this codebase has
-- actually shipped: a closure written ABOVE the local it means to capture reads
-- a nil global instead, silently. See the sched.onError note in broker-mk3.lua.

std = "lua53"   -- OC runs 5.2/5.3; Homebrew ships 5.4+. Nothing here uses
                -- `//` or `goto`, so 5.3 is the honest floor to check against.

-- The comment blocks in this repo carry the reasoning and are long on purpose.
max_line_length = false

-- Unused arguments are load-bearing here: OpenComputers' event.pull hands back
-- fixed-shape tuples, so a handler that wants the sixth value must name the
-- five before it. Same for `for _, x in`.
unused_args = false

-- The sandbox provides these; nothing else should be reached as a global.
-- Deliberately short: an empty-by-default list is what makes an accidental
-- global read stand out instead of blending in.
read_globals = {
  "component", "computer", "unicode",
  -- OpenOS extends the stock os table. Only the one we actually call.
  os = { fields = { "sleep" } },
}

-- 512: "loop is executed at most once". This is the house idiom for taking the
-- first component of a kind -- `for addr in component.list(x) do p = addr break end`
-- -- which component.list's iterator interface makes the natural spelling. It
-- appears in nearly every file here and is never a mistake.
ignore = { "512" }

files["space-miner/config.lua"] = {
  -- 3k lines of asteroid data behind one local. Nothing to analyse.
  ignore = { "631" },
}

files["space-miner/job_node.lua"] = {
  -- Legacy remote-worker path, kept for future multi-node fleets and currently
  -- run by nobody. It is not held to the same bar as the live files; see the
  -- header of that file for what is known to be wrong with it.
  ignore = { ".*" },
}

files["space-miner/hw_telem.lua"] = {
  -- 311: "value assigned is unused". Every instance is `bigTable = nil; gc()`,
  -- dropping a reference before collecting. That is deliberate and it is the
  -- point of the line -- this node's failure mode is running out of heap while
  -- holding an ME scan, so the write has an effect luacheck cannot see.
  ignore = { "311" },
}
