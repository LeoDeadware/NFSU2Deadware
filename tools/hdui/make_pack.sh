#!/bin/bash
# Builds the HD UI texture pack from scratch (regenerable, never committed):
#   tools/hdui/make_pack.sh [build_dir] [out_dir]
# 1. the Ukrainian overlay (tools/loc/build_mod.py uk) into ~/NFSU2Cache/hdui/uk,
# 2. two silent texture dumps (NFSU2_HDUI_DUMP) over tools/loc/test_page.pad
#    (title, slots, level 1 HUD, pause, inventory): with the overlay (Cyrillic
#    font atlases) and without (the disc's atlases),
# 3. tools/hdui/build_pack.py -> out_dir (default ~/NFSU2Cache/hdui/pack; for
#    the player: $NFSU2_DATA/mods/hd_ui, which the game loads by default).
# Needs Real-ESRGAN in ~/NFSU2Cache/tools/realesrgan/x (see build_pack.py).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BIN="${1:-$ROOT/out}/src/loader/nfsu2"
OUT="${2:-$HOME/NFSU2Cache/hdui/pack}"
DATA="${NFSU2_DATA:-$(cd "$(dirname "$0")/../.." && pwd)}"
UK="$HOME/NFSU2Cache/hdui/uk"
RUN="$HOME/NFSU2Cache/runs/hdui-make-$(date +%Y%m%d-%H%M%S)-$$"
python3 "$ROOT/tools/loc/build_mod.py" uk --out "$UK" > /dev/null
dump() {
  local d="$RUN/$1"
  mkdir -p "$d/home"
  (
    ulimit -c 0
    export HOME="$d/home" NFSU2_LOG_DIR="$d" NFSU2_KTRACE=0 SDL_AUDIO_DRIVER=dummy SDL_VIDEO_DRIVER=dummy \
           NFSU2_BACKGROUND=1 NFSU2_DATA="$DATA" NFSU2_MODS="$2" NFSU2_SKIP_MOVIES=1 NFSU2_HDUI=0 \
           NFSU2_PAD_SCRIPT="$ROOT/tools/loc/test_page.pad" NFSU2_LANG="$3" NFSU2_HDUI_DUMP="$d/dump" \
           NFSU2_EXIT_AFTER=6960
    exec "$BIN" > "$d/stdout.log" 2>&1
  )
}
dump uk "$UK" uk & dump disc "/nonexistent" en & wait
python3 "$ROOT/tools/hdui/build_pack.py" "$RUN/uk/dump" "$RUN/disc/dump" --out "$OUT"
