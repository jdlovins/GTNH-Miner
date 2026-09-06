# MEDINA settings reference

Every tunable is declared in [`settings.lua`](settings.lua) — one entry per
knob, carrying its type, its legal range, and one line of what it does. That
file is the source of truth: `config.lua` seeds defaults from it, the in-game
editor builds its settings page from it, and the telemetry nodes are sent the
subset marked `scope = "node"`.

This document holds the **reasoning** — the measurements, the failure modes,
the "why is this off by default". It deliberately does not live in `config.lua`
any more, because that file is loaded into the memory of machines that only
needed a number.

**You should not need to edit any of this by hand.** Press `E` on the broker,
then `g` for the settings page. Booleans toggle with `space`, choices cycle
with `space`, numbers are typed with `t` or `enter`. `s` saves, and everything
takes effect live.

Changes are written to `/home/user_config.lua`, which updates never overwrite.
`config.lua` is shipped data and gets regenerated wholesale.

---

## Dispatch

### `asteroidCap` — how many modules may work the same asteroid at once

| value  | meaning |
|--------|---------|
| `auto` | half the modules plus one **while several asteroids are wanted**, and no limit at all when only one is |
| `all`  | never limit; one asteroid may take the whole fleet |
| a number | pin it to that many modules |

The cap exists to divide the fleet between competing needs. With a single
target there is nothing to divide and nothing to protect, which is why `auto`
lifts it entirely in that case.

Raise or pin this only if you want a specific split. Lowering it idles modules,
which only helps when you are deliberately reserving capacity.

### `dispatchInterval`

Seconds between sweeps looking for an idle module. The sweep itself is cheap —
it reads state the broker already holds — so this is low. It is not the cost of
a dispatch, which is the load task the sweep spawns.

### `pipelineCheckDelay`

Seconds to wait after a job run before re-checking dust levels. Ore has to
travel from the module output through ore processing and into dust storage
before the number the broker reads means anything. Set too low, the broker
re-dispatches for dust that is already on its way.

### `maxConcurrentLoads`

How many modules may be LOADING at the same time. `0` = no limit.

Loads do not really run in parallel: they share one computer's component-call
budget, which OpenComputers meters at roughly one indirect call per tick.
Measured in game, a module loading alone took 3 seconds, and the same load
alongside five siblings took 22–30 — the work was not slower, it was queued.

Since the total budget is the same either way, staggering means early modules
start mining sooner and the last one is no worse off. That was the argument for
the cap when it was introduced, and loads were ~90 metered calls each then.
After the loader and the restock path stopped reading inventories one slot at a
time they are ~39, and six at once now finish in 2–7s rather than 22–37s.
Staggering cheap loads only delays the modules waiting for a slot, so the
default is now no limit.

**Put it back to 2 or 3 if load times climb again** — that would mean something
has started competing for the call budget once more.

### `reserveWhileMining`

Charge a drone and a full load of kits to **every** working module.

Dispatch normally works from a pool of what is free right now: telemetry
reports what the staging ME holds, and commitments the last sweep could not have
seen yet are subtracted by hand. A module that has been mining long enough for a
sweep to run is *not* subtracted, because the ME no longer lists its drone —
charging it again would count the same drone twice.

That trusts telemetry to be current. Turn this on and the trust goes away: a
working module costs its drone and its `tipsPerLoad`/`rodsPerLoad` of kits for
as long as it is working, whatever the ME says. Nothing in stock can be promised
to two modules on the strength of a stale sweep.

The price is a standing spare per busy module — five modules mining means five
drones held out of the pool — and, if commitments ever outnumber reported stock,
a pool that goes negative and stops dispatching that tier entirely. That is the
failure this was made optional to fix, so it is **off by default**.

Turn it on if you do not trust the hw node's figures, or if you have watched two
modules argue over one physical drone. A module blocked this way does not idle:
dispatch moves on to the next need, so it takes a different asteroid it *can*
reach rather than waiting.

### `fastReload` and `holdTimeout`

**Fast reload skips the unload when the next job wants the same hardware.**

A finished module has consumed its tips and rods — running out is what makes it
stop — so the only thing left in the bus is the drone. And most re-dispatches
send the module back to the same asteroid, wanting that same drone. Returning it
to the network, waiting for the network to absorb it, and then asking for it
back is a round trip per cycle that ends where it started.

With this on, a finished module **holds** the drone and dispatch decides. Same
drone → keep it, fetch consumables fresh, restart. Different → return it exactly
as before.

