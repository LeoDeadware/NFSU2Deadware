#!/bin/bash
# Dev run of community/build-metal/nfsu2_recomp from the shell (NOT the Finder path: app_smoke.sh is that).
# Game dir in ~/Library/Application Support/NFSU2/dev/game (links to game/extracted + own UDATA/TDATA copy).
#   tools/dev/run.sh NAME SECS [VAR=VALUE ...]   -> logs/dev/NAME/{nfsu2.log, f*.bmp}
# Never runs while a game is running (PIT-never-kill-running-game): BUSY = exit 2.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# R-T3/R-T12: a game run takes a lock.py runs slot (waits while a perf run measures; inside one it passes).
[[ -n "${NFSU2_RUNS_HELD:-}" ]] || NFSU2_RUNS_HELD=1 exec python3 -I "$ROOT/tools/lock.py" runs -- bash "$0" "$@"
# Head 2026-11-07: frozen (tools/owner_pause.py) while the owner plays a game from ~/Desktop; a run that was
# paused prints CONTAMINATED and exits 4 (its frame times are not evidence).
[[ -n "${DEADWARE_OWNER_PAUSED:-}" ]] || { mkdir -p "$ROOT/.cache/tmp"; \
  DEADWARE_PAUSE_MARK="$ROOT/.cache/tmp/pause-run-$$" exec python3 -I "$ROOT/tools/owner_pause.py" -- bash "$0" "$@"; }
NAME="$1"; SECS="$2"; shift 2
if pgrep -f "^[^ ]*/(nfsu2-bin|nfsu2_recomp)( |$)" >/dev/null; then echo "dev/run: BUSY (a game is running)"; exit 2; fi
DEV="$HOME/Library/Application Support/NFSU2/dev"; G="$DEV/game"
if [[ ! -d "$G" ]]; then
  mkdir -p "$G"
  for e in "$ROOT"/game/extracted/*; do b="$(basename "$e")"
    case "$b" in UDATA|TDATA) ;; *) ln -s "$e" "$G/$b";; esac; done
  P="$HOME/Library/Application Support/NFSU2/player/game"
  cp -R "$P/UDATA" "$G/UDATA" 2>/dev/null || mkdir -p "$G/UDATA"
  mkdir -p "$G/TDATA"
fi
OUT="$ROOT/logs/dev/$NAME"; rm -rf "$OUT"; mkdir -p "$OUT"
cd "$DEV"
env NFSU2_GAME_DIR="$G" NFSU2_RENDERER=metal NFSU2_FULLSCREEN=0 NFSU2_KEYBOARD=0 RECOMP_FPS_LOG=1 \
  NFSU2_SMOKE_SECONDS="$SECS" HOME="$DEV" "$@" \
  "$ROOT/community/build-metal/nfsu2_recomp" > "$OUT/nfsu2.log" 2>&1 &
pid=$!
for _ in $(seq 1 $(( (SECS + 30) * 2 ))); do kill -0 $pid 2>/dev/null || break; sleep 0.5; done
kill -0 $pid 2>/dev/null && { kill -9 $pid; echo "dev/run: timeout, killed $pid"; }
echo "dev/run: $(grep -c . "$OUT/nfsu2.log") log lines; $(ls "$OUT" | grep -c bmp) frames; $(grep -m1 -E '^\[fps\]' "$OUT/nfsu2.log")"
if [[ -s "${DEADWARE_PAUSE_MARK:-/nonexistent}" ]]; then
  cp "$DEADWARE_PAUSE_MARK" "$OUT/paused.txt"; rm -f "$DEADWARE_PAUSE_MARK"
  echo "dev/run: CONTAMINATED (paused for the owner's game: $(tr '\n' ' ' < "$OUT/paused.txt"))"; exit 4; fi
