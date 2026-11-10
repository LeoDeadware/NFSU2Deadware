#!/bin/bash
# Builds the HD world texture pack from scratch (regenerable, never committed):
#   tools/hdworld/make_pack.sh [build_dir] [out_dir] [top]
# 1. coverage runs: tests/scripts/levels_smoke.sh over the Burrow, Diagon
#    Alley and the Hogwarts maps (rows 0 5 30 29 27 16 26) with
#    NFSU2_HDUI_PROBE=1 (each texture a flat colour = its code, every draw
#    showing its stage-0 texture unlit: NFSU2_DEV_SHOW=t0), a shot every
#    150 frames and a texture dump (NFSU2_HDUI_DUMP) into ~/NFSU2Cache/hdworld/dump;
#    ~25 min, silent; HDWORLD_RUN=<levels_smoke dir> reuses earlier runs;
#    plus tools/hdworld/walks.sh: 4 long walks in Diagon Alley (the street
#    down to the white pillared building, which the short walk does not reach;
#    ~15 min); HDWORLD_WALKS=<walks dir> reuses earlier ones;
# 2. tools/hdworld/coverage.py: textures ranked by screen share;
# 3. tools/hdworld/build_world.py: every texture with >= 0.05 % of Diagon
#    Alley's screen (--must 05_:0.0005), then the top N (default 200) -> out_dir
#    (default ~/NFSU2Cache/hdworld/pack; for the player $NFSU2_DATA/mods/hd_world,
#    which the game loads by default).
# Needs Real-ESRGAN in ~/NFSU2Cache/tools/realesrgan/x (see tools/hdui/build_pack.py).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BUILD="${1:-$ROOT/out}"
OUT="${2:-$HOME/NFSU2Cache/hdworld/pack}"
TOP="${3:-200}"
W="$HOME/NFSU2Cache/hdworld"
mkdir -p "$W/dump"
RUN="${HDWORLD_RUN:-}"
if [[ -z "$RUN" ]]; then
  log="$W/coverage_runs.log"
  NFSU2_SHOT_EVERY=150 NFSU2_HDUI_PROBE=1 NFSU2_HDUI_DUMP="$W/dump" \
    NFSU2_DEV_MAGENTA=0-9999999 NFSU2_DEV_SHOW=t0 NFSU2_DEV_NOFOG=1 \
    "$ROOT/tests/scripts/levels_smoke.sh" "$BUILD" 0 5 30 29 27 16 26 > "$log" 2>&1 || true
  RUN=$(sed -n 's/^levels_smoke: .* out //p' "$log" | head -1)
fi
WALKS="${HDWORLD_WALKS:-}"
if [[ -z "$WALKS" ]]; then
  WALKS="$HOME/NFSU2Cache/runs/hdworld_walks-$(date +%Y%m%d-%H%M%S)"
  "$ROOT/tools/hdworld/walks.sh" "$BUILD" "$WALKS" 5 1 11 22 33 44 > "$W/walks.log" 2>&1 || true
fi
python3 "$ROOT/tools/hdworld/coverage.py" "$RUN" "$WALKS" --out "$W/coverage.tsv"
python3 "$ROOT/tools/hdworld/build_world.py" "$W/coverage.tsv" "$W/dump" --out "$OUT" --top "$TOP" --must 05_:0.0005
