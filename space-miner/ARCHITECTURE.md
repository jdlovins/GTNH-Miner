# MEDINA System Architecture

## Overview

MEDINA (Modular Extraction and Dispatch Intelligence Network Array) is a wireless automation system for GTNH Space Elevator mining.

**v1.5 (Current) — Broker MK3:** A single consolidated broker computer handles dispatch AND consumable loading for up to 6 local Mining Modules. A small **cooperative task scheduler** (`scheduler.lua`) runs each module's load as a coroutine, so all 6 load concurrently while the UI and telemetry stay live. Loads are self-pacing (database fingerprints confirmed by read-back) and route items by identity rather than slot position. Measured ~9.4× the throughput of the earlier blocking design (~100k → ~938k Infinity Catalyst dust/hr), validated over a 12-hour soak test.

**Evolution:** v0.x separated broker (dispatch) and job_node (consumables) across computers. v1.0 (Broker MK2) consolidated them but loaded modules sequentially with blocking sleeps, freezing the broker during each load. v1.5 (Broker MK3) keeps the consolidation but makes loading concurrent and non-blocking. The optional `job_node.lua` remote-worker path is retained for future multi-node fleets (the shared 81-slot MK3 database caps a fleet at 27 modules).

## System Diagram

```
┌─────────────────────────────────────────────────────────────────────────┐
│                        MEDINA SYSTEM ARCHITECTURE                       │
└─────────────────────────────────────────────────────────────────────────┘

                          ┌──────────────────┐
                          │   BROKER NODE    │
                          │  MEDINA-Station  │
                          │  (3×2 T3 Screen) │
                          └────────┬─────────┘
                                   │
                 ┌─────────────────┼─────────────────┐
                 │                 │                 │
          Port 2026 (RX)    Port 2026 (RX)    Port 2026 (RX)
                 │                 │                 │
        ┌────────▼────────┐ ┌──────▼──────┐ ┌───────▼────────┐
        │  DUST TELEMETRY │ │ HW TELEMETRY│ │ FLUID TELEMETRY│
        │  dust_telem.lua │ │hw_telem.lua │ │fluid_telem.lua │
        │ (DUST_UPDATE)   │ │(HW_UPDATE)  │ │(FLUID_UPDATE)  │
        │  every 10s      │ │ every 10s   │ │  every 10s     │
        └────────┬────────┘ └──────┬──────┘ └───────┬────────┘
                 │                 │                 │
         ┌───────▼─────────────────▼─────────────────▼──────┐
         │        BROKER STATE AGGREGATION                  │
         │  • Dust levels (stock vs threshold)              │
         │  • Drone availability (all 14 tiers)             │
         │  • Drill kits (by material, tips+rods)           │
         │  • Plasma levels (all 5 tiers)                   │
         │  • Hardware health                               │
         └───────┬──────────────────────────────────────────┘
                 │
         ┌───────▼───────────────────────────────┐
         │   BATCH JOB DISPATCH                  │
         │  (Every 1 second)                     │
         │  • Get all idle modules               │
         │  • Build needs list (items < target)  │
         │  • For each module: assign next asteroid
         │  • Check drone availability           │
         │  • Check drill kit availability       │
         │  • Look up optimal distance           │
         └───────┬─────────────────────────────┘
                 │
      Port 2027 (TX broadcast)
                 │
         ┌───────▼──────────────────────────────────────────┐
         │            JOB NODES (1 to N)                    │
         │         job_node.lua × N instances               │
         │                                                  │
         │  ┌────────────────────────────────────────────┐  │
         │  │  JOB_NODE #1                               │  │
         │  │  ┌─────────────────────────────────────┐   │  │
         │  │  │ MODULE #1 (MK-I/II/III Tier)        │   │  │
         │  │  │  • Receives MEDINA_COMMAND job      │   │  │
         │  │  │  • Loads drill tips & rods via ME   │   │  │
         │  │  │  • Loads drone via ME               │   │  │
         │  │  │  • Sends to Input Bus               │   │  │
         │  │  │  • Runs recipe at distance/OD       │   │  │
         │  │  │  • Recovers items via transposer    │   │  │
         │  │  └─────────────────────────────────────┘   │  │
         │  │                                            │  │
         │  │  ┌─────────────────────────────────────┐   │  │
         │  │  │ MODULE #2 (parallel mining)         │   │  │
         │  │  └─────────────────────────────────────┘   │  │
         │  │                                            │  │
         │  │  ┌─────────────────────────────────────┐   │  │
         │  │  │ ... up to 6 modules per node        │   │  │
         │  │  └─────────────────────────────────────┘   │  │
         │  │                                            │  │
         │  │ HW CONNECTIONS:                            │  │
         │  │  • ME Interface (item import/export)       │  │
         │  │  • Database (item fingerprints)            │  │
         │  │  • Transposer (item movement to bus)       │  │
         │  │  • Mining Module (recipe control)          │  │
         │  └────────────────────────────────────────────┘  │
         │                                                  │
         │  ┌────────────────────────────────────────────┐  │
         │  │  JOB_NODE #2 ... JOB_NODE #N (same setup)  │  │
         │  └────────────────────────────────────────────┘  │
         └──────────────────────────────────────────────────┘
                 │
        Port 2026 (TX Telemetry back to broker)
                 │
      ┌──────────▼──────────┐
      │  Status: IDLE/BUSY  │
      │  Modules: [jobs]    │
      │  Last seen: XX:XX   │
      └─────────────────────┘
```

