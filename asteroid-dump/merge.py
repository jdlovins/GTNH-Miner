#!/usr/bin/env python3
"""
merge.py -- combine the in-game asteroid dump with the Space Elevator Calculator.

    python merge.py --calc "GTNH Space Elevator Calculator.xlsx" \
                    [--dump asteroid_dump.json] [--config ../space-miner/config.lua] \
                    [--plasma 1] [--overdrive 1.0] [--out out]

Writes three files to --out:

  perfected.json   every asteroid with the game's numbers where the game has
                   them and the calculator's where it does not, each field
                   tagged with where it came from; the per-drone recipe the
                   module really runs; the best distance for every module tier
                   and drone; and, per item, which asteroid gives the most of it.
  report.md        every place the calculator, the game and config.lua disagree.
  generated.lua    config.asteroids and config.optimizationMatrix in config.lua's
                   own format, rebuilt from the merged data, ready to paste over
                   the blocks of the same name.

WHO WINS

The game. The calculator is somebody's transcription of the same recipes, made
by hand and not updated with the pack. What it is good for is the fields an
older dump (v1.3) never recorded -- size, computation, duration, EU/t -- and as
a cross-check. A v1.4 dump records all of those itself, per drone tier, and the
calculator is then a cross-check only.

THE MODEL (transcribed from TileEntityModuleMiner, see asteroiddump's "miner")

  pick      one asteroid per run, weighted by recipe weight, among recipes with
            module tier <= the module's, the loaded drone's tier, and
            minDistance <= distance <= maxDistance.
  per drone tier k = drone - minDrone + 1 (registered as separate recipes):
            size     += 2^(k-1) - 1
            duration  = ceil(duration / sqrt(k))
            EU/t      = ceil(EU/t * sqrt(k))
            The calculator applies the size bonus and neither of the others.
  draws     per parallel: minSize, plus (maxSize - minSize) each kept with
            probability bonus/10000, where bonus = min(7500,
            (plasmaTier/6)^3 * 10000 * (2 - overdrive)).
  draw      ONE output per draw, weighted by its chance among the outputs.
            Chances are a distribution, not independent rolls.
  time      duration * max(0.5, (1 - 0.1*(plasmaTier-1)) / overdrive)

  So the long-run rate of an asteroid at one setting is
            weight * draws / sum(weight * time) over everything eligible,
  which is the game's own "timedensity".

Standard library only, so it runs anywhere Python 3 does.
"""

import argparse
import json
import math
import os
import re
import sys
import zipfile
import xml.etree.ElementTree as ET

HERE = os.path.dirname(os.path.abspath(__file__))
TIER_KEYS = ["lv", "mv", "hv", "ev", "iv", "luv", "zpm", "uv", "uhv", "uev", "uiv", "umv", "uxv"]
MODULES = ["MK-I", "MK-II", "MK-III"]
TICKS_PER_HOUR = 72000


# ---------------------------------------------------------------------------
# xlsx, without openpyxl
# ---------------------------------------------------------------------------

_NS = {"m": "http://schemas.openxmlformats.org/spreadsheetml/2006/main",
       "r": "http://schemas.openxmlformats.org/officeDocument/2006/relationships"}


def read_xlsx(path):
    """{sheet: {row: {col: value}}}, values as the cached result of any formula."""
    z = zipfile.ZipFile(path)
    shared = []
    if "xl/sharedStrings.xml" in z.namelist():
        for si in ET.fromstring(z.read("xl/sharedStrings.xml")).findall("m:si", _NS):
            shared.append("".join(t.text or "" for t in si.iter("{%s}t" % _NS["m"])))
    wb = ET.fromstring(z.read("xl/workbook.xml"))
    rels = {r.get("Id"): r.get("Target") for r in ET.fromstring(z.read("xl/_rels/workbook.xml.rels"))}
    out = {}
    for s in wb.find("m:sheets", _NS):
        target = rels[s.get("{%s}id" % _NS["r"])].lstrip("/")
        if not target.startswith("xl/"):
            target = "xl/" + target
        rows = {}
        for c in ET.fromstring(z.read(target)).iter("{%s}c" % _NS["m"]):
            col, row = re.match(r"([A-Z]+)(\d+)", c.get("r")).groups()
            v = c.find("m:v", _NS)
            if c.get("t") == "s" and v is not None:
                val = shared[int(v.text)]
            elif c.get("t") == "inlineStr":
                val = "".join(x.text or "" for x in c.iter("{%s}t" % _NS["m"]))
            else:
                val = v.text if v is not None else None
            if val not in (None, ""):
                rows.setdefault(int(row), {})[col] = val
        out[s.get("name")] = rows
    return out


