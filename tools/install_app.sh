#!/bin/bash
# Installs the current build as ~/Desktop/NFSU2.app (RULES R-I5): a real bundle whose executable is
# the Mach-O launcher tools/launcher/launcher.c; the game is Contents/MacOS/nfsu2-bin.
# Player files (settings, saves, logs, shader cache): ~/Library/Application Support/NFSU2/player; game data:
# an APFS clone (cp -c, zero bytes) of game/extracted in ~/Library/Application Support/NFSU2/data. Libraries outside the
# system (SDL) go into Contents/Frameworks: nothing from Homebrew at run time.
#   tools/install_app.sh [build_dir]     NFSU2_APP=<path>: a test install elsewhere
#   NFSU2_DMG=1: the DMG build (tools/make_dmg.sh): no game data, no game code, first-run kit instead
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="${1:-$ROOT/community/build-macos}"
BIN="$BUILD/nfsu2_recomp"
APP="${NFSU2_APP:-$HOME/Desktop/NFSU2.app}"
C="$APP/Contents"; RES="$C/Resources"
DMG="${NFSU2_DMG:-0}"
[[ -x "$BIN" ]] || { echo "no $BIN — build first (./BUILD_NATIVE.sh)"; exit 2; }
# Never replace the app under a running game (PIT-never-kill-running-game). BUSY = exit 2.
[[ -n "${NFSU2_APP:-}" ]] || ! pgrep -f "$C/MacOS/nfsu2-bin" > /dev/null || { echo "install_app: BUSY — the game is running; not installed"; exit 2; }

rm -rf "$C/MacOS" "$C/Frameworks"; mkdir -p "$C/MacOS" "$C/Frameworks" "$RES"
# SDL: the binary's SDL2 (sdl2-compat) + the SDL3 it loads (@loader_path/libSDL3.dylib), both zlib.
copy_sdl() {  # <binary>: copy its non-system dylibs to Frameworks, rewrite the load paths
  local bin="$1" lib real dst
  for lib in $(otool -L "$bin" | awk 'NR>1{print $1}' | grep -vE '^(/usr/lib|/System|@executable_path)'); do
    real="$lib"; [[ -f "$real" ]] || { echo "install_app: FAIL cannot find $lib"; exit 1; }
    case "$(basename "$lib")" in libSDL2*) ;; *) echo "install_app: FAIL unexpected runtime library $lib"; exit 1;; esac
    dst="$C/Frameworks/libSDL2-2.0.0.dylib"; cp -L "$real" "$dst"; chmod u+w "$dst"
    install_name_tool -id "@executable_path/../Frameworks/libSDL2-2.0.0.dylib" "$dst"
    install_name_tool -change "$lib" "@executable_path/../Frameworks/libSDL2-2.0.0.dylib" "$bin"
  done
}
SDL3="${NFSU2_SDL3:-/opt/homebrew/opt/sdl3/lib/libSDL3.0.dylib}"   # build-time source only
cp "$BIN" "$C/MacOS/nfsu2-bin"; chmod u+w "$C/MacOS/nfsu2-bin"
copy_sdl "$C/MacOS/nfsu2-bin"
cp -L "$SDL3" "$C/Frameworks/libSDL3.dylib"; chmod u+w "$C/Frameworks/libSDL3.dylib"
install_name_tool -id "@loader_path/libSDL3.dylib" "$C/Frameworks/libSDL3.dylib"
if otool -L "$C/MacOS/nfsu2-bin" "$C/Frameworks/"* | grep -q /opt/homebrew; then
  echo "install_app: FAIL Homebrew path left in the app:"; otool -L "$C/MacOS/nfsu2-bin" "$C/Frameworks/"* | grep /opt/homebrew; exit 1
fi
if [[ $DMG == 1 ]]; then
  # no game code and no game data: the build kit (tools/dmg/kit.py) + the first-run importer
  rm -f "$C/MacOS/nfsu2-bin"; rm -rf "$RES/game" "$RES/build" "$RES/import"
  python3 -I "$ROOT/tools/dmg/kit.py" "$BUILD" "$RES/build"
  cp "$ROOT"/tools/dmg/{build_game.sh,clt.sh,progress.js} "$RES/build/"
  mkdir -p "$RES/build/icon" "$RES/import"
  cp "$ROOT"/tools/icon/{make_icns.sh,squircle.swift,xbe_title_image.py} "$ROOT/tools/launcher/make_art.sh" "$RES/build/icon/"
  swiftc -O -o "$RES/build/icon/squircle" "$ROOT/tools/icon/squircle.swift" 2>/dev/null || true
  X="$ROOT/tools/dmg/xiso.py"; [[ -f "$X" ]] || X="$ROOT/../XboxPortKit/portkit/xiso.py"  # in-tree copy in the public repo
  cp "$ROOT/tools/dmg/import_disc.py" "$X" "$RES/import/"
