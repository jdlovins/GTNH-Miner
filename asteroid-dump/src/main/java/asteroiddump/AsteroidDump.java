package asteroiddump;

import cpw.mods.fml.common.Mod;
import cpw.mods.fml.common.event.FMLServerStartingEvent;
import net.minecraft.command.CommandBase;
import net.minecraft.command.ICommandSender;
import net.minecraft.item.Item;
import net.minecraft.item.ItemStack;
import net.minecraft.util.ChatComponentText;

import gregtech.api.enums.Materials;
import gregtech.api.enums.OrePrefixes;
import gregtech.api.recipe.RecipeMap;
import gregtech.api.recipe.RecipeMaps;
import gregtech.api.util.GTOreDictUnificator;
import gregtech.api.util.GTRecipe;

import gtnhintergalactic.recipe.AsteroidData;
import gtnhintergalactic.recipe.SpaceMiningRecipes;

import java.io.File;
import java.io.IOException;
import java.io.OutputStreamWriter;
import java.io.Writer;
import java.io.FileOutputStream;
import java.nio.charset.StandardCharsets;
import java.util.*;

/**
 * Dumps, for every Space Elevator asteroid, what it drops and what that breaks
 * down into.
 *
 * WHY THIS EXISTS
 *   The broker's config maps a dust to the asteroid that yields it. That mapping
 *   cannot be derived outside the game. Asteroid data and GT material names can
 *   be read out of the jar, but item LABELS are composed at runtime, bridge
 *   materials from BartWorks/GoodGenerator never appear statically at all, and
 *   the ore-processing graph lives in recipe registrations built during load.
 *   In here all of that is just a method call on a live registry.
 *
 * WHAT IT DOES
 *   1. Walks SpaceMiningRecipes.uniqueAsteroidList for the drops. Asteroids
 *      declared with Materials+OrePrefixes are resolved through
 *      GTOreDictUnificator; the handful declared with explicit ItemStacks are
 *      read directly, which is what makes Clay / Everglades / Draconic Core /
 *      Mysterious Crystal resolvable here and nowhere else.
 *   2. Indexes the ore-processing recipe maps by input item.
 *   3. Breadth-first walks each drop up to MAX_DEPTH hops, recording every
 *      product with the machine and hop count that produced it.
 *   4. Writes JSON next to the world folder.
 *
 * The traversal is deliberately limited to processing maps. The full recipe
 * graph is near fully connected -- follow alloying and the chemical reactor and
 * every asteroid "yields" most of the game.
 *
 * USAGE:  /asteroiddump          walk to the default depth
 *         /asteroiddump 2        override the depth
 */
@Mod(modid = AsteroidDump.MODID, name = "Asteroid Dump", version = "1.0",
     dependencies = "required-after:gregtech", acceptableRemoteVersions = "*")
public class AsteroidDump {

    public static final String MODID = "asteroiddump";

    /** Hops away from the raw drop. 3 reaches the dust-separation lines. */
    private static final int MAX_DEPTH = 3;

    /** Guard against a pathological expansion producing an unusable file. */
    private static final int MAX_PRODUCTS_PER_ASTEROID = 400;

    @Mod.EventHandler
    public void onServerStarting(FMLServerStartingEvent event) {
        event.registerServerCommand(new DumpCommand());
    }

    // -----------------------------------------------------------------------
    // Item identity
    // -----------------------------------------------------------------------

    /** Registry-name + damage. Stable, and readable in the output. */
    private static String keyOf(ItemStack stack) {
        if (stack == null || stack.getItem() == null) return null;
        Object name = Item.itemRegistry.getNameForObject(stack.getItem());
        return name + ":" + stack.getItemDamage();
    }

    /** Wildcard form, because GT recipe inputs frequently use damage 32767. */
    private static String wildKeyOf(ItemStack stack) {
        if (stack == null || stack.getItem() == null) return null;
        return Item.itemRegistry.getNameForObject(stack.getItem()) + ":*";
    }

    private static String labelOf(ItemStack stack) {
        if (stack == null) return "?";
        try {
            return stack.getDisplayName();
        } catch (Throwable t) {
            // A few modded items throw when named outside a render context.
            return String.valueOf(Item.itemRegistry.getNameForObject(stack.getItem()));
        }
    }

    // -----------------------------------------------------------------------
    // Recipe index
    // -----------------------------------------------------------------------

    private static final class Step {
        final String machine;
        final GTRecipe recipe;
        Step(String machine, GTRecipe recipe) { this.machine = machine; this.recipe = recipe; }
    }