def num(v):
    try:
        f = float(v)
    except (TypeError, ValueError):
        return None
    return int(f) if f == int(f) else f


def norm(name):
    """Asteroid names differ in spelling between all three sources:
    'aluminiumLanthlineAsteroid', 'Aluminium-Lanth Line', 'Aluminium-LanthLine'.
    Lower-case, letters and digits only, and drop the 'asteroid' suffix."""
    n = re.sub(r"[^a-z0-9]", "", (name or "").lower())
    return re.sub(r"asteroid$", "", n)


# ---------------------------------------------------------------------------
# Sources
# ---------------------------------------------------------------------------

CALC_FIELDS = [  # Asteroids sheet column -> merged field
    ("B", "materials"), ("C", "weights"), ("D", "minSize"), ("E", "maxSize"),
    ("F", "minDist"), ("G", "maxDist"), ("H", "computation"), ("I", "minModule"),
    ("J", "duration"), ("K", "eut"), ("L", "minDrone"), ("M", "maxDrone"), ("N", "weight"),
]


def load_calc(path):
    book = read_xlsx(path)
    asteroids = {}
    for r, row in sorted(book.get("Asteroids", {}).items()):
        if r == 1 or "A" not in row:
            continue
        a = {"name": row["A"]}
        for col, field in CALC_FIELDS:
            v = row.get(col)
            if field == "materials":
                a[field] = [m.strip() for m in (v or "").split(",") if m.strip()]
            elif field == "weights":
                a[field] = [num(x) for x in (v or "").split(",") if x.strip()]
            else:
                a[field] = num(v)
        asteroids[norm(a["name"])] = a

    # "mkN module best": pairs of rows per asteroid, distance then chance,
    # one column per drone tier LV..UXV (C..O).
    best = {}
    cols = [chr(ord("C") + i) for i in range(len(TIER_KEYS))]
    for mi, mk in enumerate(MODULES):
        sheet = book.get("mk%d module best" % (mi + 1), {})
        cur = None
        table = best.setdefault(mk, {})
        for r in sorted(sheet):
            row = sheet[r]
            if r == 1:
                continue
            if row.get("A"):
                cur = row["A"]
            kind = row.get("B")
            if not cur or kind not in ("distance", "chance"):
                continue
            entry = table.setdefault(norm(cur), {"name": cur})
            for ci, col in enumerate(cols):
                if col in row:
                    entry.setdefault(TIER_KEYS[ci], {})[kind] = num(row[col])

    drills = []
    for r in range(2, 15):
        row = book.get("Templated Data", {}).get(r, {})
        if row.get("B"):
            drills.append({"drone": row["B"], "drill": row.get("G")})
    return {"asteroids": asteroids, "best": best, "tiers": drills}


def load_config(path):
    """The three things merge needs from config.lua, read as text: which
    config key each in-game asteroid name maps to (the asteroidOutputs header
    comments), the current config.asteroids keys, and the current matrix."""
    src = open(path, encoding="utf-8").read()
    internal = {}
    for key, inner in re.findall(r'^\s*\["([^"]+)"\]\s*=\s*\{\s*--\s*(\w+),', src, re.M):
        internal[inner] = key

    def block(name):
        m = re.search(r"^config\.%s = \{\n(.*?)^\}" % re.escape(name), src, re.M | re.S)
        return m.group(1) if m else ""

    keys = re.findall(r'^  \["([^"]+)"\] = \{', block("asteroids"), re.M)

    matrix, mk = {}, None
    for line in block("optimizationMatrix").splitlines():
        m = re.match(r'\s*\["(MK-[I]+)"\] = \{', line)
        if m:
            mk = m.group(1)
            matrix[mk] = {}
            continue
        m = re.match(r'\s*\["([^"]+)"\]\s*=\s*\{(.*)\}', line)
        if m and mk:
            matrix[mk][m.group(1)] = {k: int(v) for k, v in re.findall(r"(\w+)\s*=\s*(\d+)", m.group(2))}
    return {"internal": internal, "keys": keys, "matrix": matrix}


