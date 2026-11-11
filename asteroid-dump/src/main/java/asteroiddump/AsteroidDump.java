package asteroiddump;

import cpw.mods.fml.common.FMLLog;
import cpw.mods.fml.common.Mod;
import cpw.mods.fml.common.event.FMLServerStartedEvent;
import cpw.mods.fml.common.registry.GameData;
import cpw.mods.fml.common.registry.GameRegistry;

import net.minecraft.item.Item;
import net.minecraft.item.ItemStack;
import net.minecraftforge.fluids.FluidStack;

import gregtech.api.enums.Materials;
import gregtech.api.recipe.RecipeMap;
import gregtech.api.recipe.RecipeMaps;
import gregtech.api.util.GTOreDictUnificator;
import gregtech.api.util.GTRecipe;

import gtnhintergalactic.recipe.AsteroidData;
import gtnhintergalactic.recipe.IGRecipeMaps;
import gtnhintergalactic.recipe.SpaceMiningData;
import gtnhintergalactic.recipe.SpaceMiningRecipes;

import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.OutputStreamWriter;
import java.io.Writer;
import java.lang.reflect.Field;
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
 * WHAT v1.4 ADDS
 *   v1.3 said WHICH items an asteroid leads to. It could not say HOW MANY, or
 *   which of several asteroids is the better source, because it recorded no
 *   quantities and no mining parameters. The Space Elevator Calculator
 *   spreadsheet fills some of that by hand, and is wrong in places it cannot
 *   know about -- it scales size by drone tier but not duration or power, both
 *   of which addRecipesToDrones also scales. So v1.4 dumps the inputs to that
 *   arithmetic straight from the game:
 *
 *   spaceMining   every recipe in the space mining map: one per asteroid PER
 *                 DRONE TIER, with the size, duration, EU/t and computation the
 *                 game actually registered for that drone, its distance range,
 *                 weight, module tier, and the drone/drill/rod it consumes.
 *   breakdown     each product now carries the step that made it: input and
 *                 output amounts, output chance, the fluids the step needs, its
 *                 EU/t and duration, the item it came from, and the expected
 *                 count per ONE dropped item along that path ("yield").
 *   miner         the module's own constants (bonus stack cap, plasma usage),
 *                 and the drone, drill and rod for each tier, by label.
 *
 *   merge.py, beside this mod, combines the result with the calculator.
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
 *   FML), and reaches the ItemStack members it needs by reflection, trying the
 *   SRG name first and the MCP name second so it works either way. The SRG
 *   names were read out of GregTech's own bytecode rather than recalled.
 *
 *   GregTech, BartWorks, Intergalactic and Forge's own classes (FluidStack) are
 *   not remapped, so those are called directly. The miner tile entity is reached
 *   by reflection only because it would drag TecTech onto the compile path.
 *
 * DEPTH
 *   Defaults to 3 hops, override with -Dasteroiddump.depth=N. Traversal is
 *   limited to ore-processing maps plus centrifuge and electrolyzer. The full
 *   recipe graph is near fully connected -- follow alloying and the chemical
 *   reactor and every asteroid "yields" most of the game.
 */
@Mod(modid = AsteroidDump.MODID, name = "Asteroid Dump", version = AsteroidDump.VERSION,
     dependencies = "required-after:gregtech", acceptableRemoteVersions = "*")
public class AsteroidDump {

    public static final String MODID = "asteroiddump";
    public static final String VERSION = "1.4";

    private static final int DEFAULT_DEPTH = 3;
    private static final int MAX_PRODUCTS_PER_DROP = 400;

    /** OreDictionary.WILDCARD_VALUE. Hardcoded to avoid a Forge import. */
    private static final int WILDCARD_DAMAGE = 32767;

    private static final String MINER_CLASS =
        "gtnhintergalactic.tile.multi.elevatormodules.TileEntityModuleMiner";

    // ---------------------------------------------------------------------
    // Reflection into net.minecraft. SRG first, MCP second.
    // Names verified against GregTech's compiled bytecode:
    //   func_82833_r()Ljava/lang/String;              getDisplayName
    //   func_77960_j()I                               getItemDamage
    //   func_77973_b()Lnet/minecraft/item/Item;       getItem
    //   field_77994_a I                               stackSize
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

