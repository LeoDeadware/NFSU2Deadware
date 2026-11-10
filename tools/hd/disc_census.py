#!/usr/bin/env python3
"""disc_census.py: offline census of every texture on NFSU2's Xbox disc (run with python3 -I).

  python3 -I tools/hd/disc_census.py [GAME_DIR] [--files ZZDATA2.BIN,...]

GAME_DIR (default: the installed test game's NFSUNDER folder) holds ZZDATA*.BIN. The C helper
(tools/hd/disc_census.c, built into work/hd/bin) finds every texture pack, rebuilds its data area,
hashes each texture as the Metal back end does and decodes it like the runtime census
(NFSU2_TEX_DUMP). Output, next to the runtime census so community.py match and build_pack.py see it:
  work/hd/census/disc/<hash>_<fmt>_<w>x<h>_<ui|world>.png
  work/hd/census/disc/index.tsv   hash fmt w h tpk texture file offset how (every occurrence; 8-bit
                                  textures whose palette the game fills at run time are left out)
Kind: the runtime census kind when the hash was seen in play (ui wins), else guess_kind() (pack/name).
Reads game data only; never runs the game.
"""
import collections
import os
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import hdlib  # noqa: E402

GAME = os.path.expanduser("~/Library/Application Support/NFSU2/player/game/NFSUNDER")
CENSUS = os.path.join(hdlib.CACHE, "census")
OUT = os.path.join(CENSUS, "disc")
# Kind of a texture never seen in play. From the runtime census (2026-11-07, 568 reproduced hashes): every
# texture seen from these packs was "ui" (flat 2D, depth test off); GLOBAL and INGAME mix HUD/menu art with
# car and effect textures, told apart by name. Everything else (TRACK, CARTEXTURES, VINYL, shops...) is world.
UI_PACKS = ("FRONTEND", "LANGUAGE", "MAGAZINES", "DYNAMIC", "GLOBALMESSAGE", "LOCATIONDYNAMIC", "TRACKMAP")
UI_NAMES = ("U2_", "UI_", "UG_", "XBOX_", "MODE_ICON", "LOCATION_ICON", "MINIMAP", "3RDPERSON", "SHIFT_", "WHITE16X16")


def guess_kind(tpk, tex):
    tpk, tex = tpk.upper(), tex.upper()
    if tpk.startswith(UI_PACKS) or (tpk in ("GLOBAL", "INGAME") and tex.startswith(UI_NAMES)):
        return "ui"
    return "world"


def helper():
    src = os.path.join(HERE, "disc_census.c")
    exe = os.path.join(hdlib.TOOLS, "disc_census")
    if not os.path.exists(exe) or os.path.getmtime(exe) < os.path.getmtime(src):
        os.makedirs(hdlib.TOOLS, exist_ok=True)
        subprocess.run(["clang", "-O2", "-o", exe, src, "-lz"], check=True)
    return exe


def runtime_kinds():
    kinds = {}
    for d in sorted(os.listdir(CENSUS)) if os.path.isdir(CENSUS) else []:
        if d == "disc" or not os.path.isdir(os.path.join(CENSUS, d)):
            continue
        for f in os.listdir(os.path.join(CENSUS, d)):
            p = f[:-4].split("_") if f.endswith(".png") else []
            if len(p) == 4 and len(p[0]) == 16:
                kinds[p[0]] = "ui" if kinds.get(p[0]) == "ui" or p[3] == "ui" else p[3]
    return kinds


def main():
    args = sys.argv[1:]
    files = None
    if "--files" in args:
        i = args.index("--files")
        files = args[i + 1].split(",")
        del args[i:i + 2]
    game = args[0] if args else GAME
    names = files or sorted(f for f in os.listdir(game) if f.upper().startswith("ZZDATA") and f.upper().endswith(".BIN"))
    stage = os.path.join(hdlib.CACHE, "disc-stage")   # outside census/: unnamed kinds never reach the matcher
    shutil.rmtree(stage, ignore_errors=True)
    os.makedirs(stage)
    p = subprocess.run(["nice", helper(), stage] + [os.path.join(game, n) for n in names], stdout=subprocess.PIPE,
                       stderr=subprocess.PIPE, text=True, check=True)
    rows = [ln.split("\t") for ln in p.stdout.splitlines()]
    sys.stdout.write(p.stderr)   # per file, cumulative: packs, textures, PNGs, duplicates, failures
    kinds = runtime_kinds()
    tex = [r for r in rows if r[0] == "tex"]
    first = {}
    for r in tex:
        first.setdefault(r[1], r)
    shutil.rmtree(OUT, ignore_errors=True)
    os.makedirs(OUT)
    out_kind = collections.Counter()
    for h, r in first.items():
        src = os.path.join(stage, "%s_%s_%sx%s.png" % (h, r[2], r[3], r[4]))
        if not os.path.exists(src):
            continue
        k = kinds.get(h) or guess_kind(r[5], r[6])
        os.rename(src, os.path.join(OUT, "%s_%s_%sx%s_%s.png" % (h, r[2], r[3], r[4], k)))
        out_kind[(r[2], k)] += 1
    shutil.rmtree(stage, ignore_errors=True)
    with open(os.path.join(OUT, "index.tsv"), "w") as fo:
        fo.write("# hash\tfmt\tw\th\ttpk\ttexture\tfile\toffset\thow\n")
        for r in tex:
            fo.write("\t".join(r[1:]) + "\n")
    skipped = collections.Counter(r[1] for r in rows if r[0] == "skip")
    seen = set(kinds)
    got = seen & set(first)
    print("disc census: %d texture records, %d unique hashes, %d PNGs -> %s" % (len(tex), len(first), sum(out_kind.values()), OUT))
    print("  per format/kind: " + ", ".join("%s %s %d" % (f, k, n) for (f, k), n in sorted(out_kind.items())))
    nopal = set(r[1] for r in rows if r[0] == "nopal")
    if nopal:
        print("  palette filled at run time (vinyls, door lines, wheel masks; no PNG): %d records, %d hashes"
              % (sum(1 for r in rows if r[0] == "nopal"), len(nopal)))
    if skipped:
        print("  not decoded (linear/unknown formats): " + ", ".join("%s %d" % kv for kv in sorted(skipped.items())))
    print("  runtime census: %d hashes, %d reproduced (%.0f%%)" % (len(seen), len(got), 100.0 * len(got) / max(1, len(seen))))
    by_fmt = collections.Counter()
    hit_fmt = collections.Counter()
    rt_fmt = {}
    for d in os.listdir(CENSUS):
        if d != "disc" and os.path.isdir(os.path.join(CENSUS, d)):
            for f in os.listdir(os.path.join(CENSUS, d)):
                if f.endswith(".png") and len(f.split("_")) == 4:
                    rt_fmt[f.split("_")[0]] = f.split("_")[1]
    for h, f in rt_fmt.items():
        by_fmt[f] += 1
        hit_fmt[f] += h in first
    print("  reproduced per format: " + ", ".join("%s %d/%d" % (f, hit_fmt[f], by_fmt[f]) for f in sorted(by_fmt)))


if __name__ == "__main__":
    main()
