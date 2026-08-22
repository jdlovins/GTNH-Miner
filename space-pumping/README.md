# GTNH Space Gas Logistics Terminal

An OpenComputers controller for GregTech: New Horizons Space Elevator **Pumping
Modules**. It keeps a list of planetary fluids topped up, deciding which module
pumps what, and shows the whole array on one dashboard.

Sibling project: [`../space-miner`](../space-miner) does the same job for Mining
Modules. The two share `scheduler.lua` and `logger.lua` verbatim.

---

## Files

| File | What it is |
|---|---|
| `autoPump.lua` | the program you run — main loop and boot sequence |
| `config.lua` | shipped data: where each fluid comes from, plus every tunable |
| `pumps.lua` | hardware, per-pump state machine, work assignment |
| `ui.lua` | the dashboard |
| `editor.lua` | the in-game fluid editor (press **E**) |
| `scheduler.lua` | cooperative task engine (shared with space-miner) |
| `logger.lua` | logging (shared with space-miner) |
| `install-pump.lua` | one-shot downloader |

Plus one file the program writes rather than ships: `/home/user_config.lua`, which
the editor owns. Nothing else writes it and `install-pump` never touches it, so
your choices survive an update.

> **Upgrading from `autoPump-LargeScreen.lua`?** It has been replaced by the
> files above. Run `install-pump`, then start `autoPump` instead. Your
> `config.lua` keeps the same `config.master` layout, so copy your
> `{planet, slot}` pairs across; everything else in it is new.

---

## What you need

**One OpenComputers computer**

| Part | Minimum | Comfortable |
|---|---|---|
| CPU | Tier 2 | Tier 3 or APU |
| RAM | 2× Tier 2 | 2× Tier 3.5 |
| GPU | Tier 2 | Tier 3 |
| Screen | Tier 2 | Tier 3, 3 wide × 2 tall |
| Other | HDD, keyboard, **Internet Card** (for `wget`) | |

**Adapters — one per thing the computer talks to**

- One **Adapter** touching each Space Pumping Module's **controller block**.
  Each appears as a `gt_machine` component, and the script reads its tier from
  `getName()`.
- One **Adapter** touching a **dual ME Interface on the fluid subnet the pumps
  output into**. This is where every stock figure comes from. Point it at the
  network that actually holds your fluid cells — if you point it at the main
  base network instead, every fill percentage on the dashboard will be wrong and
  the array will pump the wrong things.

  An Adapter on an **ME Controller** works equally well and is tried as a
  fallback. `config.meComponents` sets the order; the first type present wins.
  The interface is the better default because a small fluid subnet often has no
  controller block at all, and then there is nothing for an Adapter to expose.

All adapters must be on the same OpenComputers cable network as the computer.

Supported modules, out of the box:

| `getName()` | Tier | Threads | Multiplier |
|---|---|---|---|
| `projectmodulepumpt1` | T1 | 1 | 4× |
| `projectmodulepumpt2` | T2 | 4 | 16× |
| `projectmodulepumpt3` | T3 | 4 | 256× |

Anything else on the network is ignored. To add a modded tier, put a row in
`config.tiers`.

---

## Install

Check the computer can see the hardware first:

```
components
```

You want one `gt_machine` per pumping module, plus an `me_interface` (or an
`me_controller`) for the fluid subnet. If a module is missing, its Adapter is not
touching the controller block.

Then:

```
wget https://raw.githubusercontent.com/jdlovins/GTNH-Miner/main/space-pumping/install-pump.lua /home/install-pump.lua
```

```
install-pump
```

It pulls every file into `/home/`. Re-running it refreshes the program files and
**leaves your `config.lua` alone** — your planet/slot layout is not something to
overwrite by accident. Delete `config.lua` first if you do want the shipped
defaults back.

---

## Configure

Everything lives in `/home/config.lua`.

### 1. Storage target

```lua
config.currentCellType   = "16384k"   -- the ME fluid cell size backing this subnet
config.safetyMargin      = 0.20       -- fill to 80%; 0.15-0.25 is the sane band
config.maxTargetOverride = 0          -- 0 = derive from the cell type
```

`maxTargetOverride` forces a flat target in litres, for testing at small scales.
Leave it at `0` in normal use — a non-zero value silently ignores your cell
choice.

### 2. What to stock — do this in game

Press **E** on the dashboard. That is the whole feature: a list of every fluid,
tick the ones you want, set how much of each to keep.

