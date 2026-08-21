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

## Use

Drop the jar in `mods/` and start the server, or load any world in singleplayer.
It runs once on server start and writes `asteroid_dump.json` to the game
directory. Read-only: it registers no recipes and changes no world state. Remove
the jar afterwards.

Depth defaults to 3 hops. Override with `-Dasteroiddump.depth=2`.

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
