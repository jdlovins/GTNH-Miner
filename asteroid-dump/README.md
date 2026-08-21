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

Drop the jar in `mods/`, start the server, then:

    /asteroiddump        walk 3 hops (default)
    /asteroiddump 1      raw drops only
    /asteroiddump 2      through ore processing

Writes `asteroid_dump.json` to the server working directory. Read-only: it
registers no recipes, changes no world state, and can be removed afterwards.

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
