#!/bin/bash
# The player's Mac builds the game code (the DMG never carries lifted or generated game code; Apple
# Command Line Tools only, no Homebrew):
#   build_game.sh <kit dir> <disc dir (game/extracted)> <out app> [progress file]
# kit (Resources/build, tools/dmg/kit.py): lift/ (xboxrecomp's Python lifter + regen.sh, seeds,
# recomp_manual.c), py/capstone, lib/ (runtime objects + static libraries + link.txt),
# ../../Frameworks (SDL2 compat + SDL3).
# Steps: 1. Command Line Tools (clt.sh); 2. lift default.xbe -> C (CLT python3 + our capstone);
# 3. compile (all performance cores, nice); 4. link into <out app>/Contents/MacOS/nfsu2-bin, ad-hoc sign.
# Progress lines "N text" (0..100) go to the progress file (the launcher's window reads it).
set -uo pipefail
KIT=$1 DISC=$2 APP=$3 PROG="${4:-/dev/null}"
OUT="$APP/Contents/MacOS/nfsu2-bin"
WORK="${NFSU2_BUILD_WORK:-$(dirname "$APP")/build-work}"
msg() { [[ "${NFSU2_UI_LANG:-en}" == uk ]] && echo "$2" || echo "$1"; }
report() { echo "$1 $2" >> "$PROG"; echo "build_game: [$1%] $2"; }
die() { report 100 "$(msg ERROR ПОМИЛКА): $1"; exit 1; }
: > "$PROG"
# 1. compiler
bash "$KIT/clt.sh" "$PROG" || die "$(msg "Command Line Tools are not installed" "Command Line Tools не встановлено")"
CC="$(xcrun -f clang)"
SDK="$(xcrun --show-sdk-path 2>/dev/null)"
[[ -d "$SDK" ]] || die "no macOS SDK in Command Line Tools (xcrun --show-sdk-path)"
[[ -x /usr/bin/python3 ]] && /usr/bin/python3 -c 'import sys' 2>/dev/null || die "no python3 (Command Line Tools)"
report 3 "$(msg Compiler Компілятор): $("$CC" --version | head -1)"
# 2. lift (resumable: a finished lift leaves gen/.done)
mkdir -p "$WORK/obj"
if [[ ! -f "$WORK/gen/.done" ]]; then
  report 5 "$(msg "Translating the game code (default.xbe)" "Перекладаю код гри (default.xbe)")"
  rm -rf "$WORK/gen" "$WORK/tk"; mkdir -p "$WORK/gen" "$WORK/tk"
  cp -R "$KIT/lift/tools" "$KIT/lift/templates" "$WORK/tk/"
  env PATH=/usr/bin:/bin PYTHONPATH="$KIT/py" PYTHONDONTWRITEBYTECODE=1 XBOXRECOMP_DIR="$WORK/tk" \
    NFSU2_XBE="$DISC/default.xbe" NFSU2_GEN_DIR="$WORK/gen" \
    nice -n 10 bash "$KIT/lift/com/tools/regen.sh" > "$WORK/lift.log" 2>&1 ||
    die "lift failed: $(tail -2 "$WORK/lift.log")"
  touch "$WORK/gen/.done"
fi
# 3. compile (existing objects newer than their source are kept)
srcs=("$WORK"/gen/*.c); n=${#srcs[@]}
(( n > 1 )) || die "no generated code"
jobs=${NFSU2_BUILD_JOBS:-$(sysctl -n hw.perflevel0.physicalcpu 2>/dev/null || sysctl -n hw.ncpu)}
FLAGS=(-isysroot "$SDK" -std=gnu11 -O2 -w -fno-strict-aliasing -fwrapv -DNDEBUG -DNFSU2_METAL=1 -DNOMINMAX
       -DWIN32_LEAN_AND_MEAN -arch arm64 -mmacosx-version-min=26.0 -I "$WORK/gen")
for f in "${FLAGS[@]}"; do printf '"%s"\n' "$f"; done > "$WORK/flags.rsp"   # paths may hold spaces
export CC WORK
done_n() { ls "$WORK"/obj/*.o 2>/dev/null | wc -l | tr -d ' '; }
printf '%s\0' "${srcs[@]}" | xargs -0 -P "$jobs" -n 1 bash -c '
  s="$1"; o="$WORK/obj/$(basename "${s%.c}").o"
  [[ -f "$o" && "$o" -nt "$s" ]] && exit 0
  nice -n 10 "$CC" @"$WORK/flags.rsp" -c "$s" -o "$o.tmp" 2>>"$WORK/compile.log" && mv "$o.tmp" "$o"' _ &
cpid=$!
while kill -0 $cpid 2>/dev/null; do
  report $((10 + 80 * $(done_n) / n)) "$(msg Compiling Компілюю) $(done_n)/$n"
  sleep 3
done
wait $cpid
(( $(done_n) == n )) || die "compile failed: $(grep -m2 error "$WORK/compile.log")"
# 4. link
report 92 "$(msg "Linking the game" "Збираю гру")"
FW="$(cd "$APP/Contents/Frameworks" && pwd)"
args=(); while read -r l; do l="${l//@KIT@/$KIT}"; args+=("${l//@FW@/$FW}"); done < "$KIT/lib/link.txt"
"$CC" -isysroot "$SDK" -arch arm64 -mmacosx-version-min=26.0 -Wl,-headerpad_max_install_names -o "$OUT.tmp" \
  "$WORK"/obj/*.o "${args[@]}" > "$WORK/link.log" 2>&1 || die "link failed: $(grep -m2 -i error "$WORK/link.log")"
for l in $(otool -L "$OUT.tmp" | awk 'NR>1 && /SDL/ {print $1}'); do
  install_name_tool -change "$l" "@executable_path/../Frameworks/$(basename "$l")" "$OUT.tmp" 2>/dev/null
done
codesign --force -s - "$OUT.tmp" >/dev/null 2>&1
mv "$OUT.tmp" "$OUT"
rm -rf "$WORK"
# the app icon and the launcher art: the title image of the player's disc (tools/icon)
report 97 "$(msg "Making the icon" "Готую іконку")"
mkdir -p "$APP/Contents/Resources/launcher"
bash "$KIT/icon/make_icns.sh" "$DISC/default.xbe" "$APP/Contents/Resources/NFSU2.icns" >/dev/null 2>&1 || true
bash "$KIT/icon/make_art.sh" "$DISC/default.xbe" "$APP/Contents/Resources/launcher/art.png" >/dev/null 2>&1 || true
touch "$APP"
report 100 "$(msg Done Готово)"
