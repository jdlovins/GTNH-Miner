package asteroiddump;

import cpw.mods.fml.common.FMLLog;
import cpw.mods.fml.common.Mod;
import cpw.mods.fml.common.event.FMLServerStartedEvent;
import cpw.mods.fml.common.registry.GameData;
import cpw.mods.fml.common.registry.GameRegistry;

import net.minecraft.item.Item;
import net.minecraft.item.ItemStack;

import gregtech.api.enums.Materials;
import gregtech.api.recipe.RecipeMap;
import gregtech.api.recipe.RecipeMaps;
import gregtech.api.util.GTOreDictUnificator;
import gregtech.api.util.GTRecipe;

import gtnhintergalactic.recipe.AsteroidData;
import gtnhintergalactic.recipe.SpaceMiningRecipes;

import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.OutputStreamWriter;
import java.io.Writer;
import java.lang.reflect.Method;
import java.nio.charset.StandardCharsets;
import java.util.*;

/**
 * Dumps, for every Space Elevator asteroid, what it drops and what those drops
 * break down into. Writes asteroid_dump.json to the game directory on server
 * start, then does nothing else.
 *
 * WHY THIS EXISTS
 *   The broker config maps a dust to the asteroid that yields it, and that
 *   mapping cannot be derived outside the game. Asteroid tables and GT material
 *   names can be read from the jar, but item LABELS are composed at runtime,
 *   BartWorks/GoodGenerator bridge materials never appear statically at all, and
 *   the ore-processing graph lives in recipe registrations built during load.
 *   In here it is all a call on a live registry.
 *
 * WHY IT LOOKS LIKE THIS (the obfuscation trap)
 *   Forge 1.7.10 remaps net.minecraft MEMBERS to SRG names at runtime -- class
 *   names survive, method and field names do not. A dev-environment build fixes
 *   that by reobfuscating MCP -> SRG on the way out. This mod is compiled by
 *   hand against the pack's own jars with no such step, so any direct call to a
 *   net.minecraft method would resolve to a name that does not exist at runtime.
 *   The first version implemented ICommand and died at registration with
 *   "does not define ... func_71517_b()", which is getCommandName().
 *
 *   So: no ICommand, no net.minecraft calls. It runs off an FML event (FML
 *   classes are never remapped), identifies items through GameRegistry (also
 *   FML), and reaches the three ItemStack methods it needs by reflection, trying
 *   the SRG name first and the MCP name second so it works either way. The SRG
 *   names were read out of GregTech's own bytecode rather than recalled.
 *
 *   GregTech, BartWorks and Intergalactic classes are mod classes and are not
 *   remapped, so those are called directly.
 *
 * DEPTH
 *   Defaults to 3 hops, override with -Dasteroiddump.depth=N. Traversal is
 *   limited to ore-processing maps plus centrifuge and electrolyzer. The full
 *   recipe graph is near fully connected -- follow alloying and the chemical
 *   reactor and every asteroid "yields" most of the game.
 */
@Mod(modid = AsteroidDump.MODID, name = "Asteroid Dump", version = "1.2",
     dependencies = "required-after:gregtech", acceptableRemoteVersions = "*")
public class AsteroidDump {

    public static final String MODID = "asteroiddump";

    private static final int DEFAULT_DEPTH = 3;
    private static final int MAX_PRODUCTS_PER_DROP = 400;

    // ---------------------------------------------------------------------
    // Reflection into net.minecraft. SRG first, MCP second.
    // Names verified against GregTech's compiled bytecode:
    //   func_82833_r()Ljava/lang/String;              getDisplayName
    //   func_77960_j()I                               getItemDamage
    //   func_77973_b()Lnet/minecraft/item/Item;       getItem
    // ---------------------------------------------------------------------

    private static Method find(Class<?> owner, String... names) {
        for (String n : names) {
            try {
                Method m = owner.getMethod(n);
                m.setAccessible(true);
                return m;
            } catch (Throwable ignored) { }
        }
        return null;
    }

    private static final Method M_DISPLAY = find(ItemStack.class, "func_82833_r", "getDisplayName");
    private static final Method M_DAMAGE  = find(ItemStack.class, "func_77960_j", "getItemDamage");
    private static final Method M_ITEM    = find(ItemStack.class, "func_77973_b", "getItem");

    private static Object call(Method m, Object on) {
        if (m == null || on == null) return null;
        try { return m.invoke(on); } catch (Throwable t) { return null; }
    }

    private static Item itemOf(ItemStack s) {
        Object o = call(M_ITEM, s);
        return (o instanceof Item) ? (Item) o : null;
    }

    private static int damageOf(ItemStack s) {
        Object o = call(M_DAMAGE, s);
        return (o instanceof Integer) ? (Integer) o : 0;
    }

    private static String labelOf(ItemStack s) {
        Object o = call(M_DISPLAY, s);
        if (o instanceof String && !((String) o).isEmpty()) return (String) o;
        return idOf(s);
    }

