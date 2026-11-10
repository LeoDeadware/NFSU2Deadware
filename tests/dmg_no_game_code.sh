#!/bin/bash
# The players' DMG carries only our tools and runtime, never game code or game data:
#   tests/dmg_no_game_code.sh [out/dmg/NFSU2-players.dmg]
# 1. no lifted code: no gen/recomp_*.c(.o); no Mach-O/archive defining more sub_XXXXXXXX functions
#    than the hand-written overrides of src/recomp_manual.c (31 on 2026-11-06); no nfsu2-bin;
# 2. no disc file: no file with the sha1 of a game/extracted file, no XBE image, no 64-byte window
#    of default.xbe's code (96 samples) in any file;
# 3. no /Users/ path in any file (build paths, home paths).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DMG="${1:-$ROOT/out/dmg/NFSU2-players.dmg}"
[[ -f "$DMG" ]] || { echo "dmg_no_game_code: no $DMG (tools/make_dmg.sh players)"; exit 2; }
mkdir -p "$ROOT/.cache/tmp"; MNT="$(mktemp -d "$ROOT/.cache/tmp/dmgscan.XXXX")"
hdiutil attach -nobrowse -readonly -mountpoint "$MNT" "$DMG" >/dev/null || { echo "dmg_no_game_code: FAIL cannot mount"; exit 1; }
MANUAL=$(grep -cE '^[a-zA-Z].*\bsub_[0-9A-Fa-f]{8}\(' "$ROOT/community/src/recomp_manual.c")
python3 -I - "$MNT" "$ROOT/game/extracted" "$MANUAL" <<'PY'
import hashlib, os, re, subprocess, sys
root, disc, manual = sys.argv[1], sys.argv[2], int(sys.argv[3])
bad, disc_sha = [], set()
for d, _, fs in os.walk(disc):
    for f in fs:
        p = os.path.join(d, f)
        if os.path.getsize(p) >= 256:
            disc_sha.add(hashlib.sha1(open(p, 'rb').read()).hexdigest())
xbe = open(os.path.join(disc, 'default.xbe'), 'rb').read()
step = (len(xbe) - 0x20000) // 96
wins = [w for w in (xbe[0x10000 + i * step:0x10000 + i * step + 64] for i in range(96)) if len(set(w)) > 16]
files = 0
for d, _, fs in os.walk(root):
    for f in fs:
        p = os.path.join(d, f)
        if os.path.islink(p) or not os.path.isfile(p):
            continue
        files += 1
        rel = os.path.relpath(p, root)
        if re.fullmatch(r'recomp_\d+\.c(\.o)?|recomp_dispatch\.c(\.o)?|nfsu2-bin', f):
            bad.append(f'{rel}: lifted code file')
        b = open(p, 'rb').read()
        if b[:4] == b'XBEH':
            bad.append(f'{rel}: XBE image')
        if len(b) >= 256 and hashlib.sha1(b).hexdigest() in disc_sha:
            bad.append(f'{rel}: a file of the disc')
        hits = sum(1 for w in wins if w in b)
        if hits >= 2:
            bad.append(f'{rel}: {hits} windows of default.xbe code')
        if b'/Users/' in b:
            i = b.index(b'/Users/')
            bad.append(f'{rel}: a /Users/ path ({b[i:i + 60].split(bytes(1))[0].decode("latin-1")})')
        if b[:4] in (b'\xcf\xfa\xed\xfe', b'\xca\xfe\xba\xbe') or b[:8] == b'!<arch>\n':
            nm = subprocess.run(['nm', '-gU', p], capture_output=True, text=True).stdout
            n = len(re.findall(r' [TtSD] _sub_[0-9A-Fa-f]{8}\b', nm))
            if n > manual:
                bad.append(f'{rel}: {n} lifted functions (manual overrides: {manual})')
for x in bad[:20]:
    print('  ' + x)
print(f'dmg_no_game_code: {"FAIL" if bad else "PASS"} ({files} files, {len(bad)} problems)')
sys.exit(1 if bad else 0)
PY
rc=$?
hdiutil detach -quiet "$MNT"; rmdir "$MNT" 2>/dev/null
exit $rc
