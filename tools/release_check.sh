#!/bin/bash
# Release gate (RULES R-L1/R-L2): a .app/.dmg/zip for anyone but the owner must contain NO
# game data and nothing derived from it (packs, voice, flat images, Ghidra exports).
#   tools/release_check.sh path/to/NFSU2.app|.dmg|.zip
set -uo pipefail
t="$1"; tmp=""
case "$t" in
  *.dmg) tmp="$(mktemp -d)"; hdiutil attach -nobrowse -readonly -mountpoint "$tmp" "$t" >/dev/null || exit 2; root="$tmp" ;;
  *.zip) tmp="$(mktemp -d)"; unzip -q "$t" -d "$tmp"; root="$tmp" ;;
  *) root="$t" ;;
esac
bad="$(find "$root" \( -iname '*.xbe' -o -iname '*.iso' -o -iname '*.xiso' -o -iname 'default.flat*' \
  -o -path '*/game/extracted/*' -o -path '*/mods/hd_*' -o -path '*/voice/*' -o -iname '*.gpr' \) -print 2>/dev/null | head -20)"
[[ "$t" == *.dmg ]] && hdiutil detach -quiet "$tmp"
[[ -n "$tmp" && "$t" == *.zip ]] && rm -rf "$tmp"
if [[ -n "$bad" ]]; then echo "release_check: FAIL — game data / derived content:"; echo "$bad"; exit 1; fi
echo "release_check: PASS (no game data found in $t)"
