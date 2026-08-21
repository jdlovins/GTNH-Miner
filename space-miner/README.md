# MEDINA — Modular Extraction and Dispatch Intelligence Network Array

Automated wireless mining system for the GTNH Space Elevator. Monitors dust storage levels across your ME network, selects asteroids to target by priority, and loads consumables to drive up to 6 Mining Modules in parallel — all from a single consolidated **Broker MK3** computer.

**Current version: v1.5 (Broker MK3).** A cooperative task scheduler loads all 6 modules concurrently without blocking, achieving ~10× the throughput of the earlier blocking design. The broker dispatches based on telemetry from **three required monitor nodes** — dust (what to mine), hardware (drones/drill kits), and fluid (plasma). It won't start mining until all three report, because mining modules physically require a plasma fluid to operate.

---

## Architecture

```
                         ┌─────────────────────────────────┐
  dust_telem  ──────────►│   BROKER MK3  (port 2026 in)    │
  fluid_telem ──────────►│                                 │
  hw_telem    ──────────►│   cooperative scheduler:        │──► M1 ┐
  (dust+hw required)     │   • dispatch (drone-first)      │──► M2 │ up to 6
                         │   • 6 concurrent load tasks     │──► M3 │ Mining
                         │   • read-back item confirmation │──► M4 │ Modules
                         │   • 3×2 T3 screen dashboard     │──► M5 │ (local)
                         └─────────────────────────────────┘──► M6 ┘
```

Each module has its own ME Interface adapter + transposer; one shared OC Database (slots partitioned per module) holds item fingerprints. Telemetry nodes broadcast on port 2026 (strength 400). The broker drives its modules directly — no separate job-node RPC in the single-broker setup.

---

## Files

| File | Runs on | Purpose |
|------|---------|---------|
| `config.lua` | *all nodes* | Master config — drones, drills, asteroids, plasmas, optimization matrix, dust targets and thresholds. Copy to `/home/config.lua` on every computer. |
| `broker-mk3.lua` | broker | **The broker.** Aggregates telemetry, dispatches jobs (drone-first with a per-asteroid cap), and spawns one cooperative load task per module. Requires `/home/job_node_config.lua`, `/home/scheduler.lua`, `/home/loader.lua`, `/home/logger.lua`. |
| `scheduler.lua` | broker | Cooperative task engine: `spawn`, `sleep`, `await`, fair `lock`. One clock (`computer.uptime`). Lets all 6 loads run concurrently without freezing the UI/telemetry. You never edit this to add features — you spawn a task. |
| `loader.lua` | broker | One module's consumable-load sequence, run as a scheduler task. Confirms database fingerprints by read-back and routes items into the input bus by identity (not slot position). |
| `logger.lua` | broker | Logging with a configurable backend (file / console / Loki). Disabled by default — ERROR/WARN still written to `/tmp/spacemining.log`. Configure under `config.logging`. |
| `dust_telem.lua` | dust node **(required)** | Queries the dust-storage ME subnet every 120 s; broadcasts tracked item stocks to the broker. Broker won't dispatch without it. |
| `hw_telem.lua` | hw node **(required)** | Scans the hardware-staging ME network every 10 s for drone counts and drill kit pairs. Broker won't dispatch without it. |
| `fluid_telem.lua` | fluid node **(required)** | Queries the plasma ME fluid network every 10 s; broadcasts plasma volumes. Modules need plasma to run, so the broker won't dispatch without it. |
| `job_node.lua` | remote worker *(optional)* | Legacy remote worker for additional modules on a separate computer. Retained for future multi-node fleets; not required for the single-broker setup. |

---

## Broker MK3 — Consolidated Cooperative Architecture

**broker-mk3.lua** runs dispatch and consumable loading on one computer. This is the **production version** for MEDINA v1.5.

**Hardware:**
- T2 wireless card (port 2026 in for telemetry)
- T3 GPU + **2 tall × 3 wide T3 screen array**
- **OC Database** — shared consumable storage, partitioned 3 slots per module (M1→1-3, M2→4-6, …). A tier-2 (25-slot) DB covers 6 modules; an MK3 (81-slot) DB covers up to 27.
- **Per-module:** OC Adapter on Mining Module, OC Adapter on ME Interface, Transposer between the interface buffer and the input bus