    /**
     * Stable identity for an item, without touching a remapped member.
     *
     * findUniqueIdentifierFor gives the readable modid:name, but it throws NPE
     * when GameData has no unique name for the item -- its UniqueIdentifier
     * constructor calls split() on the null. Across 200-odd mods some item in
     * the recipe maps always hits that, and it killed the whole run. So it is
     * attempted, then fallen back to the registry's numeric id, which is FML's
     * own method and cannot be remapped. Readability is not lost: the display
     * name is recorded separately.
     */
    private static String baseOf(Item it) {
        try {
            GameRegistry.UniqueIdentifier u = GameRegistry.findUniqueIdentifierFor(it);
            if (u != null && u.modId != null && u.name != null) return u.modId + ":" + u.name;
        } catch (Throwable ignored) { }
        try {
            return "id#" + GameData.getItemRegistry().getId(it);
        } catch (Throwable ignored) { }
        return it.getClass().getName();
    }

    private static String idOf(ItemStack s) {
        Item it = itemOf(s);
        if (it == null) return null;
        try { return baseOf(it) + ":" + damageOf(s); }
        catch (Throwable t) { return null; }
    }

    private static String wildIdOf(ItemStack s) {
        Item it = itemOf(s);
        if (it == null) return null;
        try { return baseOf(it) + ":*"; }
        catch (Throwable t) { return null; }
    }

    // ---------------------------------------------------------------------

    @Mod.EventHandler
    public void onServerStarted(FMLServerStartedEvent event) {
        int depth = DEFAULT_DEPTH;
        try {
            depth = Integer.parseInt(System.getProperty("asteroiddump.depth",
                    String.valueOf(DEFAULT_DEPTH)));
        } catch (NumberFormatException ignored) { }
        depth = Math.max(1, Math.min(6, depth));

        try {
            run(depth);
        } catch (Throwable t) {
            FMLLog.getLogger().error("[asteroiddump] failed", t);
        }
    }

    private static final class Step {
        final String machine;
        final GTRecipe recipe;
        Step(String machine, GTRecipe recipe) { this.machine = machine; this.recipe = recipe; }
    }

    private static Map<String, RecipeMap<?>> processingMaps() {
        Map<String, RecipeMap<?>> m = new LinkedHashMap<String, RecipeMap<?>>();
        m.put("macerator", RecipeMaps.maceratorRecipes);
        m.put("ore_washer", RecipeMaps.oreWasherRecipes);
        m.put("thermal_centrifuge", RecipeMaps.thermalCentrifugeRecipes);
        m.put("sifter", RecipeMaps.sifterRecipes);
        m.put("chemical_bath", RecipeMaps.chemicalBathRecipes);
        m.put("electromagnetic_separator", RecipeMaps.electroMagneticSeparatorRecipes);
        m.put("simple_washer", RecipeMaps.simpleWasherRecipes);
        // Dust separation: what resolves the rare-earth and Naquadah Earth
        // chains that no static source explains.
        m.put("centrifuge", RecipeMaps.centrifugeRecipes);
        m.put("electrolyzer", RecipeMaps.electrolyzerRecipes);
        return m;
    }

    private static void add(Map<String, List<Step>> m, String k, Step s) {
        if (k == null) return;
        List<Step> l = m.get(k);
        if (l == null) { l = new ArrayList<Step>(); m.put(k, l); }
        l.add(s);
    }

    private static Map<String, List<Step>> buildIndex(Map<String, RecipeMap<?>> maps) {
        Map<String, List<Step>> byInput = new HashMap<String, List<Step>>();
        for (Map.Entry<String, RecipeMap<?>> e : maps.entrySet()) {
            Collection<GTRecipe> recipes;
            try { recipes = e.getValue().getAllRecipes(); }
            catch (Throwable t) { continue; }
            if (recipes == null) continue;
            for (GTRecipe r : recipes) {
                if (r == null || r.mInputs == null) continue;
                for (ItemStack in : r.mInputs) {
                    if (in == null) continue;
                    Step st = new Step(e.getKey(), r);
                    // Defensive: a single unresolvable item should cost us that
                    // item, not the entire dump.
                    // Index exact and wildcard: GT inputs routinely use damage
                    // 32767 to mean "any damage".
                    add(byInput, idOf(in), st);
                    add(byInput, wildIdOf(in), st);
                }
            }
        }
        return byInput;
    }

    private static List<Step> stepsFor(ItemStack s, Map<String, List<Step>> index) {
        List<Step> a = index.get(idOf(s));
        List<Step> b = index.get(wildIdOf(s));
        if (a == null) return b;
        if (b == null) return a;
        List<Step> both = new ArrayList<Step>(a);
        both.addAll(b);
        return both;
    }

    private static final class Found {
        final String label; final int hops; final String via;
        Found(String label, int hops, String via) {
            this.label = label; this.hops = hops; this.via = via;
        }
    }

