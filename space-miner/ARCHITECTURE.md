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
        │  every 120s     │ │ every 10s   │ │  every 10s     │
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
- `scheduler.lua` — cooperative task engine (spawn / sleep / await / lock; one clock via `computer.uptime`)
- `loader.lua` — per-module load sequence, run as a task; read-back confirmation + identity-based item routing
- `logger.lua` — configurable logging (file / console / Loki); disabled by default, ERROR/WARN to `/tmp/spacemining.log`

**Network:**
- **Inbound (Port 2026):** telemetry from dust_telem / hw_telem / fluid_telem
- **Port 2027:** reserved for optional remote job nodes (unused in the single-broker setup)

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
- Stop the broker with **Ctrl+Alt+C** in the OC console.

---

### Dust Telemetry Node (dust_telem.lua)

**Purpose:** Scans dust storage subnet and broadcasts inventory levels to the broker.

**Hardware:**
- Tier 2 Wireless Network Card
- GPU (small display)
- ME Controller or ME Interface (read-only access to dust storage)

**Network:**
- **Outbound (Port 2026):** Broadcasts DUST_UPDATE payload every 120 seconds
- Payload: dust item names and current stock counts

**Monitored Items:**
- All 80+ dust types tracked in `config.conditions`
- Only items below threshold trigger mining jobs

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
- Counts items with exact label match (e.g., "Mining Drone MK-VII", "Steel Drill Tip")
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
- **Outbound (Port 2026):** Broadcasts FLUID_UPDATE payload every 10 seconds
- Payload: plasma tank levels (mB) for all 5 plasma tiers

**Plasma Tiers Monitored:**
1. Helium Plasma
2. Bismuth Plasma
3. Radon Plasma
4. Technetium Plasma
5. Plutonium-241 Plasma

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
   - Configure module: `setParameters(0, 0, distance)` and plasma mode
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
| **Broker MK3** | Central controller, UI, dispatch, drives local modules | 2026 in (2027 out only for optional remote nodes) | — | Receives telemetry; loads/runs its own modules |
| **Dust Telem** | Monitors dust storage levels | 2026 in | 120s | → Broker |
| **HW Telem** | Scans drone/drill kit inventory, auto-crafts drill consumables to par | 2026 out, 2025 in | 10s (nominal) | → Broker, ← DRILL_PAR |
| **Fluid Telem** | Reads plasma tank levels | 2026 in | 10s | → Broker |
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
  data        = { ... }
}
```

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

**DUST_UPDATE** data:
```lua
{
  ["Uranium-238 Dust"] = 50000,
  ["Plutonium-239 Dust"] = 12000,
  ...
}
```

**FLUID_UPDATE** data:
```lua
{
  ["Plutonium-241 Plasma"] = 500000,
  ["Technetium Plasma"] = 250000,
  ...
}
```

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

### MEDINA_COMMAND (Broker → HW Telem Node, Port 2025)

Broker broadcasts drill consumable par levels, every 30s on the same timer as the
dust watchlist:

```lua
{
  protocol    = "MEDINA_COMMAND",
  sender      = "broker-id",
  payloadType = "DRILL_PAR",
  data        = {
    par   = { ["Steel Drill Tip"] = 256, ["Steel Rod"] = 256, ... },
    slots = 2   -- max concurrent crafts (config.drillCraftSlots)
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

All mining parameters are defined in `config.lua`:

- **Asteroids:** Material compositions, size ranges, valid distance and drone tier ranges, computation and power requirements
- **Drones:** 14 tiers from MK-I (LV) to MK-XIV (MAX)
- **Drills:** 9 material tiers (Steel through Transcendent Metal)
- **Drill par:** `config.drillPar` — per-material stock levels the hw node auto-crafts back up to. Scaled to material cost rather than flat: 4096 (64 loads) for Steel, tapering to 256 (4 loads) for the top three tiers. All nine are listed because all nine are dispatchable: the gate in `tryDispatch()` is `config.drills`, not `config.drillRegistry` (which nothing reads). A material left out of `drillPar` still dispatches and still burns kits — it just never restocks. Note the top three tiers are expensive to craft unattended; lower those pars or set them `false` in `user_config.lua` if you would rather approve those by hand
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