`holdTimeout` returns the contents if nothing claims the module, since a held
drone is invisible to every other module until it is given back. Dispatch
normally claims it within a fraction of a second.

**Off by default:** it is the most invasive change to the load path, and the
failure mode if the broker is wrong about what a module holds would be arming a
module with the wrong hardware. The loader verifies the drone before committing,
so that should fail loudly rather than silently — but prove it on your setup
before leaving it on.

---

## Load buffer

### `tipsPerLoad` / `rodsPerLoad`

How many drill tips and rods to stock per module load, **in items**.

These are totals across the input bus, not per slot. A slot holds one stack
(64), so anything above that is spread over additional bus slots — slot 1 is the
drone, and tips and rods fill from slot 2 onwards. The bus needs enough free
slots for the total you ask for, and the loader stops filling when it runs out of
room rather than failing.

128 is two stacks each, which halves how often a module stops to reload. Drop
back to 64 if a module ever refuses to run with consumables spread over more
than one slot.

**These set the dispatch floor.** The broker will not dispatch unless at least
this many kits are in stock, so raising them also raises the floor — keep the
restock par comfortably above it. The settings page spells the current floor out
between the two sections for exactly this reason.

### `tipsToStart` / `rodsToStart`

How much has to be in the bus before the module **starts**. The rest of the
buffer is filled while it is already mining.

Waiting for the full 128 of each meant 256 items through the ME before a drill
that was ready to work would turn on, and six modules do that at once. One stack
is one interface configuration slot, which is the fastest delivery the ME can
make.

Set these equal to `tipsPerLoad`/`rodsPerLoad` to go back to filling completely
before starting.

### `topUpWindow`

How long after a module starts the broker may keep finishing its buffer.

Only unpinned modules use this, and only until the buffer is complete. It is a
backstop: without it, a module the ME cannot supply would be topped up for its
entire run, and a module that is always topped up never runs dry, never reaches
DONE, and is never re-dispatched — which quietly pins it to whatever asteroid it
first picked up. Pinned modules top up forever by design.

### `preDrainWait`

How long a load waits for the ME to take back what was just returned before
loading anyway.

It is a courtesy — giving the network room to deliver into — not a correctness
requirement, because the loader matches items by label rather than by slot. It
used to wait 15s and then **fail** the load, which on a recipe change with a busy
network cost a module an ERROR and a cooldown.

---

## Restock

### `drillCraftSlots`

How many drill crafts the hw node may have in flight at once.

Match this to your AE2 crafting CPUs in the staging network. AE2 cancels a
request outright when no CPU is free, so firing every shortfall at once on a
one-CPU network means one craft starts and the rest come back rejected — which
read as hard failures on both dashboards and re-fired every retry. Shortfalls
beyond this limit wait quietly as `queued` instead.

Setting this **higher** than your CPU count is the failure mode to avoid: the
surplus requests are rejected on arrival and show as REJECTED. Setting it lower
only makes restocking slower, so when in doubt round down.

This value is pushed to the hw node — it does not read a config file.

### `config.drillPar` — per-material restock floors

Not a scalar setting; it is a table, edited on the editor's **drills** page.

The broker publishes it to the hw telemetry node (`DRILL_PAR` on
`config.ports.hardware`); the node compares it against its own live ME scan and
auto-crafts anything below par.

Only materials listed are ever ordered — an explicit list, so adding a drill
material to the game does not silently start an expensive craft. All nine ship
listed, because all nine are dispatchable: the gate in `tryDispatch()` is
`config.drills`, which has every material. A tier left out still dispatches and
still burns kits; it just never gets restocked, which is the silent stall this
whole feature exists to remove.

**Two numbers per material, doing different jobs:**

- `tips` / `rods` — the stock **floor**. Fall below it and a craft is requested.
- `batch` — the **request size**. Always sent whole, never the shortfall.

Requesting the exact shortfall meant a material sitting just under its floor
produced a trickle — ask for 4096, be 196 short, order 196. Ordering a full batch
instead means every request is worth the crafting CPU it occupies. The trade is
overshoot: floor 4096 with batch 4096 means stock at 4095 orders another 4096 and
lands near 8191 before settling. Lower the batch to hold less, or lower the floor
to craft less often.

Levels are scaled to what each material costs to make rather than held flat. A
flat number is wrong at both ends: a shallow buffer of Steel is nothing on a
mature base, while the same figure in Transcendent Metal is an enormous
unattended craft.

