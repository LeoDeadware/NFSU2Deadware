#!/bin/bash
# NFSU2 disk images (unsigned, no Apple signing):
#   tools/make_dmg.sh players [build_dir] [out.dmg]   default out/dmg/NFSU2-players.dmg
#   tools/make_dmg.sh full    [build_dir] [out.dmg]   default out/dmg/NFSU2-full.dmg (the owner only)
# players: install_app.sh in DMG mode (NFSU2_DMG=1): no game data, no game code. Resources/import has
#   the importer (tools/dmg/import_disc.py + XboxPortKit xiso.py); Resources/build the kit
#   (tools/dmg/kit.py: lifter, capstone, runtime objects and libraries). First run: the player's own
#   disc image -> ~/Library/Application Support/NFSU2/data, Command Line Tools if missing, lift +
#   compile -> ~/Desktop/NFSU2.app. tests/dmg_no_game_code.sh gates the image.
# full: the complete app (game code + the owner's disc data). Never published (Deadware/CLAUDE.md).
# HD pack (R-L5): install_app.sh copies work/hd/pack into Resources/hd of both images.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Head 2026-11-07: frozen (tools/owner_pause.py) while the owner plays a game from ~/Desktop.
[[ -n "${DEADWARE_OWNER_PAUSED:-}" ]] || exec python3 -I "$ROOT/tools/owner_pause.py" -- bash "$0" "$@"
MODE="${1:-players}"; BUILD="${2:-$ROOT/community/build-metal}"
DMG="${3:-$ROOT/out/dmg/NFSU2-$MODE.dmg}"
STAGE="$ROOT/.cache/dmg-stage-$MODE"
export TMPDIR="$ROOT/.cache/tmp"; mkdir -p "$TMPDIR" "$(dirname "$DMG")"
rm -rf "$STAGE"; mkdir -p "$STAGE"
case "$MODE" in
  players) NFSU2_DMG=1 NFSU2_APP="$STAGE/NFSU2.app" bash "$ROOT/tools/install_app.sh" "$BUILD" | tail -2 ;;
  full)    NFSU2_APP="$STAGE/NFSU2.app" bash "$ROOT/tools/install_app.sh" "$BUILD" | tail -2
           # an owner-only image: the disc data inside the bundle (the launcher prefers Resources/game)
           mkdir -p "$STAGE/NFSU2.app/Contents/Resources/game"
           cp -c -R "$ROOT/game/extracted" "$STAGE/NFSU2.app/Contents/Resources/game/extracted" ;;
  *) echo "usage: make_dmg.sh players|full [build_dir] [out.dmg]"; exit 2 ;;
esac
APP="$STAGE/NFSU2.app"
cat > "$APP/Contents/Resources/THIRD_PARTY_NOTICES.txt" <<'TXT'
NFSU2 for Mac includes:
- xboxrecomp runtime (MIT), with APU code derived from xemu (LGPL-2.1; source on request).
- SDL3 and sdl2-compat (zlib license), Copyright (C) 1997-2025 Sam Lantinga.
- Capstone disassembler (BSD 3-clause), used by the first-run build (players image only).
- Community HD textures (NFSU2 PC mods, mapped onto the Xbox textures), with thanks to their authors:
  instanity (Remastered Underground 2), Awesome Mods (Redux HD Textures, Next-Gen Textures,
  8K Realistic Night Skyboxes), QTmodz (Project Revitalized);
  nexusmods.com/needforspeedunderground2. Authors may ask for removal: we remove within 24 hours.
Need for Speed Underground 2 is a trademark of Electronic Arts; this port contains no game data.
TXT
cp "$APP/Contents/Resources/THIRD_PARTY_NOTICES.txt" "$STAGE/Third-party notices.txt"
codesign --force --deep -s - "$APP" >/dev/null 2>&1 || echo "warning: ad-hoc signing failed"
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/Read me first.txt" <<'TXT'
NFS Underground 2 for Mac (unofficial port, not signed by Apple). Apple Silicon, macOS 26 or later.

1. Drag NFSU2.app to Applications.
2. First open: right-click NFSU2.app -> Open -> Open (the app is not signed by Apple).
3. Choose your own Need for Speed Underground 2 disc image (Xbox, .iso, USA).
4. Apple Command Line Tools are needed: if they are missing, the system dialog opens - click
   Install. The game is then built from your disc on this Mac (a few minutes, a progress window)
   and NFSU2.app is put on the Desktop. Game data and game code come only from your disc.
5. A gamepad is required (Xbox, PlayStation or another MFi controller). The launcher language
   (English / Українська) sets the launcher and all game text; voices stay original (English).

NFS Underground 2 для Mac (неофіційний порт, без підпису Apple). Apple Silicon, macOS 26 і новіші.

1. Перетягніть NFSU2.app у «Applications».
2. Перший запуск: клацніть NFSU2.app правою кнопкою → «Відкрити» → «Відкрити».
3. Оберіть образ свого диска Need for Speed Underground 2 (Xbox, .iso, США).
4. Потрібні Command Line Tools від Apple: якщо їх немає, відкриється системне вікно — натисніть
   «Встановити». Далі гра збирається з вашого диска (кілька хвилин, вікно з прогресом), і готова
   NFSU2.app з'являється на робочому столі.
5. Потрібен геймпад. Мова в лаунчері (English / Українська) — це мова лаунчера й усього тексту гри; озвучка оригінальна (англійська).
TXT
if [[ $MODE == full ]]; then cat > "$STAGE/Read me first.txt" <<'TXT'
NFS Underground 2 for Mac - the full build (game code + disc data). The owner's copy only: never share.
Drag NFSU2.app to Applications or the Desktop; first open: right-click -> Open -> Open. A gamepad is required.
TXT
fi
rm -f "$DMG"
hdiutil create -quiet -fs HFS+ -volname "NFSU2" -srcfolder "$STAGE" -format UDZO "$DMG"
[[ $MODE == players ]] && bash "$ROOT/tests/dmg_no_game_code.sh" "$DMG"
rm -rf "$STAGE"
echo "dmg: $DMG ($(du -h "$DMG" | cut -f1))"
