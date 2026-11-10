#!/usr/bin/env python3
"""community.py: community HD textures (PC mods) -> NFSU2's Xbox HD pack (owner 2026-11-07: allowed,
authors credited in docs/COMMUNITY_ASSETS.md, takedown within 24 h on complaint).

  python3 -I tools/hd/community.py unpack PACK.tpf TAG        -> .cache/community/TAG/ (tpf.py)
  python3 -I tools/hd/community.py match TAG [PC_DIR]         -> work/hd/community/TAG/ (tpfmatch.swift
                                                                 against work/hd/census/*; PC_DIR for a
                                                                 mod that ships plain files)
  python3 -I tools/hd/community.py merge TAG[,TAG...]         -> work/hd/pack-merged = our pack + TAGs
                                                                 (later TAGs win; a community texture wins
                                                                 over ours when its k >= ours)
  then NFSU2_HD_PACK=work/hd/pack-merged tools/install_app.sh ... (or make_dmg.sh)

Downloads stay outside the repo (Port ISOs/NFSU2-mods or .cache): untrusted data, never executed;
this script takes their paths as arguments. Reviewed per-pack settings (PC dir, threshold, rejected
hashes): tools/hd/community.tsv; TPFMATCH="--thr 0.12 ..." overrides its options.
"""
import os
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, HERE)
import hdlib  # noqa: E402

CACHE = os.path.join(ROOT, ".cache", "community")
OUT = os.path.join(hdlib.CACHE, "community")
CENSUS = os.path.join(hdlib.CACHE, "census")


def manifest(path):
    rows = {}
    if os.path.exists(path):
        for ln in open(path):
            if ln.startswith("#") or not ln.strip():
                continue
            f = ln.rstrip("\n").split("\t")
            rows[f[0]] = f
    return rows


def reviewed():
    """tools/hd/community.tsv: tag -> [pc_dir, tpfmatch options, skip]."""
    out = {}
    for ln in open(os.path.join(HERE, "community.tsv")):
        if ln.strip() and not ln.startswith("#"):
            f = ln.rstrip("\n").split("\t")
            out[f[0]] = f[1:4]
    return out


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    cmd = sys.argv[1]
    if cmd == "unpack":
        pack, tag = sys.argv[2], sys.argv[3]
        dst = os.path.join(CACHE, tag)
        subprocess.run([sys.executable, "-I", os.path.join(HERE, "tpf.py"), pack, dst], check=True)
    elif cmd == "match":
        tag = sys.argv[2]
        cfg = reviewed().get(tag, ["-", "", "-"])
        pc = sys.argv[3] if len(sys.argv) > 3 else os.path.join(CACHE, tag, "files") if cfg[0] == "-" else \
            os.path.join(CACHE, cfg[0])
        dst = os.path.join(OUT, tag)
        shutil.rmtree(dst, ignore_errors=True)
        dirs = ",".join(os.path.join(CENSUS, d) for d in sorted(os.listdir(CENSUS)))
        extra = (os.environ.get("TPFMATCH") or cfg[1]).split()
        subprocess.run([hdlib.tool("tpfmatch"), "--xbox", dirs, "--pc", pc, "--out", dst, "--tag", tag] + extra,
                       check=True)
        skip = set() if cfg[2] == "-" else set(cfg[2].split(","))
        if skip:   # rejected by eye: drop from the manifest (matches.tsv keeps them, verdict "skip")
            rows = manifest(os.path.join(dst, "manifest.tsv"))
            with open(os.path.join(dst, "manifest.tsv"), "w") as fo:
                fo.write("# hash\tkind\tfmt\tw\th\tk\tmode\tengine\n")
                for h in sorted(rows):
                    if h in skip:
                        os.unlink(os.path.join(dst, h + ".png"))
                    else:
                        fo.write("\t".join(rows[h]) + "\n")
            m = [ln.split("\t") for ln in open(os.path.join(dst, "matches.tsv"))]
            with open(os.path.join(dst, "matches.tsv"), "w") as fo:
                for f in m:
                    if not f[0].startswith("#") and f[0] in skip and f[3] == "ok":
                        f[3] = "skip"
                    fo.write("\t".join(f))
        verdicts = {}
        for ln in open(os.path.join(dst, "matches.tsv")):
            if not ln.startswith("#"):
                v = ln.split("\t")[3]
                verdicts[v] = verdicts.get(v, 0) + 1
        print("match %s: %s (review %s/matches.tsv)" % (tag, ", ".join("%s %d" % kv for kv in sorted(verdicts.items())), dst))
    elif cmd == "merge":
        ours = os.path.join(hdlib.CACHE, "pack")
        dst = os.path.join(hdlib.CACHE, "pack-merged")
        shutil.rmtree(dst, ignore_errors=True)
        shutil.copytree(ours, dst, copy_function=lambda s, d: os.link(s, d))
        rows = manifest(os.path.join(dst, "manifest.tsv"))
        won = {}
        for tag in sys.argv[2].split(","):
            for h, f in manifest(os.path.join(OUT, tag, "manifest.tsv")).items():
                if h in rows and rows[h][6] != "community" and int(rows[h][5]) > int(f[5]):
                    continue
                if os.path.exists(os.path.join(dst, h + ".png")):
                    os.unlink(os.path.join(dst, h + ".png"))
                os.link(os.path.join(OUT, tag, h + ".png"), os.path.join(dst, h + ".png"))
                rows[h] = f
                won[tag] = won.get(tag, 0) + 1
        os.unlink(os.path.join(dst, "manifest.tsv"))
        with open(os.path.join(dst, "manifest.tsv"), "w") as fo:
            fo.write("# hash\tkind\tfmt\tw\th\tk\tmode\tengine\n")
            for h in sorted(rows):
                fo.write("\t".join(rows[h]) + "\n")
        print("merge: %d textures, community: %s -> %s" % (len(rows), won, dst))
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
