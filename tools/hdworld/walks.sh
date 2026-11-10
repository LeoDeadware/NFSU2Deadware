#!/bin/bash
# Coverage walks for the HD world pack: long seeded random walks in one level,
# in probe mode (as make_pack.sh's levels_smoke runs), for the areas a short
# levels_smoke walk does not reach:
#   tools/hdworld/walks.sh <build_dir> <out_dir> <row> <chapter> <seed>...
# e.g. tools/hdworld/walks.sh out ~/NFSU2Cache/runs/walks 5 1 11 22 33 44  (Diagon Alley)
# The level is reached by a crafted save (New Game -> chapter start map -> save
# aimed at <row>, as tests/scripts/hdworld_pack.sh); then per seed one run of
# ~4300 frames of walking, a shot every 100 frames, into <out_dir>/<row>_w<seed>/
# (the NN_* dir names tools/hdworld/coverage.py reads). Two runs at a time.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BIN="$1/src/loader/nfsu2"
OUT=$2 ROW=$3 CH=$4
shift 4
DATA="${NFSU2_DATA:-$(cd "$(dirname "$0")/../.." && pwd)}"
W="$HOME/NFSU2Cache/hdworld"
mkdir -p "$OUT/home" "$W/dump"
run() {  # <dir> <home> <pad text> [env...]
  local d=$1 home=$2 pad=$3
  shift 3
  mkdir -p "$d"
  printf "$pad" > "$d/pad.txt"
  (
    ulimit -c 0
    export HOME="$home" NFSU2_LOG_DIR="$d" NFSU2_KTRACE=0 NFSU2_KTRACE_KERNEL=1 SDL_AUDIO_DRIVER=dummy \
           SDL_VIDEO_DRIVER=dummy NFSU2_BACKGROUND=1 NFSU2_SKIP_MOVIES=1 NFSU2_DATA="$DATA" NFSU2_PAD_SCRIPT="$d/pad.txt"
    unset NFSU2_LOOK NFSU2_STUB NFSU2_NO_PACING
    exec env "$@" "$BIN" > "$d/stdout.log" 2> "$d/stderr.log"
  )
  echo $? > "$d/exit"
}
save_call() {
  local f=$3
  echo "$f:4C140/0,$f:copy:529C10:527B78:2064,$f:poke:529C10:$(printf %X $1),$f:poke:529C14:$(printf %X $2),$f:poke:529C18:$(printf %X $((1 << $2))),$f:poke:529BE0:1,$f:39A30/1E8058@1E7F9C"
}
CH_START=(0 4 30 30 30 30 30 30 30 30 30 30 27 52)
start=${CH_START[$CH]}
run "$OUT/_newgame" "$OUT/home" '0 disconnect\n1 connect\n450 press A\n600 press A\n7060 press A\n' \
  NFSU2_CALL_AT="$(save_call $start $CH 7000)" NFSU2_EXIT_AFTER=7300
if [[ $start != $ROW ]]; then
  run "$OUT/_hop" "$OUT/home" '0 disconnect\n1 connect\n450 press A\n600 press A\n2560 press A\n' \
    NFSU2_CALL_AT="$(save_call $ROW $CH 2500)" NFSU2_EXIT_AFTER=2800
fi
walk() {  # <seed>
  local d="$OUT/$(printf %02d $ROW)_w$1"
  mkdir -p "$d"
  cp -c -R "$OUT/home" "$d/home"
  local pad
  pad=$(python3 - "$1" <<'EOF'
import random, sys
r = random.Random(int(sys.argv[1]))
L = ["0 disconnect", "1 connect", "450 press A", "600 press A"]
f = 1300
while f < 5600:
    n = r.randint(60, 240)
    x, y = r.choice([(0, 1), (0, 1), (0, 1), (0.7, 0.7), (-0.7, 0.7), (1, 0), (-1, 0), (0, -1)])
    L.append(f"{f} stick L {x} {y} {n}")
    f += n + 10
print("\\n".join(L), end="\\n")
EOF
)
  run "$d" "$d/home" "$pad" NFSU2_HDUI_PROBE=1 NFSU2_HDUI_DUMP="$W/dump" NFSU2_DEV_MAGENTA=0-9999999 \
    NFSU2_DEV_SHOW=t0 NFSU2_DEV_NOFOG=1 NFSU2_SHOT_EVERY=100 NFSU2_EXIT_AFTER=5700
  echo "$(basename "$d"): exit $(cat "$d/exit")"
}
seeds=("$@")
for ((i = 0; i < ${#seeds[@]}; i += 2)); do
  walk "${seeds[$i]}" &
  [[ -n "${seeds[$((i + 1))]:-}" ]] && walk "${seeds[$((i + 1))]}" &
  wait
done