```
FLUID EDITOR    3 of 40 stocked    * unsaved
global target 27.28 GL

FLUID                  MAINTAIN        HAVE            FILL      PRI
------------------------------------------------------------------------
 [x] Hydrogen          5.00 GL         4.21 GL         84.2%     p5
 [x] Deuterium         global          19.80 GL        72.5%     p5
 [ ] Krypton           --              0.00  L         --        p0
```

| Key | Does |
|---|---|
| up/down, pgup/pgdn, home/end | move |
| `space` | start / stop stocking the selected fluid |
| `enter` | type an amount — `5g`, `500m`, `250000`. Blank means "use the global target" |
| `t` | cycle through common amounts without typing |
| `a` / `n` | stock / unstock everything currently shown |
| `/` | filter the list by name |
| `s` | save |
| `esc` | close (asks once if you have unsaved changes) |

`a` and `n` apply to what the filter is showing, not all forty — so `/oil` then
`a` stocks just the oils.

Saving writes `/home/user_config.lua` and applies immediately; no restart. While
the editor is open no *new* work is handed out, so the array drains to idle
rather than arming pumps against a list you are halfway through changing. Work
already in flight finishes normally.

**Two defaults worth knowing.** With no `user_config.lua` the array stocks
everything in `config.master` at the global target — what it did before per-fluid
amounts existed. Once you have saved, the list is exactly what you chose, and an
empty list genuinely means "stock nothing" rather than reverting to everything.

### 3. The fluid list — where each fluid comes from

```lua
config.master = {
  ['Hydrogen'] = {priority=5, setting={8,1}, rate=78400},
  ...
}
```

- **`setting = {planet, slot}`** must match **your** space station's layout. This
  is the single most common misconfiguration: with the wrong pair the module
  runs happily and nothing arrives.
- **`priority`** 0–5. Higher is pumped sooner among fluids that are below target.
  Use 4–5 for whatever is gating your current progression.
- **`rate`** is a wiki-sourced estimate used **only** for the throughput figure
  shown beside a working pump. It does not affect what gets pumped or how fast.

To add a fluid the station can reach, add a row here. To stop *stocking* one,
untick it in the editor — leave the mapping alone, since where it comes from is
still true.

### 4. Tunables (optional)

`config.tuning` holds every interval, timeout and threshold, all in **real
seconds**. The defaults are fine; the ones worth knowing about:

| Key | Default | What it does |
|---|---|---|
| `pollInterval` | 1.0 | how often the ME network is re-read |
| `uiInterval` | 0.25 | dashboard repaint cadence |
| `snapshotInterval` | 6.0 | window the flow rates are measured over |
| `armTimeout` | 5.0 | how long to wait for a module to confirm it started |
| `rescanInterval` | 30.0 | how often new modules are picked up |
| `minDeficitFraction` | 0.002 | ignore a fluid less than 0.2% short |

### 5. Logging (optional)

```lua
config.logging.enabled = true    -- INFO/DEBUG as well as errors
```

With `enabled = false` (the default) errors and warnings are still written to
`/tmp/spacepump.log`, so a failure always leaves a trail. Note that OpenComputers'
`/tmp` is a RAM disk and is wiped on reboot.

---

## Run

```
autoPump
```

Boot goes: discover modules → close every work gate → wait for the array to go
quiet → dashboard.

Check the PUMP ARRAY panel lists every module at the right tier before walking
away.

**Autostart:** add a line reading `autoPump` to `/home/.shrc`.

---

## Operating modes

Press a key while it is running.

| Key | Mode | Behaviour |
|---|---|---|
| `N` | Normal | anything below target, highest priority first, then emptiest first. Balanced. |
| `S` | Stairstep | everything under 10% first, then under 50%, then the rest. Fastest recovery from empty. |
| `W` | Waterfall | the whole array on one fluid until it is full, then the next. Sequential. |
| `E` | edit | opens the fluid editor. |
| `Q` | quit | stops every module and exits cleanly. |

In Normal and Stairstep the array never doubles up: fluids already being pumped
are skipped, and the biggest module is offered the deepest shortfall. Waterfall
deliberately overrides that — pointing everything at one fluid is the whole idea.

---

## Dashboard