**Key features:**
1. **Concurrent cooperative loading.** Each module's load runs as a scheduler task (`scheduler.lua` + `loader.lua`). All 6 load at once; the broker never blocks — UI and telemetry stay live throughout. No stagger, no fixed delays.
2. **Self-pacing via read-back.** After writing a fingerprint with `iface.store`, the loader polls `db.get(slot)` until the fingerprint is confirmed, then proceeds — instant when the server is fast, patient when it lags. Replaces guessed sleep constants.
3. **Identity-based item routing.** Items are moved into the input bus by matching their label in the interface buffer, not by trusting slot positions (the ME interface can shuffle buffer slots under load). Each load is verified before the machine is enabled; a bad load ERRORs and auto-recovers in ~10 s rather than running wrong.
4. **Drone-first dispatch with a per-asteroid cap.** Uses the highest-tier available drones first, but no single asteroid may hold more than `floor(totalModules / 2) + 1` modules — so a high-tier target (e.g. Infinity Catalyst) can't starve lower-tier needs. Availability pools subtract drones/kits already committed to busy modules, preventing double-assignment.
5. **Priority-mode boot prompt.** At startup, choose *Threshold* (mine the lowest stock/target ratio first) or *Rarity* (highest dust-priority first, then ratio).

**Throughput:** all 6 modules load in ~1–2 s each and mine in parallel. Measured ~9.4× the earlier blocking design (≈100k → ≈938k Infinity Catalyst dust/hr), confirmed stable over a 12-hour soak test.

**Logging:** via `logger.lua`, configured under `config.logging` (default off; ERROR/WARN still written to `/tmp/spacemining.log`). Backends: `file` (default), `console`, or `loki` if you run Grafana Loki. Each load reports read-back poll counts (`confirm polls d=N t=N r=N, arrive=N`); consistently low counts indicate `store()` is reliable on your setup. The UI also shows a per-module `loaded Xs db:N buf:N` diagnostic.

**Stopping the broker:** break the script in the OC console with **Ctrl+Alt+C**.

---

## Component Detail

### `config.lua` — Shared Master Configuration

Loaded by every node with `dofile("/home/config.lua")`. Sections:

1. **Drone registry** — maps tier keys (`lv`…`max`) to exact ME item names
2. **Drill consumables** — maps drill material keys to tip/rod item names
3. **Module specs** — max parallels, power, and computation per MK tier
4. **Plasma overdrive specs** — τ (time discount), λ (size bonus), mB per parallel
5. **Cycle mode defaults** — distance sweep range/step for dynamic mode
6. **Asteroid database** — 41 asteroids with materials, weights, size range, distance range, computation, EU/t, drone tier bounds, and spawn weight
7. **Optimization matrix** — per `[moduleTier][asteroid][droneKey]` optimal distance (pre-computed from the Space Elevator Calculator spreadsheet)
8. **Dust target registry** — maps each tracked dust/item name to its source asteroid and a priority number
9. **Module filter blacklist** — high-volume junk ores to exclude from module output
10. **Dust stock thresholds** — `config.conditions` — what the broker uses to decide when to mine
11. **Network settings** — `config.ports` (telemetry=2026; command=2027 reserved for optional remote job nodes; hardware=2025 for `DRILL_PAR` to the hw node), `config.pipelineCheckDelay` (default 120 s), `config.drillPar` (per-material stock the hw node auto-crafts back up to)

---

### `dust_telem.lua` — Dust Storage Monitor

**Hardware:** T2 wireless card · T3 GPU · T3 screen · OC Adapter on the **dust-storage ME Controller**

Reads `config.conditions` to know which items and thresholds to track. Queries `adapter.getItemsInNetwork()` and broadcasts a `DUST_UPDATE` payload every `pipelineCheckDelay` seconds (120 s by default — matched to the ore processing pipeline delay so the broker sees real post-processing inventory levels).

**Display (80×25):**
```
================================================================================
 MEDINA RELAY NETWORK  |  NODE: MEDINA-DustRelay            LAST_SYNC: 14:23:07
================================================================================

  ITEM (lowest fill first)           STOCK / TARGET        FILL
  ---------------------------------------------------------------------------
  Ichorium Dust                        245 / 5000             4%   ← red
  Trinium Dust                        1105 / 10000           11%   ← red
  Adamantium Dust                     2340 / 15000           15%   ← red
  Cosmic Neutronium Dust              1820 / 10000           18%   ← red
  Draconic Core Dust                   980 / 5000            19%   ← red
  Aluminium Dust                     52000 / 100000          52%   ← amber
  Chrome Dust                        14200 / 25000           56%   ← amber
  Cobalt Dust                        19000 / 30000           63%   ← amber
  Copper Dust                       125000 / 150000          83%   ← cyan
  Silicon Dust                       78000 / 90000           86%   ← cyan
```
Sorted by fill ratio ascending. Color: red < 25%, amber < 75%, cyan < 100%, dim green ≥ 100%.