    private static Field findField(Class<?> owner, String... names) {
        for (String n : names) {
            try {
                Field f = owner.getDeclaredField(n);
                f.setAccessible(true);
                return f;
            } catch (Throwable ignored) { }
        }
        return null;
    }

    private static final Method M_DISPLAY = find(ItemStack.class, "func_82833_r", "getDisplayName");
    private static final Method M_DAMAGE  = find(ItemStack.class, "func_77960_j", "getItemDamage");
    private static final Method M_ITEM    = find(ItemStack.class, "func_77973_b", "getItem");
    private static final Field  F_SIZE    = findField(ItemStack.class, "field_77994_a", "stackSize");

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

    /** Stack size, or 1 when the field cannot be read -- the common case anyway. */
    private static int sizeOf(ItemStack s) {
        if (F_SIZE == null || s == null) return 1;
        try { return F_SIZE.getInt(s); } catch (Throwable t) { return 1; }
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

    private static String fluidName(FluidStack f) {
        if (f == null) return null;
        try { return f.getLocalizedName(); } catch (Throwable t) { }
        try { return f.getFluid().getName(); } catch (Throwable t) { return "?"; }
    }

    // ---------------------------------------------------------------------
    // A small JSON writer. v1.3 wrote JSON by string concatenation, which was
    // fine for one shape and is error-prone for four. This one tracks commas
    // per nesting level so a field can be added without touching its
    // neighbours.
    // ---------------------------------------------------------------------

    private static final class Json {
        private final Writer w;
        private final Deque<boolean[]> first = new ArrayDeque<boolean[]>();
        private int indent = 0;
        private boolean afterKey = false;

        Json(Writer w) { this.w = w; }

        private void pad() throws IOException {
            w.write('\n');
            for (int i = 0; i < indent; i++) w.write("  ");
        }

        private void sep() throws IOException {
            if (afterKey) { afterKey = false; return; }
            if (!first.isEmpty()) {
                boolean[] f = first.peek();
                if (!f[0]) w.write(',');
                f[0] = false;
                pad();
            }
        }

        Json open(char c) throws IOException {
            sep(); w.write(c); indent++; first.push(new boolean[] { true }); return this;
        }

        Json close(char c) throws IOException {
            indent--; boolean empty = first.pop()[0];
            if (!empty) pad();
            w.write(c); return this;
        }

        Json obj() throws IOException { return open('{'); }
        Json end() throws IOException { return close('}'); }
        Json arr() throws IOException { return open('['); }
        Json endArr() throws IOException { return close(']'); }

        Json key(String k) throws IOException {
            sep(); w.write('"'); w.write(esc(k)); w.write("\": "); afterKey = true; return this;
        }

        Json str(String v) throws IOException {
            sep();
            if (v == null) w.write("null");
            else { w.write('"'); w.write(esc(v)); w.write('"'); }
            return this;
        }

        Json num(double v) throws IOException {
            sep();
            if (Double.isNaN(v) || Double.isInfinite(v)) w.write("null");
            else if (v == Math.rint(v) && Math.abs(v) < 1e15) w.write(Long.toString((long) v));
            else w.write(String.format(Locale.ROOT, "%.6g", v));
            return this;
        }

        Json bool(boolean v) throws IOException { sep(); w.write(v ? "true" : "false"); return this; }

        Json kv(String k, String v) throws IOException { return key(k).str(v); }
        Json kv(String k, double v) throws IOException { return key(k).num(v); }
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
                    // Exact identity always. The wildcard bucket ONLY for inputs
                    // that really are damage-agnostic.
                    //
                    // v1.2 indexed every input under both, which was badly wrong:
                    // GregTech packs thousands of distinct items into one item id
                    // separated only by damage -- every ore is gt.blockores:<dmg>.
                    // Putting them all in one gt.blockores:* bucket meant a lookup
                    // for End Coal Ore returned every recipe consuming any ore, so
                    // coal "broke down into" crushed tungsten. 66821 products at
                    // one hop was the symptom.
                    add(byInput, idOf(in), st);
                    if (damageOf(in) == WILDCARD_DAMAGE) {
                        add(byInput, wildIdOf(in), st);
                    }
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

    /** How many of `cur` the recipe eats. Matched by id, wildcard last. */
    private static int inputAmount(GTRecipe r, ItemStack cur) {
        String id = idOf(cur), wild = wildIdOf(cur);
        int wildSize = 0;
        for (ItemStack in : r.mInputs) {
            if (in == null) continue;
            String k = idOf(in);
            if (k != null && k.equals(id)) return Math.max(1, sizeOf(in));
            if (damageOf(in) == WILDCARD_DAMAGE && wild != null && wild.equals(wildIdOf(in))) {
                wildSize = Math.max(1, sizeOf(in));
            }
        }
        return wildSize > 0 ? wildSize : 1;
    }

    private static int outputChance(GTRecipe r, int i) {
        if (r.mOutputChances == null || i >= r.mOutputChances.length) return 10000;
        return r.mOutputChances[i];
    }

    private static final class Found {
        final String label; final int hops; final String via;
        final String from;       // id of the item this step consumed
        final int inAmount;      // how many of `from` the step eats
        final int amount;        // how many it gives
        final int chance;        // out of 10000
        final double yield;      // expected count per ONE dropped item, along this path
        final int eut, ticks;
        final List<String> fluids;
        Found(String label, int hops, String via, String from, int inAmount, int amount,
              int chance, double yield, int eut, int ticks, List<String> fluids) {
            this.label = label; this.hops = hops; this.via = via; this.from = from;
            this.inAmount = inAmount; this.amount = amount; this.chance = chance;
            this.yield = yield; this.eut = eut; this.ticks = ticks; this.fluids = fluids;
        }
    }

    private static List<String> fluidInputs(GTRecipe r) {
        List<String> l = new ArrayList<String>();
        if (r.mFluidInputs != null) {
            for (FluidStack f : r.mFluidInputs) {
                if (f != null) l.add(fluidName(f) + " x" + f.amount);
            }
        }
        return l;
    }

    /**
     * Breadth-first, first path wins: the shortest route to each product, and
     * its yield along that route. A product reachable two ways at the same depth
     * keeps whichever was seen first; yields are a guide to scale, not a promise
     * that this is the best processing line.
     */
    private static Map<String, Found> walk(ItemStack seed, Map<String, List<Step>> index, int maxDepth) {
        Map<String, Found> found = new LinkedHashMap<String, Found>();
        Map<String, Double> yieldOf = new HashMap<String, Double>();
        Set<String> seen = new HashSet<String>();
        String sk = idOf(seed);
        if (sk != null) { seen.add(sk); yieldOf.put(sk, 1.0); }

        List<ItemStack> frontier = new ArrayList<ItemStack>();
        frontier.add(seed);

        for (int hop = 1; hop <= maxDepth && !frontier.isEmpty(); hop++) {
            List<ItemStack> next = new ArrayList<ItemStack>();
            for (ItemStack cur : frontier) {
                List<Step> steps = stepsFor(cur, index);
                if (steps == null) continue;
                String curId = idOf(cur);
                Double cy = yieldOf.get(curId);
                double curYield = cy == null ? 0 : cy;
                for (Step st : steps) {
                    GTRecipe r = st.recipe;
                    if (r.mOutputs == null) continue;
                    int inAmt = inputAmount(r, cur);
                    for (int i = 0; i < r.mOutputs.length; i++) {
                        ItemStack out = r.mOutputs[i];
                        if (out == null) continue;
                        String k = idOf(out);
                        if (k == null || seen.contains(k)) continue;
                        seen.add(k);
                        if (found.size() >= MAX_PRODUCTS_PER_DROP) return found;
                        int amt = Math.max(1, sizeOf(out));
                        int ch = outputChance(r, i);
                        double y = curYield * amt * (ch / 10000.0) / inAmt;
                        yieldOf.put(k, y);
                        found.put(k, new Found(labelOf(out), hop, st.machine, curId, inAmt, amt,
                                               ch, y, r.mEUt, r.mDuration, fluidInputs(r)));
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

    private static void log(String msg) {
        FMLLog.getLogger().info("[asteroiddump] " + msg);
    }

    private static String localized(AsteroidData a) {
        try { return a.getAsteroidNameLocalized(); } catch (Throwable t) { return a.asteroidName; }
    }

    private static void writeStack(Json j, ItemStack s) throws IOException {
        j.kv("item", labelOf(s)).kv("id", idOf(s)).kv("count", sizeOf(s));
    }

    // ---------------------------------------------------------------------
    // SECTIONS
    // ---------------------------------------------------------------------

    /**
     * The module's constants and the formulas they feed, read from the class
     * rather than restated. Formulas are transcribed from the module's bytecode
     * (TileEntityModuleMiner.process / getBonusStackChance / getRecipeTime) so
     * merge.py and anyone reading the dump work from the same arithmetic.
     */
    private static void writeMiner(Json j) throws IOException {
        j.key("miner").obj();
        Class<?> c = null;
        try { c = Class.forName(MINER_CLASS); } catch (Throwable ignored) { }
        j.key("constants").obj();
        if (c != null) {
            for (String n : new String[] { "BONUS_STACK_MAX_CHANCE", "MIN_RECIPE_TIME_MODIFIER",
                    "MAX_DISTANCE", "PLASMA_HELIUM_USAGE", "PLASMA_BISMUTH_USAGE", "PLASMA_RADON_USAGE",
                    "PLASMA_TECHNETIUM_USAGE", "PLASMA_PLUTONIUM241_USAGE" }) {
                try {
                    Field f = c.getDeclaredField(n);
                    f.setAccessible(true);
                    Object v = f.get(null);
                    if (v instanceof Number) j.kv(n, ((Number) v).doubleValue());
                } catch (Throwable ignored) { }
            }
        }
        j.end();

        j.key("formulas").obj();
        j.kv("selection", "one asteroid per run, weighted by recipe weight, among recipes whose module tier <= the module's, "
                        + "minDistance <= distance <= maxDistance, and whose drone/drill/rod/voltage the module can satisfy");
        j.kv("parallels", "min(requested, availableComputation / (computation * (1 - outpostComputationDiscount)))");
        j.kv("stacks", "per parallel: minSize guaranteed draws, plus (maxSize - minSize) draws each kept with probability bonusChance/10000");
        j.kv("draw", "each draw picks ONE output, weighted by its chance among the recipe's outputs");
        j.kv("bonusChance", "plasmaTier in 1..5: min(BONUS_STACK_MAX_CHANCE, (plasmaTier/6)^3 * 10000 * (2 - overdrive)); else 0");
        j.kv("time", "plasmaTier > 0: duration * max(0.5, (1 - 0.1*(plasmaTier-1)) / overdrive); else duration");
        j.kv("plasmaTier", "Helium 1, Bismuth 2, Radon 3, Technetium 4, Plutonium-241 5");
        j.kv("plasmaUsed", "plasmaUsage(tier) * parallels * (1 - outpostPlasmaDiscount)");
        j.end();

        j.key("tiers").arr();
        ItemStack[] drones = SpaceMiningRecipes.MINING_DRONES;
        ItemStack[] drills = SpaceMiningRecipes.MINING_DRILLS;
        ItemStack[] rods   = SpaceMiningRecipes.MINING_RODS;
        int n = drones == null ? 0 : drones.length;
        for (int i = 0; i < n; i++) {
            j.obj().kv("tier", i);
            j.kv("drone", drones[i] == null ? null : labelOf(drones[i]));
            j.kv("drill", drills != null && i < drills.length && drills[i] != null ? labelOf(drills[i]) : null);
            j.kv("rod",   rods   != null && i < rods.length   && rods[i]   != null ? labelOf(rods[i])   : null);
            j.end();
        }
        j.endArr();
        j.end();
    }

    private static int droneTierOf(GTRecipe r) {
        if (r.mInputs == null) return -1;
        for (ItemStack in : r.mInputs) {
            if (in == null) continue;
            try {
                Optional<Integer> t = SpaceMiningRecipes.getTierFromDrone(in);
                if (t != null && t.isPresent()) return t.get();
            } catch (Throwable ignored) { }
        }
        return -1;
    }

    /**
     * The space mining map as the module sees it: one recipe per asteroid per
     * drone tier. This is what the calculator spreadsheet approximates by hand.
     */
    private static int writeSpaceMining(Json j) throws IOException {
        Collection<GTRecipe> recipes = null;
        try { recipes = IGRecipeMaps.spaceMiningRecipes.getAllRecipes(); }
        catch (Throwable t) { log("space mining map unreadable: " + t); }
        j.key("spaceMining").arr();
        int n = 0;
        if (recipes != null) {
            for (GTRecipe r : recipes) {
                if (r == null) continue;
                SpaceMiningData d;
                Integer moduleTier;
                try {
                    d = r.getMetadata(IGRecipeMaps.SPACE_MINING_DATA);
                    moduleTier = r.getMetadataOrDefault(IGRecipeMaps.MODULE_TIER, 1);
                } catch (Throwable t) { continue; }
                if (d == null) continue;
                n++;
                j.obj();
                j.kv("asteroid", d.asteroidName);
                String loc;
                try { loc = d.getAsteroidNameLocalized(); } catch (Throwable t) { loc = d.asteroidName; }
                j.kv("label", loc);
                j.kv("droneTier", droneTierOf(r));
                j.kv("moduleTier", moduleTier == null ? 1 : moduleTier);
                j.key("distance").arr().num(d.minDistance).num(d.maxDistance).endArr();
                j.key("size").arr().num(d.minSize).num(d.maxSize).endArr();
                j.kv("computation", d.computation);
                j.kv("weight", d.recipeWeight);
                j.kv("eut", r.mEUt);
                j.kv("duration", r.mDuration);
                j.key("inputs").arr();
                if (r.mInputs != null) for (ItemStack in : r.mInputs) {
                    if (in != null) { j.obj(); writeStack(j, in); j.end(); }
                }
                j.endArr();
                j.key("fluids").arr();
                for (String f : fluidInputs(r)) j.str(f);
                j.endArr();
                j.key("outputs").arr();
                if (r.mOutputs != null) for (int i = 0; i < r.mOutputs.length; i++) {
                    ItemStack out = r.mOutputs[i];
                    if (out == null) continue;
                    j.obj(); writeStack(j, out); j.kv("chance", outputChance(r, i)); j.end();
                }
                j.endArr();
                j.end();
            }
        }
        j.endArr();
        return n;
    }

    private static void run(int depth) throws IOException {
        if (M_DISPLAY == null || M_ITEM == null) {
            log("could not resolve ItemStack methods by SRG or MCP name -- aborting");
            return;
        }
        if (F_SIZE == null) log("stackSize not readable -- every count will read as 1");

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
        int products = 0, mining = 0;
        try {
            Json j = new Json(w);
            j.obj();
            j.kv("version", VERSION);
            j.kv("depth", depth);
            writeMiner(j);
            mining = writeSpaceMining(j);

            j.key("asteroids").arr();
            for (AsteroidData a : asteroids) {
                j.obj();
                j.kv("name", a.asteroidName);
                j.kv("label", localized(a));
                j.kv("moduleTier", a.requiredModuleTier);
                j.key("droneTier").arr().num(a.minDroneTier).num(a.maxDroneTier).endArr();
                j.key("distance").arr().num(a.minDistance).num(a.maxDistance).endArr();
                j.key("size").arr().num(a.minSize).num(a.maxSize).endArr();
                j.kv("computation", a.computation);
                j.kv("duration", a.duration);
                j.kv("weight", a.recipeWeight);
                j.key("drops").arr();
                for (Drop d : dropsOf(a)) {
                    j.obj();
                    j.kv("item", labelOf(d.stack));
                    j.kv("id", idOf(d.stack));
                    j.kv("chance", d.chance);
                    j.key("breaksDownInto").arr();
                    Map<String, Found> found = walk(d.stack, index, depth);
                    products += found.size();
                    for (Map.Entry<String, Found> e : found.entrySet()) {
                        Found f = e.getValue();
                        j.obj();
                        j.kv("item", f.label).kv("id", e.getKey());
                        j.kv("hops", f.hops).kv("via", f.via);
                        j.kv("from", f.from).kv("in", f.inAmount);
                        j.kv("amount", f.amount).kv("chance", f.chance);
                        j.kv("yield", f.yield);
                        j.kv("eut", f.eut).kv("ticks", f.ticks);
                        if (!f.fluids.isEmpty()) {
                            j.key("fluids").arr();
                            for (String fl : f.fluids) j.str(fl);
                            j.endArr();
                        }
                        j.end();
                    }
                    j.endArr();
                    j.end();
                }
                j.endArr();
                j.end();
            }
            j.endArr();
            j.end();
            w.write('\n');
        } finally {
            try { w.close(); } catch (IOException ignored) { }
        }

        log("wrote " + out.getAbsolutePath());
        log(asteroids.size() + " asteroids, " + mining + " space mining recipes, "
            + products + " breakdown products at depth " + depth);
    }
}
