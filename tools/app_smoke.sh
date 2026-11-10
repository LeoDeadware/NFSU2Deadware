#!/bin/bash
# Smoke test of the INSTALLED app, launched the way Finder does it (RULES R-I5): `open -n NFSU2.app`
# with the smoke settings by `open --env`: no launcher window, windowed, NFSU2_SMOKE_SECONDS (default 25),
# player files in a run dir. Checks: CFBundleExecutable is a Mach-O; no Homebrew path in the app; the
# log shows the Metal renderer, the game booted (kernel thunks resolved) and frames ([fps] line), and the
# bounded run ended by itself ("smoke time limit reached").
# Never touches a running game (PIT-never-kill-running-game): BUSY = exit 2; on timeout only our pid dies.
#   tools/app_smoke.sh          APP=~/Desktop/NFSU2.app by default
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${APP:-$HOME/Desktop/NFSU2.app}"
C="$APP/Contents"
SECS="${NFSU2_SMOKE_SECONDS:-25}"
[[ -x "$C/MacOS/nfsu2-bin" ]] || { echo "app_smoke: FAIL no $C/MacOS/nfsu2-bin"; exit 1; }
exe="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$C/Info.plist" 2>/dev/null)"
fails=0
file -b "$C/MacOS/$exe" | grep -q "Mach-O" || { echo "app_smoke: FAIL CFBundleExecutable '$exe' is not a Mach-O"; fails=1; }
if otool -L "$C/MacOS/nfsu2-bin" "$C"/Frameworks/* 2>/dev/null | grep -q /opt/homebrew; then
  echo "app_smoke: FAIL Homebrew path in the app"; fails=1
fi
if pgrep -f "$C/MacOS/nfsu2-bin" > /dev/null; then
  echo "app_smoke: BUSY — the game is running (pid $(pgrep -f "$C/MacOS/nfsu2-bin" | tr '\n' ' ')); not touched, not tested"; exit 2
fi
# the run dir is in the user library: the app must never touch ~/Desktop (no TCC dialog)
LIB="$HOME/Library/Application Support/NFSU2"
RUN="$LIB/smoke/app_smoke-$(date +%Y%m%d-%H%M%S)-$$"; mkdir -p "$RUN"
LOG="$RUN/logs/nfsu2.log"
open -n "$APP" --env NFSU2_PLAYER_ROOT="$RUN" --env NFSU2_DATA_DIR="$LIB/data" --env NFSU2_NO_UI=1 --env NFSU2_FULLSCREEN=0 \
  --env NFSU2_SMOKE_SECONDS="$SECS" || { echo "app_smoke: FAIL open -n $APP"; fails=1; }
pid=""; for _ in $(seq 1 40); do pid="$(pgrep -f "$C/MacOS/nfsu2-bin" | head -1)"; [[ -n "$pid" ]] && break; sleep 0.5; done
for _ in $(seq 1 $(( (SECS + 40) * 2 ))); do [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null || break; sleep 0.5; done
if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then kill -9 "$pid"; echo "app_smoke: FAIL timeout (pid $pid)"; fails=1; fi
[[ -n "$pid" ]] || { echo "app_smoke: FAIL the game process never started"; fails=1; }
chk() { grep -qE -- "$1" "$LOG" 2>/dev/null || { echo "app_smoke: FAIL no '$1' in the log"; fails=1; }; }
chk "renderer: Metal"; chk "Kernel thunk bridge: 152/152 resolved"; chk "^\[fps\] [0-9.]+ fps"; chk "smoke time limit reached"
grep -h -m3 -E "FATAL|Assertion|SIGSEGV" "$LOG" 2>/dev/null && fails=1
# no file under ~/Desktop may be opened by the game (lsof is not reliable post mortem: the log's paths)
# (the app may read its own bundle wherever it lies: launcher line and Contents/Resources are allowed)
grep -E "/Users/[^/]+/Desktop/" "$LOG" | grep -vE "^launcher: /Users/[^/]*/Desktop/NFSU2.app|$C/Resources/" | head -3 | grep . && { echo "app_smoke: FAIL a ~/Desktop path at run time"; fails=1; }
(( fails )) && { mkdir -p "$ROOT/.cache/runs"; cp -R "$RUN" "$ROOT/.cache/runs/"; echo "app_smoke: evidence $ROOT/.cache/runs/$(basename "$RUN")"; exit 1; }
echo "app_smoke: PASS ($(grep -m1 -E '^\[fps\] [0-9.]+ fps' "$LOG"))"
rm -rf "$RUN"
