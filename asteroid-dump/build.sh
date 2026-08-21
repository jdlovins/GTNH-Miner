#!/usr/bin/env bash
# Build asteroiddump without a Forge dev environment.
#
# The trick is compiling against jars that are already on this machine:
#   - recompiled_minecraft-1.7.10.jar   deobfuscated, MCP-named Minecraft, left
#     behind by a previous RetroFuturaGradle build of GT5-Unofficial. The
#     shipped minecraft_server jar is obfuscated and will NOT work -- GT is
#     compiled against MCP names.
#   - forge universal   for cpw.mods.fml
#   - the pack's gregtech jar   for GT + GT Intergalactic
#
# Adjust these three if the paths move.
set -e

MC="C:/Users/josh/Desktop/mm/GT5-Unofficial/build/rfg/recompiled_minecraft-1.7.10.jar"
PACK="C:/Users/josh/webae2/GTNH-daily-2026-08-01+656-server-java17-26"
FORGE="$PACK/forge-1.7.10-10.13.4.1614-1.7.10-universal.jar"
GT="$PACK/mods/gregtech-5.09.54.67.jar"

for f in "$MC" "$FORGE" "$GT"; do
  [ -f "$f" ] || { echo "missing: $f"; exit 1; }
done

rm -rf build/classes
mkdir -p build/classes
javac --release 8 -nowarn -cp "$MC;$FORGE;$GT" -d build/classes \
      src/main/java/asteroiddump/AsteroidDump.java
cp src/main/resources/mcmod.info build/classes/
jar cf build/asteroiddump-1.3.jar -C build/classes .
echo "built build/asteroiddump-1.3.jar"