    /** Processing maps only, in roughly the order ore actually flows. */
    private static Map<String, RecipeMap<?>> processingMaps() {
        Map<String, RecipeMap<?>> maps = new LinkedHashMap<String, RecipeMap<?>>();
        maps.put("macerator", RecipeMaps.maceratorRecipes);
        maps.put("ore_washer", RecipeMaps.oreWasherRecipes);
        maps.put("thermal_centrifuge", RecipeMaps.thermalCentrifugeRecipes);
        maps.put("sifter", RecipeMaps.sifterRecipes);
        maps.put("chemical_bath", RecipeMaps.chemicalBathRecipes);
        maps.put("electromagnetic_separator", RecipeMaps.electroMagneticSeparatorRecipes);
        maps.put("simple_washer", RecipeMaps.simpleWasherRecipes);
        // Dust separation. These are what resolve the rare-earth and
        // Naquadah Earth chains that no static source explains.
        maps.put("centrifuge", RecipeMaps.centrifugeRecipes);
        maps.put("electrolyzer", RecipeMaps.electrolyzerRecipes);
        return maps;
    }

    private static Map<String, List<Step>> buildIndex(Map<String, RecipeMap<?>> maps) {
        Map<String, List<Step>> byInput = new HashMap<String, List<Step>>();
        for (Map.Entry<String, RecipeMap<?>> e : maps.entrySet()) {
            Collection<GTRecipe> recipes;
            try {
                recipes = e.getValue().getAllRecipes();
            } catch (Throwable t) {
                continue;
            }
            for (GTRecipe r : recipes) {
                if (r == null || r.mInputs == null) continue;
                for (ItemStack in : r.mInputs) {
                    String k = keyOf(in);
                    if (k == null) continue;
                    // Index under both the exact damage and a wildcard, because GT
                    // recipe inputs routinely use damage 32767 to mean "any".
                    add(byInput, k, new Step(e.getKey(), r));
                    add(byInput, wildKeyOf(in), new Step(e.getKey(), r));
                }
            }
        }
        return byInput;
    }

    private static void add(Map<String, List<Step>> m, String k, Step s) {
        if (k == null) return;
        List<Step> l = m.get(k);
        if (l == null) { l = new ArrayList<Step>(); m.put(k, l); }
        l.add(s);
    }

    // -----------------------------------------------------------------------
    // Asteroid drops
    // -----------------------------------------------------------------------

    private static final class Drop {
        final ItemStack stack;
        final int chance;
        Drop(ItemStack stack, int chance) { this.stack = stack; this.chance = chance; }
    }

    private static List<Drop> dropsOf(AsteroidData a) {
        List<Drop> drops = new ArrayList<Drop>();
        if (a.outputItems != null) {
            for (int i = 0; i < a.outputItems.length; i++) {
                ItemStack s = a.outputItems[i];
                if (s != null) drops.add(new Drop(s, chanceAt(a, i)));
            }
            return drops;
        }
        if (a.output == null || a.orePrefixes == null) return drops;
        for (int i = 0; i < a.output.length; i++) {
            Materials m = a.output[i];
            if (m == null) continue;
            ItemStack s = null;
            try {
                s = GTOreDictUnificator.get(a.orePrefixes, m, 1L);
            } catch (Throwable ignored) { }
            if (s != null) drops.add(new Drop(s, chanceAt(a, i)));
        }
        return drops;
    }

    private static int chanceAt(AsteroidData a, int i) {
        return (a.chances != null && i < a.chances.length) ? a.chances[i] : 0;
    }

    // -----------------------------------------------------------------------
    // Traversal
    // -----------------------------------------------------------------------

    private static final class Found {
        final String label;
        final int depth;
        final String via;
        Found(String label, int depth, String via) {
            this.label = label; this.depth = depth; this.via = via;
        }
    }

    private static Map<String, Found> walk(ItemStack seed, Map<String, List<Step>> index, int maxDepth) {
        Map<String, Found> found = new LinkedHashMap<String, Found>();
        Set<String> visited = new HashSet<String>();

        List<ItemStack> frontier = new ArrayList<ItemStack>();
        frontier.add(seed);
        String sk = keyOf(seed);
        if (sk != null) visited.add(sk);

        for (int depth = 1; depth <= maxDepth && !frontier.isEmpty(); depth++) {
            List<ItemStack> next = new ArrayList<ItemStack>();
            for (ItemStack cur : frontier) {
                List<Step> steps = stepsFor(cur, index);
                if (steps == null) continue;
                for (Step st : steps) {
                    if (st.recipe.mOutputs == null) continue;
                    for (ItemStack out : st.recipe.mOutputs) {
                        String k = keyOf(out);
                        if (k == null || visited.contains(k)) continue;
                        visited.add(k);
                        if (found.size() >= MAX_PRODUCTS_PER_ASTEROID) return found;
                        found.put(k, new Found(labelOf(out), depth, st.machine));
                        next.add(out);
                    }
                }
            }
            frontier = next;
        }
        return found;
    }