---

### `fluid_telem.lua` — Plasma Overdrive Monitor

**Hardware:** T2 wireless card · T3 GPU · T3 screen · OC Adapter on the **plasma ME Fluid Controller**

Scans for all five plasmas by exact name. Determines the highest-tier plasma currently in stock (from `config.plasmaKeyOrder`, tier-descending). Broadcasts `FLUID_UPDATE` every 10 s with all plasma volumes — the broker uses this for plasma selection regardless of mode.

**Display (80×25):**
```
================================================================================
 MEDINA RELAY NETWORK  |  NODE: MEDINA-FluidRelay           LAST_SYNC: 14:23:05
================================================================================

  [ PLASMA OVERDRIVE STOCK ]
  Helium Plasma:        100000 mB
  Bismuth Plasma:        25000 mB
  Radon Plasma:              0 mB   ← dim (empty)
  Technetium Plasma:     12000 mB
  Plutonium-241 Plasma:  50000 mB

--------------------------------------------------------------------------------
  [ HIGHEST AVAILABLE PLASMA ]
  Active Plasma:  Plutonium-241 Plasma
  Current Volume: 50000 mB
  Wireless Range: 400 blocks
================================================================================
```

---

### `hw_telem.lua` — Hardware Inventory Monitor

**Hardware:** T2 wireless card · T3 GPU · T3 screen · OC Adapter on the **hardware-staging ME Controller** (where drones and drill consumables are stored)

Matches items by exact label against a compiled-in lookup table (e.g. `"Cosmic Neutronium Drill Tip"` → key `cosmicNeutronium`) — this node deliberately does **not** load `config.lua`, to stay inside its memory budget. Drone counts are keyed by drone tier key so the broker can compare against `config.droneTierKeys` directly. Broadcasts `HW_UPDATE` every 10 s.

**Auto-crafts drill consumables to par.** The broker publishes `config.drillPar`
as ME labels (`DRILL_PAR`, port 2025); this node diffs par against its own live
scan and asks the ME network to craft the shortfall. Policy stays on the broker,
execution happens here — this node holds the ME controller proxy and the freshest
counts.

Par is published only for materials this base can actually consume — drill keys
reachable from a drone you currently hold, plus whatever busy modules are using.
No MK-XI, no Cosmic Neutronium crafting. And `config.drillCraftSlots` (default 2)
caps how many crafts run at once, matched to your AE2 crafting CPUs: AE2 cancels
requests when no CPU is free, so anything over the limit waits as `queued`
instead of being fired and rejected.

Without it, running low on one material had no visible symptom: the broker
silently refuses to dispatch below 64 kits, so the affected drone tier just stops
being used and its modules sit idle. Materials with no crafting pattern are
reported as `NO CRAFTING PATTERN` on both this display and the broker's hardware
panel, because that is the one part a human has to fix.

With no broker on the air, or an empty `config.drillPar`, it orders nothing and
behaves exactly as it did before.

**Display (80×25):**
```
================================================================================
 MEDINA RELAY NETWORK  |  NODE: MEDINA-HWRelay              LAST_SYNC: 14:23:02
================================================================================

  DRONE FLEET STATUS            DRILL KIT AVAILABILITY
  ---------------------------------------------------------------------------
  MK-XIV        : 0               [ NO FLEET — MASKED ]
  MK-XI         : 2               Cosmic Neutronium   : 8 kits
  MK-X          : 1               Naquadah Alloy      : 12 kits
  MK-IX         : 1               Naquadah            : 16 kits
  MK-VIII       : 0               Tungstensteel       : 20 kits
  MK-VII        : 2               Titanium            : 0 kits
  ...                             Steel               : 48 kits

  ============================================================================
  Wireless Signal Range: 400 blocks
  Network Port: 2026
```
Drones with stock cyan, zero dim. Drill kits shown as matched pairs (tip count ∧ rod count). "MASKED" replaces drill data if the total drone count is zero.

---