# ---------------------------------------------------------------------------
# Merge
# ---------------------------------------------------------------------------

def merge(dump, calc, cfg, report):
    """One record per asteroid, keyed by its config.lua name. Every scalar is
    {value, source}; a field both sides have and disagree on is reported."""
    by_norm_key = {norm(k): k for k in cfg["keys"]}
    merged = {}

    def key_for(game_name, label):
        if game_name in cfg["internal"]:
            return cfg["internal"][game_name]
        for cand in (label, game_name):
            if norm(cand) in by_norm_key:
                return by_norm_key[norm(cand)]
        return label or game_name

    for a in dump.get("asteroids", []):
        key = key_for(a["name"], a.get("label"))
        g = {
            "minModule": a.get("moduleTier"),
            # The game counts drone tiers from 0 (LV); config and calculator from 1.
            "minDrone": a["droneTier"][0] + 1, "maxDrone": a["droneTier"][1] + 1,
            "minDist": a["distance"][0], "maxDist": a["distance"][1],
            "weight": a.get("weight"),
        }
        if "size" in a:
            g.update(minSize=a["size"][0], maxSize=a["size"][1],
                     computation=a.get("computation"), duration=a.get("duration"))
        # AsteroidData has no EU/t; the recipe for the lowest drone tier does,
        # unscaled (k = 1), so it stands for the asteroid's base figure.
        base = [r for r in dump.get("spaceMining") or [] if r.get("asteroid") == a["name"]]
        if base:
            g["eut"] = min(base, key=lambda r: r["droneTier"])["eut"]
        merged[key] = {"key": key, "internal": a["name"], "label": a.get("label"),
                       "game": g, "drops": a.get("drops", [])}

    claimed = set()
    for key, m in merged.items():
        c = None
        for cand in (key, m["internal"], m.get("label")):
            c = calc["asteroids"].get(norm(cand))
            if c:
                claimed.add(norm(c["name"]))
                break
        m["calc"] = c
        fields = {}
        for f in ("minModule", "minDrone", "maxDrone", "minDist", "maxDist", "weight",
                  "minSize", "maxSize", "computation", "duration", "eut"):
            gv = m["game"].get(f)
            cv = c.get(f) if c else None
            if gv is not None:
                fields[f] = {"value": gv, "source": "game"}
                if cv is not None and cv != gv:
                    report["field"].append((key, f, gv, cv))
            elif cv is not None:
                fields[f] = {"value": cv, "source": "calculator"}
            else:
                report["missing"].append((key, f))
        m["fields"] = fields
        if not c:
            report["no_calc"].append(key)

        # Drops: the game's labels and chances. The calculator names materials,
        # not items, so it is only compared on the weights.
        if c and m["drops"]:
            gw = sorted(d["chance"] for d in m["drops"])
            cw = sorted(w for w in c.get("weights") or [] if w is not None)
            if gw != cw:
                report["weights"].append((key, gw, cw))

    for n, c in calc["asteroids"].items():
        if n not in claimed:
            report["calc_only"].append(c["name"])
    return merged