    private static List<Step> stepsFor(ItemStack stack, Map<String, List<Step>> index) {
        List<Step> exact = index.get(keyOf(stack));
        List<Step> wild = index.get(wildKeyOf(stack));
        if (exact == null) return wild;
        if (wild == null) return exact;
        List<Step> both = new ArrayList<Step>(exact);
        both.addAll(wild);
        return both;
    }

    // -----------------------------------------------------------------------
    // Output
    // -----------------------------------------------------------------------

    private static String esc(String s) {
        if (s == null) return "";
        StringBuilder b = new StringBuilder();
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            switch (c) {
                case '"':  b.append("\\\""); break;
                case '\\': b.append("\\\\"); break;
                case '\n': b.append("\\n");  break;
                case '\r': b.append("\\r");  break;
                case '\t': b.append("\\t");  break;
                default:
                    if (c < 0x20) b.append(String.format("\\u%04x", (int) c));
                    else b.append(c);
            }
        }
        return b.toString();
    }

    private static class DumpCommand extends CommandBase {
        public String getCommandName() { return "asteroiddump"; }
        public String getCommandUsage(ICommandSender s) { return "/asteroiddump [depth]"; }
        public int getRequiredPermissionLevel() { return 2; }

        public void processCommand(ICommandSender sender, String[] args) {
            int depth = MAX_DEPTH;
            if (args.length > 0) {
                try { depth = Math.max(1, Math.min(6, Integer.parseInt(args[0]))); }
                catch (NumberFormatException ignored) { }
            }

            reply(sender, "indexing recipe maps...");
            Map<String, RecipeMap<?>> maps = processingMaps();
            Map<String, List<Step>> index = buildIndex(maps);
            reply(sender, "indexed " + index.size() + " distinct recipe inputs across "
                    + maps.size() + " maps");

            List<AsteroidData> asteroids = SpaceMiningRecipes.uniqueAsteroidList;
            if (asteroids == null || asteroids.isEmpty()) {
                reply(sender, "uniqueAsteroidList is empty -- is GT Intergalactic loaded?");
                return;
            }

            File out = new File("asteroid_dump.json");
            Writer w = null;
            int totalProducts = 0;
            try {
                w = new OutputStreamWriter(new FileOutputStream(out), StandardCharsets.UTF_8);
                w.write("{\n");
                w.write("  \"depth\": " + depth + ",\n");
                w.write("  \"asteroids\": [\n");

                for (int ai = 0; ai < asteroids.size(); ai++) {
                    AsteroidData a = asteroids.get(ai);
                    w.write("    {\n");
                    w.write("      \"name\": \"" + esc(a.asteroidName) + "\",\n");
                    w.write("      \"moduleTier\": " + a.requiredModuleTier + ",\n");
                    w.write("      \"droneTier\": [" + a.minDroneTier + ", " + a.maxDroneTier + "],\n");
                    w.write("      \"distance\": [" + a.minDistance + ", " + a.maxDistance + "],\n");
                    w.write("      \"weight\": " + a.recipeWeight + ",\n");
                    w.write("      \"drops\": [\n");

                    List<Drop> drops = dropsOf(a);
                    for (int di = 0; di < drops.size(); di++) {
                        Drop d = drops.get(di);
                        w.write("        {\n");
                        w.write("          \"item\": \"" + esc(labelOf(d.stack)) + "\",\n");
                        w.write("          \"id\": \"" + esc(keyOf(d.stack)) + "\",\n");
                        w.write("          \"chance\": " + d.chance + ",\n");
                        w.write("          \"breaksDownInto\": [\n");

                        Map<String, Found> found = walk(d.stack, index, depth);
                        totalProducts += found.size();
                        int fi = 0;
                        for (Map.Entry<String, Found> e : found.entrySet()) {
                            Found f = e.getValue();
                            w.write("            { \"item\": \"" + esc(f.label)
                                    + "\", \"id\": \"" + esc(e.getKey())
                                    + "\", \"hops\": " + f.depth
                                    + ", \"via\": \"" + esc(f.via) + "\" }");
                            w.write(++fi < found.size() ? ",\n" : "\n");
                        }
                        w.write("          ]\n");
                        w.write(di + 1 < drops.size() ? "        },\n" : "        }\n");
                    }
                    w.write("      ]\n");
                    w.write(ai + 1 < asteroids.size() ? "    },\n" : "    }\n");
                }
                w.write("  ]\n}\n");
            } catch (IOException e) {
                reply(sender, "write failed: " + e.getMessage());
                return;
            } finally {
                if (w != null) try { w.close(); } catch (IOException ignored) { }
            }

            reply(sender, "wrote " + out.getAbsolutePath());
            reply(sender, asteroids.size() + " asteroids, " + totalProducts
                    + " breakdown products at depth " + depth);
        }

        private void reply(ICommandSender s, String msg) {
            s.addChatMessage(new ChatComponentText("[asteroiddump] " + msg));
        }
    }
}