    private static Map<String, Found> walk(ItemStack seed, Map<String, List<Step>> index, int maxDepth) {
        Map<String, Found> found = new LinkedHashMap<String, Found>();
        Set<String> seen = new HashSet<String>();
        String sk = idOf(seed);
        if (sk != null) seen.add(sk);

        List<ItemStack> frontier = new ArrayList<ItemStack>();
        frontier.add(seed);

        for (int hop = 1; hop <= maxDepth && !frontier.isEmpty(); hop++) {
            List<ItemStack> next = new ArrayList<ItemStack>();
            for (ItemStack cur : frontier) {
                List<Step> steps = stepsFor(cur, index);
                if (steps == null) continue;
                for (Step st : steps) {
                    if (st.recipe.mOutputs == null) continue;
                    for (ItemStack out : st.recipe.mOutputs) {
                        if (out == null) continue;
                        String k = idOf(out);
                        if (k == null || seen.contains(k)) continue;
                        seen.add(k);
                        if (found.size() >= MAX_PRODUCTS_PER_DROP) return found;
                        found.put(k, new Found(labelOf(out), hop, st.machine));
                        next.add(out);
                    }
                }
            }
            frontier = next;
        }
        return found;
    }

    private static final class Drop {
        final ItemStack stack; final int chance;
        Drop(ItemStack stack, int chance) { this.stack = stack; this.chance = chance; }
    }

    private static int chanceAt(AsteroidData a, int i) {
        return (a.chances != null && i < a.chances.length) ? a.chances[i] : 0;
    }

    private static List<Drop> dropsOf(AsteroidData a) {
        List<Drop> drops = new ArrayList<Drop>();
        if (a.outputItems != null) {
            // The four asteroids declared with explicit ItemStacks. Unreachable
            // from outside the game, which is half the point of this mod.
            for (int i = 0; i < a.outputItems.length; i++) {
                if (a.outputItems[i] != null) drops.add(new Drop(a.outputItems[i], chanceAt(a, i)));
            }
            return drops;
        }
        if (a.output == null || a.orePrefixes == null) return drops;
        for (int i = 0; i < a.output.length; i++) {
            Materials m = a.output[i];
            if (m == null) continue;
            ItemStack s = null;
            try { s = GTOreDictUnificator.get(a.orePrefixes, m, 1L); }
            catch (Throwable ignored) { }
            if (s != null) drops.add(new Drop(s, chanceAt(a, i)));
        }
        return drops;
    }

    private static String esc(String s) {
        if (s == null) return "";
        StringBuilder b = new StringBuilder();
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            switch (c) {
                case '"':  b.append("\\\""); break;
                case '\\': b.append("\\\\"); break;
                case '\n': b.append("\\n"); break;
                case '\r': b.append("\\r"); break;
                case '\t': b.append("\\t"); break;
                default:
                    if (c < 0x20) b.append(String.format("\\u%04x", (int) c));
                    else b.append(c);
            }
        }
        return b.toString();
    }

    private static void log(String msg) {
        FMLLog.getLogger().info("[asteroiddump] " + msg);
    }

    private static void run(int depth) throws IOException {
        if (M_DISPLAY == null || M_ITEM == null) {
            log("could not resolve ItemStack methods by SRG or MCP name -- aborting");
            return;
        }

        log("indexing recipe maps...");
        Map<String, RecipeMap<?>> maps = processingMaps();
        Map<String, List<Step>> index = buildIndex(maps);
        log("indexed " + index.size() + " distinct inputs across " + maps.size() + " maps");

        List<AsteroidData> asteroids = SpaceMiningRecipes.uniqueAsteroidList;
        if (asteroids == null || asteroids.isEmpty()) {
            log("uniqueAsteroidList is empty -- GT Intergalactic not loaded?");
            return;
        }

        File out = new File("asteroid_dump.json");
        Writer w = new OutputStreamWriter(new FileOutputStream(out), StandardCharsets.UTF_8);
        int products = 0;
        try {
            w.write("{\n  \"depth\": " + depth + ",\n  \"asteroids\": [\n");
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
                    w.write("          \"id\": \"" + esc(idOf(d.stack)) + "\",\n");
                    w.write("          \"chance\": " + d.chance + ",\n");
                    w.write("          \"breaksDownInto\": [\n");
                    Map<String, Found> found = walk(d.stack, index, depth);
                    products += found.size();
                    int fi = 0;
                    for (Map.Entry<String, Found> e : found.entrySet()) {
                        Found f = e.getValue();
                        w.write("            { \"item\": \"" + esc(f.label)
                              + "\", \"id\": \"" + esc(e.getKey())
                              + "\", \"hops\": " + f.hops
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
        } finally {
            try { w.close(); } catch (IOException ignored) { }
        }

        log("wrote " + out.getAbsolutePath());
        log(asteroids.size() + " asteroids, " + products + " breakdown products at depth " + depth);
    }
}
