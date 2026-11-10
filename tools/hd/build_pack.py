#!/usr/bin/env python3
"""build_pack.py DUMP_DIR [DUMP_DIR...] --out DIR [--budget MB] [--only HASH,...]

Builds NFSU2's HD texture pack from texture dumps (NFSU2_TEX_DUMP, community
src/apple/apple_textures.m: <hash>_<fmt>_<w>x<h>_<ui|world>.png, the decoded
original with straight alpha; tools/hd/census.sh makes them).

  ui     first drawn with the depth test off (menus, HUD, fonts, loading
         screens): hdfix split -> Real-ESRGAN x4plus-anime -> hdfix join (tone
         corrected to the original; --ink for square textures <= 64 and for
         font atlases: mostly transparent, grey/white). 4x up to 256 texels,
         2x up to 512.
Textures of one colour are left alone (blank canvases the game fills later:
the Quick Race track map went black when its empty state was replaced).
  world  everything else (cars, vinyls, track, signs): hdfix pad 16 (wrap when
         the texture tiles, PIT-H04) -> split -> Real-ESRGAN x4plus -> join ->
         crop. 4x up to 64 texels, 2x up to 256 (VRAM: no larger).
The glyphs src/apple/apple_prompts.m redraws are left to it. Level-0 RGBA
total kept under --budget (default 640 MB, ui first).
Output: <hash>.png + manifest.tsv (hash kind fmt w h k mode engine). Derived
from the game's data: never committed, never published without the owner's
decision (Deadware: HD in the DMG, release decision separate).
"""
import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import hdlib  # noqa: E402

ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
PAD = 16
NAME = re.compile(r"^([0-9a-f]{16})_([0-9a-f]{2})_(\d+)x(\d+)_(ui|world)\.png$")


def prompt_hashes():
    p = os.path.join(ROOT, "community", "src", "apple", "apple_prompts.m")
    return set(m.lower() for m in re.findall(r"0x([0-9a-fA-F]{16})ull", open(p).read())) if os.path.exists(p) else set()


def census(dirs):
    """hash -> dict(fmt, w, h, kind, src); ui wins when a texture was seen both ways."""
    out = {}
    for d in dirs:
        for f in sorted(os.listdir(d)):
            m = NAME.match(f)
            if not m:
                continue
            h, fmt, w, hh, kind = m.group(1), m.group(2), int(m.group(3)), int(m.group(4)), m.group(5)
            t = out.get(h)
            if not t:
                out[h] = dict(fmt=fmt, w=w, h=hh, kind=kind, src=os.path.join(d, f))
            elif kind == "ui":
                t["kind"] = "ui"
    return out


def scale(t):
    m = max(t["w"], t["h"])
    if min(t["w"], t["h"]) < 8:
        return 0
    if t["kind"] == "ui":
        return 4 if m <= 256 else 2 if m <= 512 else 0
    return 4 if m <= 64 else 2 if m <= 256 else 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("dumps", nargs="+")
    ap.add_argument("--out", required=True)
    ap.add_argument("--budget", type=float, default=640)
    ap.add_argument("--only", default="")
    a = ap.parse_args()
    only = set(filter(None, a.only.split(",")))
    skip = prompt_hashes()
    tex = census(a.dumps)
    hdfix = hdlib.tool("hdfix")
    st = {}
    srcs = [t["src"] for t in tex.values()]
    for i in range(0, len(srcs), 200):
        out = subprocess.run([hdfix, "stats"] + srcs[i:i + 200], check=True, capture_output=True, text=True).stdout
        for line in out.splitlines():
            f = line.split("\t")
            st[f[0]] = [float(x) for x in f[1:]]
    flat = 0
    todo, total = [], 0
    for h, t in sorted(tex.items(), key=lambda kv: (kv[1]["kind"] != "ui", kv[0])):
        k = scale(t)
        if not k or h in skip or (only and h not in only):
            continue
        tr, _, _, sat, fl = st[t["src"]]
        if fl:
            flat += 1
            continue
        t["font"] = t["kind"] == "ui" and tr >= 0.4 and sat < 0.15
        size = t["w"] * t["h"] * k * k * 4
        if total + size > a.budget * 2**20:
            continue
        total += size
        todo.append((h, t, k))
    os.makedirs(a.out, exist_ok=True)
    work = tempfile.mkdtemp(prefix="nfsu2-hd-", dir=hdlib.CACHE if os.path.isdir(hdlib.CACHE) else None)
    edges = {}
    for kind in ("ui", "world"):
        os.makedirs(os.path.join(work, kind, "in"))
    for h, t, k in todo:
        src, inp = t["src"], os.path.join(work, t["kind"], "in")
        if t["kind"] == "world":
            padded = os.path.join(work, h + "_p.png")
            edges[h] = subprocess.run([hdfix, "pad", src, padded, str(PAD), "auto"], check=True,
                                      capture_output=True, text=True).stdout.strip()
            src = padded
        subprocess.run([hdfix, "split", src, os.path.join(inp, h + "_c.png"), os.path.join(inp, h + "_a.png")],
                       check=True)
    eng = hdlib.engine()
    for kind, model in (("ui", "realesrgan-x4plus-anime"), ("world", "realesrgan-x4plus")):
        inp = os.path.join(work, kind, "in")
        if os.listdir(inp):
            eng = hdlib.upscale4(inp, os.path.join(work, kind, "up"), model)
    counts = {}
    with open(os.path.join(a.out, "manifest.tsv"), "w") as man:
        man.write("# hash\tkind\tfmt\tw\th\tk\tmode\tengine\n")
        for h, t, k in todo:
            up = os.path.join(work, t["kind"], "up")
            dst = os.path.join(a.out, h + ".png")
            joined = os.path.join(work, h + "_j.png")
            if t["kind"] == "world":
                subprocess.run([hdfix, "join", os.path.join(work, h + "_p.png"), os.path.join(up, h + "_c.png"),
                                os.path.join(up, h + "_a.png"), joined], check=True)
                subprocess.run([hdfix, "crop", joined, dst, str(PAD * 4)] + (["--half"] if k == 2 else []),
                               check=True)
                mode = edges[h]
            else:
                ink = (t["w"] == t["h"] and t["w"] <= 64) or t["font"]
                subprocess.run([hdfix, "join", t["src"], os.path.join(up, h + "_c.png"),
                                os.path.join(up, h + "_a.png"), joined] + (["--ink"] if ink else []), check=True)
                if k == 2:
                    subprocess.run([hdfix, "crop", joined, dst, "0", "--half"], check=True)
                else:
                    shutil.move(joined, dst)
                mode = "ink" if ink else "tone"
            counts[t["kind"]] = counts.get(t["kind"], 0) + 1
            man.write(f"{h}\t{t['kind']}\t{t['fmt']}\t{t['w']}\t{t['h']}\t{k}\t{mode}\t{eng}\n")
    shutil.rmtree(work)
    print(f"hd pack: {len(todo)} of {len(tex)} textures, {flat} flat skipped ({', '.join(f'{v} {k}' for k, v in sorted(counts.items()))}), "
          f"engine {eng}, {total / 2**20:.0f} MB level 0 -> {a.out}")
    return 0 if todo else 1


if __name__ == "__main__":
    sys.exit(main())