```
================================ GTNH SPACE-GAS LOGISTICS TERMINAL ================================
  CELL: 16384k   SAFE: 80%   MAX: 27.28 GL          ME: OK      MODE: Normal

PUMP ARRAY STATUS
---------------------------------------------------------------------------------------------------
a3f1 T3   RUNNING  Hydrogen             20.06 ML/t     b7c2 T2   RUNNING  Deuterium    1.25 ML/t
c910 T1   IDLE     None                 ---            d4e8 T2   ERROR    did not start within 5.0s

FLUID DEMAND QUEUE
---------------------------------------------------------------------------------------------------
Hydrogen          85.432%     23.13 GL /   27.28 GL   Oxygen     12.004%   3.27 GL /  27.28 GL
...

NET FLOW   (total in: 42.10 ML/s)
---------------------------------------------------------------------------------------------------
TOP INFLOW:                                  TOP OUTFLOW:
Hydrogen           +18.20 ML/s               Heavy Oil        -2.10 ML/s

TARGET: 27.28 GL                    >[N]ormal   [S]tairstep   [W]aterfall   [E]dit   [Q]uit
```

**Fill colours:** red under 50%, orange 50–95%, green 95–110%, magenta above 110%
(over target, which is harmless — it just means there is headroom). The percentage
is against **that fluid's own** ceiling, so it stays comparable across fluids you
keep very different amounts of.

**NET FLOW** is litres per second, measured over the last `snapshotInterval`.
It is a rate, not a percentage — an absolute rate has no blind spot for a fluid
that started empty, and it is the number you can actually compare against a
module's throughput.

**Pump states:** `IDLE` waiting for work · `ARMING` starting a cycle ·
`RUNNING` pumping · `ERROR` faulted, retrying after a cooldown.

---

## Troubleshooting

**No modules found at boot.** The Adapter must touch the module's *controller*
block. Run `components` and look for `gt_machine`. If one is listed but not
adopted, its `getName()` is not in `config.tiers` — add it there.

**`ME: DOWN` in the header.** Nothing in `config.meComponents` is on the network,
or the call failed (chunk unloaded, adapter removed). The most common cause is an
Adapter on a fluid subnet with no ME Controller *and* no ME Interface for it to
attach to. The program keeps running and re-acquires on its own; it just will not
assign new work while the stock figures are unknown.

**A module sits in ERROR: "did not start within 5.0s".** It accepted the
parameters but never became active. Usual causes: the Space Elevator is not
powered, there is not enough computation allocated to the module, or the
`{planet, slot}` pair for that fluid does not exist on your station. The module
retries automatically after `errorCooldown`.

**Pumps run but nothing arrives in the ME.** Almost always a wrong
`setting = {planet, slot}`. Check it against your actual station layout.

**Storage overfilling.** Lower `safetyMargin`, give the offending fluid a smaller
amount in the editor, or untick it.

**Config changes not taking effect.** `config.lua` is read once at startup, so
restart `autoPump` after editing it by hand. Changes made in the **E** editor
apply the moment you save — no restart.

**Everything looks slow.** Raise `uiInterval` and `pollInterval`. The row cache
means an unchanged dashboard costs almost nothing, so this is rarely the problem
— check for a module stuck in an arm/error loop in `/tmp/spacepump.log` instead.

---

## How it works

- **Discovery** scans for `gt_machine` components, matches `getName()` against
  `config.tiers`, and sorts the array by capacity so the biggest module gets the
  deepest shortfall. Re-run every 30s, matching by address, so a module added
  mid-run joins without disturbing anything in flight.
- **Demand** is rebuilt each second from `getFluidsInNetwork()`, measured against
  each fluid's own ceiling so the percentages stay comparable, then sorted by the
  current mode. The comparators end in a label tie-break so the queue does not
  reshuffle between frames when nothing has changed.
- **Assignment** claims the fluids that running modules already hold, then walks
  idle modules against the need queue.
- **Arming** runs as a scheduler task: write the parameters, open the work gate,
  then wait for `isMachineActive()` to confirm the cycle actually started before
  closing the gate again. Confirming beats sleeping a guess — instant on a fast
  server, patient on a laggy one.
- **Every component call is wrapped.** An adapter pulled out puts one module in
  ERROR with a cooldown; the rest of the array keeps pumping.
- **One clock.** Everything is measured against `computer.uptime()` in real
  seconds. No world ticks anywhere.

---

## License & credits

Built for the GTNH community. Descended from the OpenComputers Space Pumping
script on the [GTNH wiki](https://wiki.gtnewhorizons.com/wiki/Open_Computers_Space_Pumping).