else
  # No reads from ~/Desktop at run time (root CLAUDE.md, 2026-11-06: no macOS permission dialogs): the game
  # data goes to ~/Library/Application Support/NFSU2/data (APFS clone, zero bytes), the player folder next to
  # it; the bundle carries no game data. The owner's saves from .cache/player move over once.
  rm -rf "$RES/game"
  LIB="$HOME/Library/Application Support/NFSU2"
  if [[ ! -f "$LIB/data/game/extracted/default.xbe" ]]; then
    rm -rf "$LIB/data/game/extracted"; mkdir -p "$LIB/data/game"
    cp -c -R "$ROOT/game/extracted" "$LIB/data/game/extracted"
  fi
  OLD="$ROOT/.cache/player"
  if [[ -d "$OLD" && ! -d "$LIB/player" ]]; then
    mkdir -p "$LIB/player/game"
    for d in home saves; do [[ -d "$OLD/$d" ]] && cp -R "$OLD/$d" "$LIB/player/"; done
    for d in UDATA TDATA; do [[ -d "$OLD/game/$d" ]] && cp -R "$OLD/game/$d" "$LIB/player/game/"; done
    echo "install_app: player files moved to $LIB/player (the old copy stays in .cache/player)"
  fi
fi
# HD textures (tools/hd: census.sh + build_pack.py -> work/hd/pack): in every app and DMG (owner 2026-11-06:
# ready packs in the DMG, no generation on the player's Mac). Derived from game data: publishing is a
# separate owner decision. The game reads Contents/Resources/hd (src/apple/apple_textures.m).
# Community textures (tools/hd/community.py merge -> work/hd/pack-merged, docs/COMMUNITY_ASSETS.md) win when built.
HD_DEF="$ROOT/work/hd/pack"; [[ -f "$ROOT/work/hd/pack-merged/manifest.tsv" ]] && HD_DEF="$ROOT/work/hd/pack-merged"
HD="${NFSU2_HD_PACK:-$HD_DEF}"
rm -rf "$RES/hd"
if [[ -f "$HD/manifest.tsv" ]]; then
  mkdir -p "$RES/hd"; cp -c "$HD"/*.png "$HD/manifest.tsv" "$RES/hd/" 2>/dev/null || cp "$HD"/*.png "$HD/manifest.tsv" "$RES/hd/"
  echo "install_app: HD pack $(($(wc -l < "$HD/manifest.tsv") - 1)) textures"
else
  echo "install_app: no HD pack ($HD) — the app uses the original textures"
fi
mkdir -p "$RES/launcher"; cp "$ROOT/tools/launcher/launcher.js" "$RES/launcher/"
PLAYER=""   # ~/Library/Application Support/NFSU2/player (never a folder under ~/Desktop)
clang -O2 -DNFSU2_PLAYER_ROOT="\"$PLAYER\"" -o "$C/MacOS/NFSU2" "$ROOT/tools/launcher/launcher.c"
if [[ $DMG != 1 ]]; then
  bash "$ROOT/tools/icon/make_icns.sh" "$ROOT/game/extracted/default.xbe" "$RES/NFSU2.icns" || echo "warning: no icon"
  bash "$ROOT/tools/launcher/make_art.sh" "$ROOT/game/extracted/default.xbe" "$RES/launcher/art.png" || echo "warning: no launcher art"
fi
cat > "$C/Info.plist" <<EOS
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>NFSU2</string>
  <key>CFBundleDisplayName</key><string>Need for Speed Underground 2</string>
  <key>CFBundleIdentifier</key><string>local.nfsu2port.game</string>
  <key>CFBundleExecutable</key><string>NFSU2</string>
  <key>CFBundleIconFile</key><string>NFSU2</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>GCSupportsControllerUserInteraction</key><true/>
</dict></plist>
EOS
touch "$APP"
codesign --force --deep -s - "$APP" >/dev/null 2>&1 || echo "warning: ad-hoc signing failed"
[[ -n "${NFSU2_APP:-}" ]] || rm -f "$HOME/Desktop/Run NFS Underground 2.command"
echo "installed $APP ($(git -C "$ROOT" rev-parse --short HEAD))"