def per_drone(m, dump_mining, report):
    """The recipe the module actually runs for each drone tier."""
    f = {k: v["value"] for k, v in m["fields"].items()}
    recipes = {}
    from_game = [r for r in dump_mining if r.get("asteroid") == m["internal"]]
    for r in from_game:
        t = r["droneTier"] + 1
        recipes[t] = {"tier": t, "minSize": r["size"][0], "maxSize": r["size"][1],
                      "duration": r["duration"], "eut": r["eut"], "computation": r["computation"],
                      "weight": r["weight"], "minDist": r["distance"][0], "maxDist": r["distance"][1],
                      "moduleTier": r["moduleTier"], "source": "game",
                      "outputs": r.get("outputs", [])}
    if recipes:
        # Hold the formula below to account: everything the game registered
        # that it would not have predicted goes in the report, so a pack
        # update that changes the scaling shows up rather than hiding behind
        # the game's numbers.
        lo = min(recipes)
        b = recipes[lo]
        for t, r in sorted(recipes.items()):
            k = t - lo + 1
            bump = 2 ** (k - 1) - 1
            exp = {"minSize": recipes[lo]["minSize"] + bump, "maxSize": recipes[lo]["maxSize"] + bump,
                   "duration": math.ceil(b["duration"] / math.sqrt(k)),
                   "eut": math.ceil(b["eut"] * math.sqrt(k))}
            for fld, v in exp.items():
                if r[fld] != v:
                    report["formula"].append((m["key"], TIER_KEYS[t - 1] if t <= len(TIER_KEYS) else t,
                                              fld, v, r[fld]))
        return [recipes[t] for t in sorted(recipes)]

    needed = ("minDrone", "maxDrone", "minSize", "maxSize", "duration", "eut")
    if any(f.get(k) is None for k in needed):
        report["underived"].append(m["key"])
        return []
    out = []
    for t in range(f["minDrone"], f["maxDrone"] + 1):
        k = t - f["minDrone"] + 1
        bump = 2 ** (k - 1) - 1
        out.append({"tier": t, "minSize": f["minSize"] + bump, "maxSize": f["maxSize"] + bump,
                    "duration": math.ceil(f["duration"] / math.sqrt(k)),
                    "eut": math.ceil(f["eut"] * math.sqrt(k)),
                    "computation": f.get("computation"), "weight": f["weight"],
                    "minDist": f["minDist"], "maxDist": f["maxDist"],
                    "moduleTier": f["minModule"], "source": "derived"})
    return out


def bonus_chance(plasma, overdrive, cap=7500):
    if plasma <= 0 or plasma > 5:
        return 0
    return min(cap, int((plasma / 6.0) ** 3 * 10000 * (2 - overdrive)))


def time_factor(plasma, overdrive):
    if plasma <= 0:
        return 1.0
    return max(0.5, (1 - 0.1 * (plasma - 1)) / overdrive)


def optimise(merged, plasma, overdrive, cap, max_distance):
    """For every module tier, drone tier and asteroid: the distance that gives
    it the best pick chance, and the distance that gives the most draws per
    hour. They differ when a heavy, slow neighbour shares the range."""
    b = bonus_chance(plasma, overdrive, cap) / 10000.0
    tf = time_factor(plasma, overdrive)
    recipes = []
    for key, m in merged.items():
        for r in m["perDrone"]:
            recipes.append((key, r))

    best = {}
    for mi, mk in enumerate(MODULES):
        mod_tier = mi + 1
        for t in range(1, len(TIER_KEYS) + 1):
            mine = [(k, r) for k, r in recipes if r["tier"] == t and (r["moduleTier"] or 1) <= mod_tier]
            if not mine:
                continue
            lo = min(r["minDist"] for _, r in mine)
            hi = min(max_distance, max(r["maxDist"] for _, r in mine))
            for d in range(lo, hi + 1):
                here = [(k, r) for k, r in mine if r["minDist"] <= d <= r["maxDist"]]
                tw = sum(r["weight"] for _, r in here)
                td = sum(r["weight"] * r["duration"] * tf for _, r in here)
                if tw <= 0 or td <= 0:
                    continue
                for k, r in here:
                    p = r["weight"] / tw
                    draws = r["minSize"] + (r["maxSize"] - r["minSize"]) * b
                    rate = r["weight"] * draws / td * TICKS_PER_HOUR
                    slot = best.setdefault(mk, {}).setdefault(k, {}).setdefault(TIER_KEYS[t - 1], {})
                    # Ties go to the shorter distance, which is what the
                    # existing matrix does. Compared unrounded: comparing
                    # against the rounded figure let every tie win.
                    if p > slot.get("_p", -1) + 1e-12:
                        slot.update(_p=p, distance=d, pickChance=round(p, 6),
                                    drawsPerHourAtBest=round(rate, 2))
                    if rate > slot.get("_r", -1) + 1e-9:
                        slot.update(_r=rate, rateDistance=d, drawsPerHour=round(rate, 2))
    for table in best.values():
        for tiers in table.values():
            for slot in tiers.values():
                slot.pop("_p", None)
                slot.pop("_r", None)
    return best