## Component Specifications

### Broker Node (broker-mk3.lua)

**Purpose:** Central controller. Aggregates telemetry, selects mining targets, and drives up to 6 local Mining Modules — dispatching jobs and loading their consumables in one process.

**Hardware:**
- Tier 2 Wireless Network Card (strength 400)
- GPU + 3×2 T3 screen array
- Shared OC Database (3 slots per module)
- Per module: module-controller adapter, ME-interface adapter, transposer

**Supporting modules (on the same computer):**
- `settings.lua` — the tunable registry: every runtime knob declared once with its type, legal range and one-line help. `config.lua` seeds defaults from it, the editor's settings page is built from it, and the node broadcast is the subset marked `scope = "node"`. See SETTINGS.md.
- `scheduler.lua` — cooperative task engine (spawn / sleep / await / lock; one clock via `computer.uptime`)
- `loader.lua` — per-module load sequence, run as a task; read-back confirmation + identity-based item routing
- `editor.lua` — the in-game condition editor (press `E`). Dependencies arrive through `editor.init(deps)`; the broker asks it only `isOpen()`, `handle(ev)`, `draw()` and `takeRequests()`. It was split out when `broker-mk3.lua` reached Lua's limit of 200 locals per chunk — the same layout `space-pumping` already uses.
- `module_api.lua` — the GTNH 2.8 / 2.9 mining-module parameter API. Every version-dependent call to a module controller lives here and nowhere else.
- `logger.lua` — configurable logging (file / console / Loki); disabled by default, ERROR/WARN to `/tmp/spacemining.log`

**Network:**
- **Inbound (Port 2026):** telemetry from dust_telem / hw_telem / fluid_telem
- **Outbound (Port 2027):** DUST_WATCHLIST and NODE_SETTINGS to the dust and fluid nodes; also carries jobs to optional remote job nodes
- **Outbound (Port 2025):** DRILL_PAR to the hw node

**State Tracked:**
- Dust levels (stock vs. thresholds), drone counts, drill kits, plasma levels — from telemetry
- Live module status (IDLE / LOADING / RUNNING / DONE / ERROR) and per-load diagnostics

**Dispatch Logic (drone-first, on a short interval):**
- Build a needs list (items below threshold) sorted by priority mode
- Compute availability = telemetry stock − drones/kits already committed to busy modules
- Iterate drones highest-tier first; assign a needed, drone-eligible asteroid that is under its per-asteroid cap of `floor(totalModules/2)+1`
- Each assignment spawns a concurrent cooperative load task; the dispatch loop never blocks

**Boot Configuration:**
- Priority mode prompt: "threshold" (lowest stock/target ratio first) or "rarity" (highest dust priority first, then ratio)
- (Plasma mode selection is not implemented; plasma is supplied by a hardware ME Fluid Export Bus.)
- Everything else is configured from the in-game editor: press **E**, then the asteroid pages for what to mine, `d` for drill consumables, and `g` for every other setting. Changes apply live and are written to `/home/user_config.lua`.
- Stop the broker with **Ctrl+Alt+C** in the OC console.

---

### Dust Telemetry Node (dust_telem.lua)