### `broker-mk3.lua` — Central Controller

**Hardware:** T2 wireless card · T3 GPU · **2 tall × 3 wide T3 screen array** · shared OC Database · per-module ME-interface adapter + transposer + module adapter

On startup it prompts for **priority mode** (Threshold ratio vs Rarity first), then draws the dashboard and runs the main loop.

**Dispatch** (drone-first, on a short interval):
1. Build a needs list from `config.conditions` — items below their `amountToMaintain` threshold, sorted by the chosen priority mode.
2. Compute availability pools: drones and drill kits in stock **minus** those already committed to busy modules (prevents double-assigning one physical drone).
3. Iterate drones highest-tier first; for each, find a needed asteroid that drone can mine and that is **under its per-asteroid module cap** (`floor(totalModules/2)+1`).
4. Assign an idle module: set status LOADING and `spawn` a cooperative load task. Loads run concurrently; the loop never blocks.

**Module lifecycle:** `IDLE → LOADING (load task) → RUNNING → DONE → IDLE`. A failed/mismatched load goes to `ERROR` and auto-recovers after ~10 s.

**Dashboard — three panels (3×2 screen):**

```
MODULES                    DUST STOCK                 HARDWARE
M1 [MK-II]  RUNNING  Ich   ! Uranium 238 Dust   29%   NEXT: Infinity Catalyst
  dist=91  drone=MK-X      ! Infinity Cat Dust  33%   PRIORITY: THRESHOLD  CAP: 4/asteroid
  loaded 1.4s db:1 buf:1   ! Diamond            41%   TELEMETRY SYNC: Dust/Fluid/HW
                             Cosmic Neutronium  122%   TASKS RUNNING: 2
M2 [MK-II]  LOADING Inf      Nether Star        315%   DRONES IN STOCK: MK-X x1 ...
...                                                     DRILL KITS IN STOCK: Naquadah x7782 ...
```

Module panel shows each module's state, its job's distance/drone, and the per-load diagnostic. Dust panel marks `!` for items below threshold. Hardware panel shows the active priority mode, per-asteroid cap, telemetry freshness, live task count, drone stock, and drill-kit stock.

---

### `job_node.lua` — Mining Module Worker

**Hardware (shared per node):** T2 wireless card · OC Database component (tier 2, 25 slots — covers all 6 modules) · optional GPU + screen

**Hardware per module slot:** OC Adapter on Mining Module · OC Adapter on ME Interface · OC Transposer between ME Interface buffer and Input Bus

Plasma is supplied by hardware only — connect an ME Fluid Export Bus directly to each module's Input Hatch. The script does not load plasma.

On first run, auto-generates `/home/job_node_config.lua` with full comments and exits. Fill in addresses (use `component.list()` in the OC console), then restart.

**Node-level config field:**

| Field | Description |
|-------|-------------|
| `dbAddr` | Shared OC Database component address. Tier 2 (25 slots) covers 6 modules. Each module uses 3 slots: M1→1-3, M2→4-6 … M6→16-18. |

**Per-module config fields:**

| Field | Description |
|-------|-------------|
| `tier` | `"MK-I"`, `"MK-II"`, or `"MK-III"` |
| `moduleAddr` | OC Adapter on the Mining Module controller block |
| `ifaceAddr` | OC Adapter on the ME Interface |
| `transposerAddr` | OC Transposer between ME Interface and Input Bus |
| `interfaceSide` | Side of transposer facing the ME Interface buffer (0–5) |
| `inputBusSide` | Side of transposer facing the Input Bus (0–5) |
| `distanceParam` | `setParameters` index for distance — confirmed as `0` in-game |

**Per-module state machine** (advances every 0.5 s, all slots run concurrently):

```
IDLE ──[JOB_ASSIGN]──► LOADING ──[load ok + started]──► RUNNING
                            │                                │
                          ERROR ◄──────────── [isMachineActive = false]──► DONE
                            │                                                  │
                            └──[JOB_COMPLETE sent]──► IDLE ◄──────────────────┘
```

**Item loading sequence (confirmed in-game API path):**
1. `iface.store({label=name}, dbAddress, slot)` — write item fingerprint from ME into the shared database
2. `iface.setInterfaceConfiguration(slot, dbAddress, dbSlot, count)` — tell the interface to pull those items from ME into its buffer
3. Poll `transposer.getSlotStackSize(interfaceSide, slot)` until expected counts appear
4. `transposer.transferItem(interfaceSide, inputBusSide, count, fromSlot, toSlot)` — move to Input Bus
5. `iface.setInterfaceConfiguration(slot)` — clear the configuration so ME stops refilling