| tier | floor | batch |
|------|-------|-------|
| steel, titanium, tungstensteel | 4096 | 4096 |
| naquadah, naquadahAlloy | 2048 | 2048 |
| neutronium | 1024 | 1024 |
| cosmicNeutronium, infinity, transcendentMetal | 256 | 256 |

**Be aware what the top three cost.** 256 Infinity or Transcendent Metal drill
tips is a large unattended resource commitment. Lower those pars, or switch them
off on the drills page, if you would rather approve those crafts by hand. They
are held low deliberately, and par is only published once you own a drone that
uses them anyway.

Values are in items. One module refill is `tipsPerLoad` of each, which ships at
128, so 4096 is 32 refills. How long a refill lasts depends on the module: the
recipe burns 4 tips and 4 rods per parallel per cycle, and `maxParallels` is
2/4/8 for MK-I/II/III — so on an MK-II a refill covers 8 cycles, making 4096
roughly 256 cycles of buffer.

**Keep every floor at or above `tipsPerLoad`** or a module can stall on the
dispatch floor while nominally sitting at par. The drills page warns when you
set one below it.

If the network has no crafting pattern for a listed item, the node reports it as
`nopattern` and it shows up red on both dashboards — a missing pattern is meant
to be loud, since the failure it replaces (a module that silently never loads) is
the hardest thing in this system to diagnose.

---

## Run polling

### `runPollIdle` / `runSafeFraction`

How often to ask a running module whether it has finished.

Each check is a component call, so a constant fast rate is expensive: nine
modules at four checks a second spend 36 calls a second on a question that is
answered "no" for nearly the whole run, competing with the loads for the same
budget.

The broker learns how long each module runs for (it stops when consumables run
out, so this is very consistent) and checks lazily until the end is near. Run
length is not constant — a recipe cycle varies from a few seconds to fifteen, and
a run is several cycles — so the broker does not try to predict when a run will
end. It remembers the **shortest** run each module has done for its current
asteroid, drill and parallel count, and checks lazily only within a fraction of
that: a window the module has demonstrably never finished in.

- `runPollIdle` — seconds between checks inside that safe window. `0` = check at
  the fast rate throughout, the old behaviour.
- `runSafeFraction` — how much of the shortest observed run counts as safe.
  Lower is more cautious and costs more calls.

Measured across six modules, poll rate against worst-case detection lag:

| `runPollIdle` | calls/s | worst-case lag |
|------|------|------|
| 3.0  | 8.2  | 2.41s |
| 2.0  | 8.9  | 2.32s |
| **1.5** | **9.6** | **1.38s** ← the knee, and the default |
| 1.0  | 11.1 | 1.51s |
| 0.25 | 23.9 | 0.76s (constant fast polling) |

1.5 nearly halves the worst case against 3.0 for 1.4 extra calls a second. Going
all the way to constant costs another fourteen for 0.6s.

---

## Telemetry nodes

These are marked `scope = "node"` in `settings.lua`, which means the broker
broadcasts them and the dust, fluid and hardware nodes apply them live. **This is
why those machines no longer carry `config.lua`.** They ship with
[`node_config.lua`](node_config.lua) — ports and the same defaults, about forty
lines — and cache whatever the broker last sent to `/home/node_settings.lua`, so
a node that restarts during a broker outage still comes up correctly configured.

Resolution order on a node, most authoritative first:

1. what the broker last sent
2. the cached copy of that
3. `node_config.lua` defaults

### `dustScanInterval` / `fluidScanInterval`

Seconds between ME scans on the respective node. Each scan is one
`getItemsInNetwork` / `getFluidsInNetwork` call, and on a large network that
call is the single most expensive thing those machines do — it builds a table
entry per stack. Raise these if a node is running short of memory.

### `wirelessStrength`

Modem range in blocks, applied on the broker and on the dust and fluid nodes.
400 is the tier-2 card's maximum. Lower it only if you have a reason to.

The hw node is not reached by this. It stays off the command port so the dust
watchlist never lands in its memory, and it holds 400 itself.

### `nodeDashboard`

Whether the dust and fluid nodes draw their screens. Turning it off saves each node
its GPU calls and a little memory; the node keeps scanning and broadcasting
exactly as before, it just stops painting.

---

## Interface

### `uiInterval`

Seconds between dashboard repaints.