**Purpose:** Scans dust storage subnet and broadcasts inventory levels to the broker.

**Hardware:**
- Tier 2 Wireless Network Card
- GPU (small display)
- ME Controller or ME Interface (read-only access to dust storage)

**Network:**
- **Outbound (Port 2026):** Broadcasts DUST_UPDATE payload every `dustScanInterval` (10s default)
- **Inbound (Port 2027):** Receives DUST_WATCHLIST (what to scan) and NODE_SETTINGS (how often, how far) from the broker

**Monitored Items:**
- Whatever the broker's `config.conditions` currently holds, pushed over the wire
- Only items below threshold trigger mining jobs

**No config file at all.** This node is one script. It carries its two port
numbers at the top — OpenComputers makes you `modem.open()` an explicit port, so
that much cannot be pushed — and gets everything else from the broker. Loading
the 3000-line `config.lua` for two values was the direct cause of this node's
out-of-memory failures, since it then has to hold a full ME network scan in what
is left. A node that has never heard from the broker scans nothing and says so,
rather than guessing from a local copy that may have drifted.

---

### Hardware Telemetry Node (hw_telem.lua)

**Purpose:** Scans the drone and drill consumable inventory from the hardware-staging ME network, broadcasts availability to broker.

**Hardware:**
- Tier 2 Wireless Network Card
- GPU (dashboard display)
- OC Adapter on ME Controller (read-only access to hardware-staging ME network)

**Network:**
- **Outbound (Port 2026):** Broadcasts HW_UPDATE payload every 10 seconds
- Payload: drone counts (by tier key), drill kit counts (tips ∩ rods by material), and any outstanding restock orders
- **Inbound (Port 2025):** Receives DRILL_PAR from the broker — the par levels this node crafts back up to

Note the 10s cadence is nominal. The loop's `event.pull(10, ...)` returns early on
any modem traffic on an open port, and the other telem nodes broadcast on 2026
continuously, so iterations are frequent and irregular. Anything in this node that
needs to be rate-limited uses `computer.uptime()`, never a loop counter.

**Inventory Scanning:**
- Calls `me_controller.getItemsInNetwork()` for all items
- Counts items with exact label match (e.g. "Mining Drone Mk-VII", "Steel Drill Tip").
  The drone marker is `MK-` on GTNH 2.8 and `Mk-` on 2.9; the broker sends which
  one to use with `DRILL_PAR`, since this node holds no config. See `gtVersion`.
- Groups tips and rods by material to compute kits
- Drill kit = min(tips, rods) for that material
- Only reports non-zero counts to minimize payload

**Dashboard:**
- Left column: Drone availability (14 tiers, cyan when > 0)
- Right column: Drill kit availability (9 materials, magenta when available)
- Masking: Drills only displayed if any drone is in stock
- Updates every 10 seconds

**Auto-Crafting (par restock):**
- The broker publishes `config.drillPar` as ME labels (DRILL_PAR, port 2025); this node diffs par against its own live scan and calls `me.getCraftables{label=...}` / `craftable.request(n)` for the shortfall
- Policy (what "enough" means) lives on the broker; execution lives here, because this node holds the ME controller proxy and the freshest counts
- An in-flight craft is tracked so the deficit — which stays positive until the craft lands — cannot cause a re-order every cycle
- After a craft completes, the label is held until a scan observes the stock actually move (with a 120s backstop), so a stale snapshot cannot cause a double-order
- A label with no crafting pattern is reported as `nopattern` and shown red on both dashboards, and re-probed at most once a minute
- With no DRILL_PAR received (broker down, or `config.drillPar` empty) this node orders nothing and behaves exactly as it did before

**Role in Dispatch:**
- Broker uses these counts directly to decide whether `selectDrone()` can find an available drone
- These are the source of truth — no estimation or allocation tracking by broker

---

### Fluid Telemetry Node (fluid_telem.lua)

**Purpose:** Monitors plasma tank levels and broadcasts to broker.

**Hardware:**
- Tier 2 Wireless Network Card
- GPU (dashboard display)
- Fluid Tank or Fluid Transposer (reads plasma levels)

**Network:**
- **Outbound (Port 2026):** Broadcasts FLUID_UPDATE payload every `fluidScanInterval` (10s default)
- **Inbound (Port 2027):** Receives NODE_SETTINGS from the broker