On completion, all items (including the unconsumed drone) are returned to ME by iterating the Input Bus slots via `transposer.transferItem`. Registers with the broker every 30 s so a broker restart picks up all nodes automatically.

**Display (80×25):**
```
 MEDINA JOB NODE  |  MEDINA-Ring-1                        SYNC: 14:23:15
==============================================================================
  SLOT  TIER      STATUS
------------------------------------------------------------------------------
  M1    MK-II     RUNNING    Ichorium
  M2    MK-II     RUNNING    Cosmic
  M3    MK-III    RUNNING    Draconic Core
  M4    MK-I      IDLE
  M5    MK-I      IDLE
  M6    MK-I      IDLE
[14:23:08] RUN  M1: Ichorium dist=81 x8
[14:23:09] RUN  M2: Cosmic dist=91 x4
[14:21:34] RUN  M3: Draconic Core dist=161 x1
[14:21:33] DONE M4: Aluminium-LanthLine
```
RUNNING amber · LOADING yellow · ERROR red · IDLE dim.

---

## Deployment

### 1. Shared config

Copy `config.lua` to `/home/config.lua` on **every** computer in the system.

### 2. Telemetry nodes

**All three telem nodes are required** — dust (`dust_telem.lua`), hardware
(`hw_telem.lua`), and fluid/plasma (`fluid_telem.lua`). The broker stays at
"Waiting for telemetry..." and dispatches nothing until all three report. (Plasma
is required because mining modules physically can't run without a plasma fluid.)

Each telem node needs only its own script and `config.lua`:

```
/home/config.lua
/home/dust_telem.lua    (or hw_telem.lua / fluid_telem.lua)
```

Set `targetSide` at the top of each script to the side of the OC Adapter facing
the relevant ME Controller (dust node → dust-storage network; hardware node →
the network holding your drones/drill bits). Boot and leave running.

### 3. Broker MK3 (primary deployment)

Copy these to the broker computer:

```
/home/config.lua
/home/job_node_config.lua    (your module hardware addresses)
/home/broker-mk3.lua
/home/scheduler.lua
/home/loader.lua
/home/logger.lua
```

**First boot:**
1. Copy `job_node_config.example.lua` to `/home/job_node_config.lua` and fill in your hardware:
   - `dbAddr` — the shared OC Database (3 slots used per module)
   - per module: `tier`, `moduleAddr` (module controller adapter), `ifaceAddr` (ME interface adapter), `transposerAddr`, `interfaceSide`, `inputBusSide`
   - Find addresses with `list_components.lua`, or add modules with `detect_module.lua`.
2. Run `broker-mk3.lua`. It prompts for **priority mode** (Threshold / Rarity), then draws the dashboard and begins dispatching once telemetry arrives.

To stop it, break the script with **Ctrl+Alt+C** in the OC console.

### 4. Multi-node fleets (future / optional)

The single broker is limited by the host computer's component budget (≈6 modules on a typical bus; far more on a creative component bus). The shared database caps the fleet at **27 modules** (81 slots ÷ 3). To scale past one broker's component limit, `job_node.lua` can run remote workers on additional computers — each driving its own modules and partitioning into the shared database. This is the path back toward the multi-elevator architecture; the per-asteroid cap already scales with total module count.

---

## Job Flow

```
1. dust_telem broadcasts DUST_UPDATE (stock levels) every 120 s
2. fluid_telem broadcasts FLUID_UPDATE (plasma volumes) every 10 s
3. hw_telem broadcasts HW_UPDATE (drones/drills) every 10 s

4. Broker dispatch cycle (every 1 second):
   a. Get all idle modules from registered job nodes
   b. Build needs list from config.conditions (items below threshold)
   c. For each idle module:
      - Find next asteroid from needs list not on cooldown and not already being mined
      - Select best drone (highest tier within asteroid's minDrone/maxDrone, with stock > 0)
      - Verify drill consumables available
      - Look up optimal distance from config.optimizationMatrix
      - Broadcast JOB_ASSIGN on port 2027
   d. Mark dispatched asteroids to prevent double-assignment in this batch

5. Job node receives JOB_ASSIGN (checks msg.target == nodeId):
   a. store() fingerprints into db slots, setInterfaceConfiguration() to pull from ME
   b. Poll transposer slot sizes until drone + 4×parallels tips + rods are present
   c. transferItem() drone/tips/rods into Input Bus; clear interface config
   d. setParameters(0, 0, distance), setWorkAllowed(true)
   e. Poll isMachineActive() every 10 s (5 s startup grace period)

6. Job complete:
   a. Job node iterates Input Bus slots and returns all items (including drone) to ME
   b. Broadcasts JOB_COMPLETE; broker frees the module and sets pipelineCheckDelay cooldown
   c. After cooldown, broker re-evaluates and may re-dispatch the same asteroid
```

---

## Notes

- **`distanceParam` index** — confirmed as `0` in-game. The default in `job_node_config.lua` is already correct. Verify with `component.proxy(component.get("<moduleAddr>")).getParametersInfo()` if behaviour seems wrong.
- **Plasma supply** — the script does not load plasma. Connect an ME Fluid Export Bus directly to each module's Input Hatch and configure it to export the plasma type you want for that module. The broker selects plasma based on mode (best/single/tiered) and reports it in `hw_telem`; the physical export bus must be pre-configured to match.
- **Database slots** — each module uses 3 consecutive slots in the shared database (M1→1-3, M2→4-6, …). The script writes fingerprints at runtime via `store()` — the database does not need to be pre-loaded manually.
- **Ore → dust pipeline** — the broker triggers on dust levels, not ore. Ore outputs to an ore-processing subnet, then dusts arrive in the dust-storage subnet where `dust_telem` is watching. `pipelineCheckDelay` (default 120 s) is the cooldown the broker waits after a job completes before re-checking — tune this to your ore factory throughput.
- **Draconic Core** — always capped at 1 parallel regardless of module tier due to its 7.8 M EU/t draw per parallel. The broker enforces this automatically.
- **Distances > 200** — some entries in the optimization matrix are `201`+ (optimizer result exceeded the valid range). The broker clamps all dispatched distances to 200.
- **Component budget** — 6 modules × 3 components (module adapter + ME Interface adapter + transposer) = 18 + ~4 overhead (modem, GPU, database, computer) = 22 of the 32 OC component limit per computer.

## Config file ownership

Three files, three writers, one writer each. They never overwrite each other.

| file | written by | contains |
|---|---|---|
| `config.lua` | this repo | shipped tables plus the generated `asteroidOutputs` block. Regenerated wholesale, so never hand-edit it in game. |
| `user_config.lua` | the in-game editor (press `E`) | what you track, any dust→asteroid mappings you added, and your drill par overrides. Safe to hand-edit. |
| `job_node_config.lua` | `detect_module` / `detect_sides` | your hardware addresses and transposer sides. |

`config.lua` applies `user_config.lua` as an overlay at the end:

- **`conditions`** — yours replaces the shipped list outright. What you stock is
  your call.
- **`dustTargets`** — yours merges over the shipped table, so mappings you added
  or corrected win, while everything you have not touched keeps following
  updates to `config.lua`.
- **`drillPar`** — merges per material, same reasoning. Set a material to `false`
  to stop ordering it entirely:

  ```lua
  drillPar = {
    naquadah = { tips = 512, rods = 512 },  -- keep more of the one you burn most
    steel    = false,                        -- stop auto-crafting this entirely
  }
  ```

  Par is not edited by the in-game editor — hand-edit `user_config.lua` for this
  one. Keep any par at or above `config.tipsPerLoad` (64) or a module can still
  stall while nominally "at par". `config.drillCraftSlots` sets how many crafts
  may run at once; set it to your AE2 crafting CPU count. Rounding down only
  slows restocking, whereas setting it too high produces rejected requests.

  Shipped par is scaled to material cost rather than flat — 4096 for
  steel/titanium/tungstensteel, 2048 for the naquadahs, 1024 for neutronium, 256
  for the top three tiers — because a flat number is simultaneously too shallow
  for cheap tiers and too aggressive for expensive ones. Values are in items; one
  module refill is 64 of each.

The editor only persists mappings that are genuinely yours, compared against
`config.shippedDustTargets` — the snapshot taken before the overlay is applied.
Writing all of them back would freeze the shipped table and mask every future
label correction.

`user_config.lua` is optional. Without it the shipped defaults apply exactly as
before, so a fresh install needs nothing extra.