def item_sources(merged, best):
    """Per item: expected count per draw from each asteroid, and the best
    (module, drone, distance) to get it. An item's per-draw figure is the
    share of draws that land on each drop, times what one of that drop
    processes into. Drops count as yield 1 of themselves.

    v1.3 dumps carry no yields, so only the drops themselves are ranked."""
    items = {}
    for key, m in merged.items():
        drops = m["drops"]
        total = sum(d.get("chance", 0) for d in drops) or 1
        counts = m.get("outCount") or {}
        per = {}
        for d in drops:
            # A draw adds the recipe output's whole stack -- 64 ore, not 1.
            # Only a 1.4 dump knows the stack size; a 1.3 one counts it as 1.
            share = d.get("chance", 0) / total * counts.get(d.get("id"), 1)
            per[d["item"]] = per.get(d["item"], 0) + share
            for p in d.get("breaksDownInto", []):
                y = p.get("yield")
                if y:
                    per[p["item"]] = per.get(p["item"], 0) + share * y
        for item, v in per.items():
            items.setdefault(item, []).append({"asteroid": key, "perDraw": round(v, 6)})

    for item, srcs in items.items():
        for s in srcs:
            s["best"] = {}
            for mk, table in best.items():
                for tier, slot in table.get(s["asteroid"], {}).items():
                    per_hour = s["perDraw"] * slot.get("drawsPerHour", 0)
                    cur = s["best"].get(mk)
                    if not cur or per_hour > cur["perHour"]:
                        s["best"][mk] = {"drone": tier, "distance": slot["rateDistance"],
                                         "perHour": round(per_hour, 2)}
        srcs.sort(key=lambda s: -s["perDraw"])
    return items


# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------