Same as the dust node: one script, no config file. It also carries the five
plasma tier names locally — a fact about the game, not a preference, and holding
it here means the dashboard and the `hasPlasma()` gate are populated the instant
the node boots. The scan loop waits in short hops rather than `os.sleep`, so a
settings push lands during the wait it arrived in rather than up to an interval
later.

**Plasma Tiers Monitored:**
1. Helium Plasma
2. Bismuth Plasma
3. Radon Plasma
4. Technetium Plasma
5. Plutonium 241 Plasma

---

### Job Nodes (job_node.lua × N)

**Purpose:** Receive mining jobs from broker, load consumables from ME network, execute mining recipes on up to 6 Mining Modules, recover output.

**Hardware per Job Node:**
- Tier 2 Wireless Network Card
- ME Interface (imports/exports items)
- Database (stores item fingerprints)
- Transposer (moves items from ME Interface to Input Bus)
- Mining Modules (1 to 6 per node, each is a multiblock recipe machine)
- Input Bus (feeds items into Mining Modules)

**Network:**
- **Inbound (Port 2027):** Receives MEDINA_COMMAND jobs from broker
- **Outbound (Port 2026):** Sends status updates every 30s (self-registration + module status)

**Job Execution Pipeline:**
1. Receive job: `{ asteroid, drone, distance, drillKey, plasmaName, modulesInUse }`
2. For each module in job:
   - Query ME for drone item by name
   - Store drone fingerprint in database slot via `me_interface.store()`
   - Query ME for drill tips and rods (by material, 4× each per parallel)
   - Store drill fingerprints in database slots
   - Load drone into module via `iface.setInterfaceConfiguration()` + `transposer.transferItem()`
   - Load drills into module via same pipeline
   - Configure module via `module_api.lua`: distance (plus parallel and cycle on GTNH 2.9), and plasma mode
   - Run recipe until complete
   - Recover output back to ME via transposer
   - Clear interface config for next job

**Constraints:**
- All modules share a single ME Interface and transposer
- Item loads must be serialized per module to avoid cross-contamination
- Plasma is a hardware concern (ME Fluid Export Bus wired directly to Input Hatch)
- Draconic Core is hard-capped at 1 parallel regardless of module tier

---

## Data Flow Summary

| Component | Purpose | Port | Frequency | Direction |
|-----------|---------|------|-----------|-----------|
| **Broker MK3** | Central controller, UI, dispatch, drives local modules | 2026 in, 2027 out, 2025 out | — | Receives telemetry; pushes watchlist / node settings / drill par |
| **Dust Telem** | Monitors dust storage levels | 2026 out, 2027 in | 10s | → Broker, ← DUST_WATCHLIST + NODE_SETTINGS |
| **HW Telem** | Scans drone/drill kit inventory, auto-crafts drill consumables to par | 2026 out, 2025 in | 10s (nominal) | → Broker, ← DRILL_PAR |
| **Fluid Telem** | Reads plasma tank levels | 2026 out, 2027 in | 10s | → Broker, ← NODE_SETTINGS |
| **Job Nodes** | Execute mining jobs on modules | 2026 in, 2027 out | Per job | ← Broker commands, → Status updates |

---

## Network Protocols

### MEDINA_TELEMETRY (Inbound to Broker, Port 2026)

All telemetry nodes send updates in this format:

```lua
{
  protocol    = "MEDINA_TELEMETRY",
  sender      = "node-id",
  payloadType = "HW_UPDATE" | "DUST_UPDATE" | "FLUID_UPDATE",
  -- Absent when the figures are fresh. A number means they are the last good
  -- ones, republished because that many consecutive ME scans have failed. The
  -- broker uses them and says so on the panel; it does not stop dispatching.
  recast      = 2,
  data        = { ... }
}
```

**Fault reports.** A node that has failed `MAX_RECASTS` (5) scans in a row stops
publishing figures and sends this instead, every cycle, in place of the normal
payload:

```lua
{
  protocol    = "MEDINA_TELEMETRY",
  sender      = "node-id",
  payloadType = "DUST_UPDATE" | "FLUID_UPDATE",
  error       = "returned nil: no channel",   -- no `data` field at all
}
```

