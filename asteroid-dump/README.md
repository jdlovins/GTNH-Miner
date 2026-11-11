# asteroiddump

A one-shot diagnostic mod for GTNH. Adds `/asteroiddump`, which writes
`asteroid_dump.json` listing every Space Elevator asteroid, what it drops, and
what those drops break down into.

## Why

The broker maps a dust to the asteroid that yields it. That mapping cannot be
derived outside the game:

- asteroid tables and GT material names **can** be read from the jar
- item **labels** are composed at runtime from prefix + material
- BartWorks / GoodGenerator bridge materials never appear statically at all
- the ore-processing graph lives in recipe registrations built during load

In-game all of it is a method call on a live registry. `getDisplayName()`
replaces every label-derivation rule; the recipe maps replace the guesswork
about what an ore becomes.

## What 1.4 adds

1.3 said *which* items an asteroid leads to, but not *how many*, and not which
of several asteroids is the better source. 1.4 records the inputs to that
arithmetic, straight from the game:

- `spaceMining`: every recipe in the space mining map. That is one per asteroid
  **per drone tier**, with the size, duration, EU/t and computation the game
  registered for that drone, plus its distance range, weight, module tier, and
  the drone, drill and rod it consumes.
- On every breakdown product: the input and output amounts, the output chance,
  any fluids the step needs, the step's EU/t and duration, the item it was made
  from, and `yield`, the expected count from **one** dropped item along that
  path.
- `miner`: the mining module's own constants (bonus stack cap, plasma usage),
  the formulas they feed (transcribed from its bytecode), and the drone, drill
  and rod for each tier.
- On each asteroid: `label` (the name the game shows), `size`, `computation`,
  `duration`.

All 1.3 fields are kept with the same names, so anything that read a 1.3 dump
still works.

## Use

Drop the jar in `mods/` and start the server, or load any world in singleplayer.
It runs once on server start and writes `asteroid_dump.json` to the game
directory. Read-only: it registers no recipes and changes no world state. Remove
the jar afterwards.

Depth defaults to 3 hops. Override with `-Dasteroiddump.depth=2`.

Copy the file over `asteroid-dump/asteroid_dump.json` in this repo, then run the
merge.

## Merging with the Space Elevator Calculator

`merge.py` combines the dump with the community calculator spreadsheet. It needs
Python 3 and nothing else:

    python merge.py --calc "GTNH Space Elevator Calculator.xlsx"

Options: `--plasma 1..5` and `--overdrive` set the assumptions used for rates,
`--out` sets the output folder (default `out/`), and `--apply` also writes the
generated blocks into `space-miner/config.lua`, leaving the rest of the file
alone. It writes:

- `out/perfected.json`: every asteroid with each field tagged by where it came
  from; the recipe the module really runs for each drone tier; the best
  distance per module tier and drone, by pick chance and by draws per hour; and
  for each item, which asteroid and setting gives the most of it.
- `out/report.md`: every disagreement between the game, the calculator and
  `config.lua`.
- `out/generated.lua`: `config.asteroids`, `config.optimizationMatrix` and
  `config.itemSources` in `config.lua`'s format, ready to paste over those
  blocks.

`config.itemSources` lists, for every item an asteroid leads to, the asteroids
that are the best source for at least one drone tier, best first. It is the
fallback for `config.dustTargets`: an item with no entry there is mined from the
first source in this list that the broker can reach when the job goes out, so
the choice follows the drones you own. A `dustTargets` entry always wins.

When the two sources disagree, the game wins. The calculator is a hand-made
copy of the same recipes and is missing two of the game's scalings: per drone
tier the game divides duration by sqrt(k) and multiplies EU/t by sqrt(k), and
the calculator applies only the size bonus. With a 1.3 dump the calculator
supplies size, computation, duration and EU/t, and the per-drone values are
derived; with a 1.4 dump they come from the game and the calculator is only a
cross-check.

The model was checked against the calculator: from the same inputs, merge.py
reproduces every entry in the calculator's three "module best" sheets.

There is deliberately no command. See below.

## The obfuscation trap

Forge 1.7.10 remaps `net.minecraft` MEMBERS to SRG names at runtime -- class
names survive, method and field names do not. A dev-environment build handles
this by reobfuscating MCP -> SRG on the way out. This mod is compiled by hand
against the pack's jars with no such step, so any direct call to a
`net.minecraft` method resolves to a name that does not exist at runtime.

v1.0 implemented `ICommand` and crashed the server at registration:

    AbstractMethodError: ... does not define or inherit ... func_71517_b()

which is `getCommandName()`. Compiling cleanly proved nothing, because the
compiler was looking at MCP names that the runtime does not have.

v1.1 therefore touches no `net.minecraft` member at all:

- runs off `FMLServerStartedEvent` instead of a command (FML is never remapped)
- identifies items via `GameRegistry.findUniqueIdentifierFor`, also FML
- reaches the three `ItemStack` methods it needs by reflection, SRG name first
  and MCP name second, so it works in either environment
- calls GregTech / BartWorks / Intergalactic directly, as mod classes are not
  remapped

The SRG names were read out of GregTech's own bytecode, not recalled:

    func_82833_r()Ljava/lang/String;           getDisplayName
    func_77960_j()I                            getItemDamage
    func_77973_b()Lnet/minecraft/item/Item;    getItem

Verify a build is safe with:

    javap -p -c build/classes/asteroiddump/*.class | grep -E "(Method|Field) net/minecraft/"

That must print nothing. `net/minecraft` may appear as a TYPE; it must never
appear as a member reference.

## Traversal

Deliberately limited to processing maps -- macerator, ore washer, thermal
centrifuge, sifter, chemical bath, electromagnetic separator, simple washer,
plus centrifuge and electrolyzer for dust separation.

The full recipe graph is near fully connected. Follow alloying and the chemical
reactor and every asteroid "yields" most of the game, which is useless. Depth is
capped and each asteroid stops at 400 products.

## Building

No Forge dev environment needed. `./build.sh` compiles against jars already on
the machine.

The one non-obvious requirement: **Minecraft must be the deobfuscated,
MCP-named build**, taken from a previous RetroFuturaGradle build
(`GT5-Unofficial/build/rfg/recompiled_minecraft-1.7.10.jar`). The
`minecraft_server.1.7.10.jar` shipped with the pack is obfuscated and will fail
with "package net.minecraft.item does not exist" -- GregTech is compiled against
MCP names.