This was 0.25 when every repaint cost 223 component calls and spanned several
ticks — the panels painted progressively, which is why the screen looked
continuously busy. With the row cache an unchanged frame costs nothing, so the
interval stopped being a throttle and became the only source of latency: updates
arrived in four visible steps a second with nothing moving between.

Going to 0.05 was overcorrecting: the panels still rebuild their row strings
every frame, so 20fps meant five times the Lua work for a screen that mostly does
not change. 0.1 is 2.5× more responsive than the original and 2.5× the CPU, on a
broker whose CPU budget matters because six loaders share it.

### `watchlistInterval`

Seconds between re-broadcasts of the dust watchlist, the drill par table and the
node settings. Sent on a timer as well as on change, so a node that boots late
or restarts picks everything up without having to ask.

### `quiesceSeconds` / `quiesceGrace`

The editor competes with the loader for the per-tick component call budget, so it
is least responsive exactly when the broker is busiest. Rather than pause work
mid-flight — which risks failing a load, since every loader wait is measured
against `computer.uptime()` and would time out while frozen — pressing `E` stops
handing out **new** jobs and lets the in-flight ones land on their own.

- `quiesceSeconds` — the countdown before the editor opens. Dispatch is suspended
  for its duration; loads already running finish untouched.
- `quiesceGrace` — if loads are still running when the countdown ends, keep
  waiting, but only this long, so a wedged module cannot lock you out of the
  editor.

The grace is generous on purpose: a three-item load confirms each fingerprint by
read-back and waits on ME delivery (the arrive timeout alone is 15s per item), so
a healthy load on a laggy server can easily outlast a short grace — and opening
early lands you in exactly the contention this exists to avoid.

---

## Logging

See [`logger.lua`](logger.lua). Disabled by default: ERROR/WARN lines still go to
the log file so you can diagnose problems, but nothing spams the screen and
nothing hits the network. Turn `logging.enabled` on to also capture INFO/DEBUG,
or to use the `console` or `loki` backends.

`logging.bootUnixTime` anchors timestamps to a real epoch if you have a way to
fetch one; otherwise timestamps are uptime-relative.

---

## Ports

`config.ports` is **not** in the settings registry, on purpose.

```lua
config.ports = {
  telemetry = 2026,  -- inbound to broker: telem nodes + job nodes -> broker
  command   = 2027,  -- outbound from broker: broker -> dust/fluid nodes
  hardware  = 2025,  -- outbound from broker: broker -> hw telem node
}
```

Changing a port from inside the editor would disconnect the fleet from the
machine doing the changing, and the nodes have no way to be told about the new
number — the message telling them would go out on it. So ports are edited in
`config.lua` and `node_config.lua` together, deliberately, with a restart.

**Why the hardware node gets its own port** rather than listening on `command`:
the `DUST_WATCHLIST` broadcast carries every tracked dust item, and the hw node
is the most memory-constrained machine in the fleet. Sharing a port would make it
unserialize that packet every 30s only to discard it. 2025 was already opened by
`hw_telem` for a query protocol that never got a client, so this costs nothing
new.

Note that `hw_telem.lua` hardcodes 2025 — it does not load any config. Changing
the number in one place and not the other silently stops drill auto-crafting.

---

## The user overlay

`config.lua` is shipped data: hand-maintained tables plus the generated
`asteroidOutputs` block. It gets regenerated and updated wholesale, so **nothing
you change in game may live there.**

Your choices live in `/home/user_config.lua`, which only the in-game editor ever
writes. One writer per file, so the two can never clobber each other. The overlay
is optional — with no `user_config.lua` present the shipped defaults are used.

| table | merge behaviour |
|-------|-----------------|
| `settings` | merged per key, validated against `settings.lua`. An unknown key or an out-of-range value is reported at boot and ignored, rather than stopping the broker. |
| `conditions` | **replaced** by yours if present — what you track is entirely your call, not something a shipped default should fight |
| `dustTargets` | **merged** over the shipped table, so new mappings you add are added and existing ones can be corrected, while everything you have not touched keeps following updates to `config.lua` |
| `drillPar` | **merged** per material. A par you tuned for one drill wins, while materials you never touched keep following the shipped defaults. Set a material to `false` to stop ordering it entirely. |

The editor writes only what is genuinely yours, worked out against a snapshot
`config.lua` takes before applying the overlay. Writing everything back would
freeze the shipped tables and mask every future correction.

`drillLoad` from older versions is still read, and its five fields are folded
into `settings` on the next save.