The broker keeps the figures it already has — they are stale, but they are the
last ones that were true — and **holds dispatch** until the node reports cleanly
again, naming the node and the reason on the hardware panel. Sending every cycle
rather than falling silent is deliberate: it is what distinguishes "node alive,
ME broken" from "node gone", which staleness alone cannot.


**HW_UPDATE** data:
```lua
{
  drones = { ["lv"]=2, ["mv"]=5, ... },
  -- A "kit" is min(tips, rods) of one material. All three counts are sent so the
  -- broker can tell "no tips" apart from "no rods".
  drills = { ["steel"] = { kits=10, tips=10, rods=64 }, ... },
  -- Present only while restock orders are outstanding; absent at par.
  crafting = { ["Steel Drill Tip"] = { want=156, state="crafting" }, ... }
}
```
`crafting` states: `"crafting"` (request accepted, in flight), `"queued"` (below
par, waiting on a free craft slot — not a problem), `"nopattern"` (no crafting
pattern in the network — needs a human), `"failed"` (request rejected by AE2).
The broker replaces its copy wholesale on every HW_UPDATE, so a resolved entry
clears itself.

**DUST_UPDATE** data — stock only, keyed by ME label. The threshold is policy
and stays on the broker (see DUST_WATCHLIST); a node echoing one back used to be
able to overwrite live policy with a stale copy.
```lua
{
  ["Uranium-238 Dust"]   = { stock = 50000 },
  ["Plutonium-239 Dust"] = { stock = 12000 },
  ...
}
```

**FLUID_UPDATE** data — note the `plasmas` wrapper; the volumes are not at the
top level.
```lua
{
  plasmas = {
    ["Plutonium 241 Plasma"] = 500000,
    ["Technetium Plasma"]    = 250000,
    ...
  }
}
```
Plasma labels are spelled as `config.plasmaKeyOrder` spells them — `Plutonium
241 Plasma`, with a space and no hyphen, which is what the game uses. The broker
matches on the exact string, so a hyphen here means the reading is silently
dropped.

### MEDINA_JOB (Job Node → Broker Status, Port 2026)

Job nodes send status updates:

```lua
{
  protocol    = "MEDINA_JOB",
  sender      = "node-id",
  nodeId      = "unique-node-name",
  modules     = { 
    { index=1, tier="MK-II", status="IDLE", job=nil },
    { index=2, tier="MK-II", status="RUNNING", job={...} },
    ...
  },
  lastSeen    = os.time()
}
```

### MEDINA_COMMAND / NODE_SETTINGS (Broker → Dust and Fluid Nodes, Port 2027)

Broadcasts the `scope = "node"` subset of the settings registry, on the same
timer as the dust watchlist and again immediately after an edit is saved:

```lua
{
  protocol    = "MEDINA_COMMAND",
  sender      = "broker-id",
  payloadType = "NODE_SETTINGS",
  data        = {
    dustScanInterval  = 10,
    fluidScanInterval = 10,
    wirelessStrength  = 400,
    nodeDashboard     = true,
    drillCraftSlots   = 2,
  }
}
```

**Notes:**
- This is what lets the dust and fluid nodes ship without `config.lua`
- Nodes cache what they receive to `/home/node_settings.lua`, so one that
  restarts during a broker outage comes back configured rather than reverting
- A node accepts only the keys it knows, and only with the right type; an
  empty or malformed push is ignored rather than resetting a working node
- The hw node is not an audience: it stays off this port (see the note on
  DRILL_PAR below), and the one setting it cares about rides along with its own

### MEDINA_COMMAND (Broker → HW Telem Node, Port 2025)

Broker broadcasts drill consumable par levels, every 30s on the same timer as the
dust watchlist:

```lua
{
  protocol    = "MEDINA_COMMAND",
  sender      = "broker-id",
  payloadType = "DRILL_PAR",
  data        = {
    par   = {
      ["Steel Drill Tip"] = { min = 4096, batch = 4096 },  -- min = stock floor
      ["Steel Rod"]       = { min = 4096, batch = 4096 },  -- batch = request size
      ...
    },
    slots   = 2,     -- max concurrent crafts (config.drillCraftSlots)
    enabled = true,  -- config.drillRestock; false = order nothing at all
  }
}
```