def lua_str(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


# Items that are not worth a mapping: ore (the module's raw drop, eaten by
# processing on arrival, never accumulates) and the half-processed stages that
# only exist between two machines. Same exclusions as asteroidOutputs.
_NOT_A_TARGET = re.compile(r"(^(Crushed|Purified|Centrifuged|Impure Pile of|Purified Pile of) )|( Ore$)")


def ranked_sources(items, best, asteroid_keys):
    """item -> [asteroid, ...], best first: the most per hour the asteroid can
    deliver at any module tier, drone and distance. The broker walks the list at
    dispatch and takes the first one it can actually reach with what it owns,
    so a source needing a drone you lack costs nothing.

    Only sources that are the BEST for at least one drone tier are kept. Stone
    dust comes off 39 asteroids, and the broker runs on a machine with a few
    hundred KB of memory; a source that is never the best choice for any drone
    you could own is never the one dispatch would pick, so it is not shipped."""
    out = {}
    for item, srcs in items.items():
        if _NOT_A_TARGET.search(item):
            continue
        overall, by_tier = {}, {}
        for s in srcs:
            ast = s["asteroid"]
            if ast not in asteroid_keys:
                continue
            for mk, table in best.items():
                for tier, slot in table.get(ast, {}).items():
                    rate = s["perDraw"] * slot.get("drawsPerHour", 0)
                    if rate <= 0:
                        continue
                    overall[ast] = max(overall.get(ast, 0), rate)
                    cur = by_tier.get(tier)
                    if not cur or rate > cur[0]:
                        by_tier[tier] = (rate, ast)
        keep = {ast for _, ast in by_tier.values()}
        if keep:
            out[item] = sorted(keep, key=lambda a: (-overall[a], a))
    return out


def write_lua(path, merged, best, generated_from, sources=None):
    out = ["-- Generated by asteroid-dump/merge.py from %s." % generated_from,
           "-- Paste each block over the block of the same name in space-miner/config.lua.",
           ""]
    # The broker does arithmetic on every one of these, so an asteroid missing
    # any is left out rather than emitted half-filled. It comes back once a
    # v1.4 dump supplies the fields.
    need = ("minSize", "maxSize", "minDist", "maxDist", "computation", "minModule",
            "duration", "eut", "minDrone", "maxDrone", "weight")
    keys = sorted(k for k in merged if all(f in merged[k]["fields"] for f in need))
    skipped = sorted(set(merged) - set(keys))
    if skipped:
        out.append("-- Left out, incomplete without a v1.4 dump: %s" % ", ".join(skipped))
        out.append("")
    out.append("config.asteroids = {")
    for i, key in enumerate(keys):
        m = merged[key]
        f = {k: v["value"] for k, v in m["fields"].items()}
        c = m.get("calc") or {}
        # materials and weights are parallel lists. The weights are the game's;
        # the calculator's names are kept only when they pair one-to-one with
        # them, which they do not where the game drops something it omits.
        wts = [d["chance"] for d in m["drops"]] or c.get("weights") or []
        mats = c.get("materials") or []
        if len(mats) != len(wts) and m["drops"]:
            mats = [re.sub(r" Ore$", "", d["item"]) for d in m["drops"]]
        out.append("  [%s] = {" % lua_str(key))
        out.append("    materials = { %s }," % ", ".join(lua_str(x) for x in mats))
        out.append("    weights = { %s }," % ", ".join(str(int(w)) for w in wts))
        rows = [("minSize", "minSize"), ("maxSize", "maxSize"), ("minDist", "minDist"),
                ("maxDist", "maxDist"), ("computation", "computation"), ("minModule", "minModule"),
                ("baseDuration", "duration"), ("euPerTick", "eut"), ("minDrone", "minDrone"),
                ("maxDrone", "maxDrone"), ("weight", "weight")]
        rows = [(lk, f[fk]) for lk, fk in rows if f.get(fk) is not None]
        for j, (lk, v) in enumerate(rows):
            out.append("    %s = %s%s" % (lk, v, "," if j + 1 < len(rows) else ""))
        out.append("  }" + ("," if i + 1 < len(keys) else ""))
    out.append("}")
    out.append("")
    out.append("config.optimizationMatrix = {")
    for mi, mk in enumerate(MODULES):
        table = best.get(mk, {})
        out.append('  ["%s"] = {' % mk)
        names = sorted(table)
        width = max([len(n) for n in names] or [0]) + 5   # ["name"] plus one space
        for ni, n in enumerate(names):
            parts = ["%s = %d" % (t, table[n][t]["distance"]) for t in TIER_KEYS if t in table[n]]
            out.append("    %-*s= { %s }%s" % (width, "[%s]" % lua_str(n), ", ".join(parts),
                                                "," if ni + 1 < len(names) else ""))
        out.append("  }" + ("," if mi + 1 < len(MODULES) else ""))
    out.append("}")
    if sources is not None:
        out.append("")
        out.append("config.itemSources = {")
        names = sorted(sources)
        width = max([len(n) for n in names] or [0]) + 5
        for i, n in enumerate(names):
            out.append("  %-*s= { %s }%s" % (width, "[%s]" % lua_str(n),
                                             ", ".join(lua_str(a) for a in sources[n]),
                                             "," if i + 1 < len(names) else ""))
        out.append("}")
    open(path, "w", encoding="utf-8", newline="\n").write("\n".join(out) + "\n")


ITEM_SOURCES_HEADER = """--------------------------------------------------------------------------------
-- 7c. ITEM SOURCES  (generated by asteroid-dump/merge.py -- do not hand-edit)
--
-- Every item an asteroid leads to, with the asteroids that yield it, best
-- first: the most of that item per hour each can deliver at its best module
-- tier, drone and distance.
--
-- This is the fallback for config.dustTargets, not a replacement. An item
-- listed there goes to that asteroid, always. An item that is not goes to the
-- first asteroid here that the broker can reach at dispatch time -- a drone of
-- the right tier free, and drill kits for it -- so a better source that needs
-- a drone you do not own is passed over rather than blocking the item.
--
-- Nothing here starts a job: only items in config.conditions are mined.
--------------------------------------------------------------------------------
"""



def apply_to_config(config_path, generated_path):
    """Replace config.asteroids and config.optimizationMatrix in config.lua
    with the generated blocks. Everything else in the file, comments included,
    is left exactly as it was."""
    def grab(text, name):
        m = re.search(r"^config\.%s = \{\n.*?^\}\n" % re.escape(name), text, re.M | re.S)
        if not m:
            raise SystemExit("config.%s not found in %s" % (name, config_path))
        return m
    raw = open(config_path, "rb").read().decode("utf-8")
    crlf = "\r\n" in raw
    src = raw.replace("\r\n", "\n")
    gen = open(generated_path, encoding="utf-8").read()
    for name in ("asteroids", "optimizationMatrix"):
        old = grab(src, name)
        src = src[:old.start()] + grab(gen, name).group(0) + src[old.end():]

    # itemSources is newer than the file it goes into, so the first apply has
    # to place it: just ahead of the dust target registry it backs up.
    block = grab(gen, "itemSources").group(0)
    if re.search(r"^config\.itemSources = \{", src, re.M):
        old = grab(src, "itemSources")
        src = src[:old.start()] + block + src[old.end():]
    else:
        anchor = re.search(r"^-{20,}\n-- 8\. DUST TARGET REGISTRY", src, re.M)
        if not anchor:
            raise SystemExit("cannot find section 8 in %s to place itemSources" % config_path)
        src = src[:anchor.start()] + ITEM_SOURCES_HEADER + block + "\n" + src[anchor.start():]
    if crlf:
        src = src.replace("\n", "\r\n")
    open(config_path, "wb").write(src.encode("utf-8"))


def write_report(path, report, merged, best, calc, cfg, dump):
    L = ["# Asteroid data: game vs calculator vs config.lua", ""]
    L.append("Dump version: %s. Asteroids in game: %d, in calculator: %d, in config.lua: %d."
             % (dump.get("version", "1.3 (no version field)"), len(merged),
                len(calc["asteroids"]), len(cfg["keys"])))
    L.append("")
    if not dump.get("spaceMining"):
        L += ["**This dump has no `spaceMining` section** (it predates asteroiddump 1.4), so size, "
              "computation, duration and EU/t come from the calculator, and per-drone values are "
              "derived with the formula from the module's bytecode. Run asteroiddump 1.4 to replace "
              "them with what the game registered.", ""]

    L += ["## The calculator's model is incomplete", "",
          "- Per drone tier the game also divides duration by sqrt(k) and, for most asteroids, "
          "multiplies EU/t by sqrt(k) (k = drone - minDrone + 1). The calculator scales size only, "
          "so its Time and Voltage are wrong for every drone above an asteroid's minimum. Where the "
          "game departs from that formula it is listed under \"Per-drone recipes the formula does "
          "not predict\".",
          "- Its Chance column is weight / sum of ALL asteroids' weights. The game only competes "
          "asteroids eligible at the chosen distance, drone and module tier.",
          "- Output chances are a weighted pick of ONE output per draw, not independent rolls. "
          "config.lua's asteroidOutputs header says otherwise (\"~2.9 items per run\") and is wrong.",
          ""]

    def table(title, head, rows):
        L.append("## %s (%d)" % (title, len(rows)))
        L.append("")
        if not rows:
            L.append("None.")
        else:
            L.append("| " + " | ".join(head) + " |")
            L.append("|" + "---|" * len(head))
            for r in rows:
                L.append("| " + " | ".join(str(x) for x in r) + " |")
        L.append("")

    table("Game and calculator disagree", ["asteroid", "field", "game", "calculator"], report["field"])
    table("Drop weights disagree", ["asteroid", "game", "calculator"], report["weights"])
    table("In the game, not the calculator", ["asteroid"], [(k,) for k in report["no_calc"]])
    table("In the calculator, not the game", ["asteroid"], [(k,) for k in report["calc_only"]])
    table("No value from either source", ["asteroid", "field"], report["missing"])
    table("Per-drone recipes the formula does not predict (the game's value is used)",
          ["asteroid", "drone", "field", "formula", "game"], report["formula"])

    diffs = []
    for mk, table_ in best.items():
        for ast, tiers in sorted(table_.items()):
            cur = cfg["matrix"].get(mk, {}).get(ast, {})
            for t in TIER_KEYS:
                new = tiers.get(t, {}).get("distance")
                old = cur.get(t)
                if new != old:
                    diffs.append((mk, ast, t, old if old is not None else "-",
                                  new if new is not None else "-",
                                  tiers.get(t, {}).get("pickChance", "")))
        for ast in cfg["matrix"].get(mk, {}):
            if ast not in table_:
                diffs.append((mk, ast, "*", "present", "no recipe", ""))
    table("Best distance differs from config.optimizationMatrix",
          ["module", "asteroid", "drone", "config", "merged", "pick chance"], diffs)

    calc_diffs = []
    for mk, table_ in best.items():
        for ast, tiers in table_.items():
            c = calc["best"].get(mk, {}).get(norm(ast))
            if not c:
                continue
            for t in TIER_KEYS:
                cd = (c.get(t) or {}).get("distance")
                nd = tiers.get(t, {}).get("distance")
                if cd is not None and nd is not None and int(cd) != nd:
                    calc_diffs.append((mk, ast, t, int(cd), nd))
    table("Best distance differs from the calculator's own best sheets",
          ["module", "asteroid", "drone", "calculator", "merged"], calc_diffs)
    open(path, "w", encoding="utf-8", newline="\n").write("\n".join(L) + "\n")


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--calc", required=True, help="Space Elevator Calculator .xlsx")
    ap.add_argument("--dump", default=os.path.join(HERE, "asteroid_dump.json"))
    ap.add_argument("--config", default=os.path.join(HERE, "..", "space-miner", "config.lua"))
    ap.add_argument("--plasma", type=int, default=1, help="plasma tier 1-5 (Helium..Pu-241)")
    ap.add_argument("--overdrive", type=float, default=1.0)
    ap.add_argument("--out", default=os.path.join(HERE, "out"))
    ap.add_argument("--apply", action="store_true",
                    help="also write the generated blocks into --config")
    a = ap.parse_args()

    dump = json.load(open(a.dump, encoding="utf-8"))
    calc = load_calc(a.calc)
    cfg = load_config(a.config)
    report = {k: [] for k in ("field", "weights", "no_calc", "calc_only", "missing", "underived", "formula")}

    merged = merge(dump, calc, cfg, report)
    mining = dump.get("spaceMining") or []
    for m in merged.values():
        m["perDrone"] = per_drone(m, mining, report)
        # Output stack size per item id. Identical across a recipe's drone
        # tiers, so the first recipe found for the asteroid stands for all.
        for r in mining:
            if r.get("asteroid") == m["internal"]:
                m["outCount"] = {o["id"]: o.get("count", 1) for o in r.get("outputs", [])}
                break

    consts = (dump.get("miner") or {}).get("constants") or {}
    cap = int(consts.get("BONUS_STACK_MAX_CHANCE", 7500))
    max_d = int(consts.get("MAX_DISTANCE", 0)) or max(
        (r["maxDist"] for m in merged.values() for r in m["perDrone"]), default=300)
    best = optimise(merged, a.plasma, a.overdrive, cap, max_d)
    items = item_sources(merged, best)

    os.makedirs(a.out, exist_ok=True)
    perfected = {
        "sources": {"dump": os.path.basename(a.dump), "dumpVersion": dump.get("version", "1.3"),
                    "calculator": os.path.basename(a.calc)},
        "assumptions": {"plasmaTier": a.plasma, "overdrive": a.overdrive,
                        "bonusChance": bonus_chance(a.plasma, a.overdrive, cap),
                        "timeFactor": time_factor(a.plasma, a.overdrive)},
        "miner": dump.get("miner") or {"tiers": calc["tiers"]},
        "asteroids": {k: {"internal": m["internal"], "label": m["label"], "fields": m["fields"],
                          "perDrone": m["perDrone"],
                          "drops": [{"item": d["item"], "chance": d["chance"]} for d in m["drops"]]}
                      for k, m in sorted(merged.items())},
        "best": best,
        "items": dict(sorted(items.items())),
    }
    json.dump(perfected, open(os.path.join(a.out, "perfected.json"), "w", encoding="utf-8"), indent=1)
    write_report(os.path.join(a.out, "report.md"), report, merged, best, calc, cfg, dump)
    sources = ranked_sources(items, best, {k for k, m in merged.items() if m["perDrone"]})
    perfected["itemSources"] = sources
    json.dump(perfected, open(os.path.join(a.out, "perfected.json"), "w", encoding="utf-8"), indent=1)
    write_lua(os.path.join(a.out, "generated.lua"), merged, best,
              "%s + %s" % (os.path.basename(a.dump), os.path.basename(a.calc)), sources)
    print("item sources %d (%d with more than one)"
          % (len(sources), sum(1 for v in sources.values() if len(v) > 1)))

    print("asteroids %d  per-drone recipes %d (%s)  items %d"
          % (len(merged), sum(len(m["perDrone"]) for m in merged.values()),
             "from game" if mining else "derived", len(items)))
    print("field disagreements %d  weight disagreements %d  calculator-only %d  game-only %d"
          % (len(report["field"]), len(report["weights"]), len(report["calc_only"]), len(report["no_calc"])))
    print("wrote %s" % a.out)
    if a.apply:
        apply_to_config(a.config, os.path.join(a.out, "generated.lua"))
        print("updated %s" % a.config)


if __name__ == "__main__":
    sys.exit(main())