**Notes:**
- Built from `config.drillPar`, resolved to ME labels through `config.drills` — the hw node does not load `config.lua` and cannot map a drill key to a label itself
- **Filtered to materials this base can consume:** only drill keys reachable via `droneDrillMap` from a drone currently in stock, unioned with the drill keys of any non-idle module. The union matters — a drone loaded into a running module is not in the ME network and reports zero, and dropping its material from par mid-run would stop restocking the one material actively being spent
- `slots` carries `config.drillCraftSlots` because the node cannot read config. AE2 cancels a request outright when no CPU is free, so the node keeps at most this many crafts in flight and reports the rest as `queued` rather than firing requests it knows will be rejected
- Sent on its own port rather than 2027 because the hw node is the most memory-constrained machine in the fleet, and sharing a port would make it unserialize every DUST_WATCHLIST broadcast just to discard it. Port 2025 was already open on that node for a query protocol that never got a client
- The node **replaces** its par table on receipt, so removing a material from `config.drillPar` actually stops it being ordered
- An empty `data` table is valid and means "order nothing"
- `enabled = false` (from `config.drillRestock`) also sends an empty par table,
  but says WHY it is empty. The node distinguishes the two on its dashboard:
  switched off reads as `Auto-craft off (broker).`, whereas an empty par with
  `enabled = true` means nothing is currently restockable — no drone in stock
  for any material, say. Crafts already in flight are still retired normally
  when this goes false; only new orders stop, and the par figures are kept

### MEDINA_COMMAND (Broker → Job Nodes, Port 2027)

Broker broadcasts mining jobs:

```lua
{
  protocol = "MEDINA_COMMAND",
  target = "node-id",
  payloadType = "JOB_ASSIGN",
  data = {
    jobId = "unique-job-id",
    moduleIndex = 1,
    asteroid = "Uranium-Plutonium",
    droneKey = "uiv",
    drillKey = "tungstensteel",
    droneLocked = false,
    distance = 51,
    parallels = 8
  }
}
```

**Notes:**
- `target` specifies the node that should execute this job
- `droneLocked` is always false in current implementation (locking logic removed for simplicity)
- `parallels` is the max parallel count for the assigned module tier
- Distance is looked up from `config.optimizationMatrix` and clamped to 200

---

## Configuration

Nothing here needs to be edited by hand. Press `E` on the broker: the asteroid
pages choose what to mine, `d` the drill consumables, and `g` every other
tunable in the system. Saving applies live and writes `/home/user_config.lua`,
which updates never overwrite.

Runtime tunables are declared in `settings.lua` and documented in `SETTINGS.md`.
Shipped mining data lives in `config.lua`:

- **Asteroids:** Material compositions, size ranges, valid distance and drone tier ranges, computation and power requirements
- **Drones:** 14 tiers from MK-I (LV) to MK-XIV (MAX)
- **Drills:** 9 material tiers (Steel through Transcendent Metal)
- **Drill par:** `config.drillPar` — per-material stock levels the hw node auto-crafts back up to. `tips`/`rods` are the stock **floor** that triggers a craft, `batch` is the **request size**, always sent whole. See SETTINGS.md for the full reasoning and the shipped table
- **Plasmas:** 5 tiers with consumption rates, time discounts, and size bonuses
- **Optimization Matrix:** Pre-computed optimal distances per [module tier][asteroid][drone tier]
- **Dust Targets:** Mapping of dust items to source asteroids and mining priorities
- **Conditions:** Dust threshold levels that trigger mining jobs

---

## Scaling Considerations

- **Job Nodes:** Add more job node instances to mine asteroids in parallel. Each node can control up to 6 modules but shares ME/transposer hardware, so throughput scales with the transposer speed and item loading latency.
- **Telemetry Nodes:** Multiple instances of dust_telem, hw_telem, or fluid_telem can exist for redundancy. Broker aggregates the latest update from each sender.
- **Wireless Range:** All nodes must be within 400 blocks (configurable via `modem.setStrength()`). Extend range or add relay nodes if needed.
- **ME Network:** All job nodes must have access to the same ME Controller for drone and drill sourcing. Plasma is hardware-direct (no network required).

---

## Future Roadmap

**MEDINA v2.0** (planned post-v1.0):
- MQTT fork: Replace wireless modem with MQTT broker for cloud-scale automation
- Internet Cards: Replace wireless modems with Internet Cards for better reliability
- Mosquitto broker on homelab server

