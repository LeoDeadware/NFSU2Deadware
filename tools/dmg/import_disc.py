#!/usr/bin/env python3
"""First-run import for an NFSU2.app without game data (the DMG build, tools/make_dmg.sh).

    python3 -I import_disc.py <disc.iso> <data dir>

Extracts the player's own disc image into <data>/game/extracted (XDVDFS, XboxPortKit xiso.py) and
checks default.xbe: the port is lifted from the NTSC-U executable (SHA-1 below), so another
executable cannot run with our runtime objects. Another edition of NFSU2 (Europe/PAL, Japan: title ID
0x4541005A with a different executable) exits 5 = "not tested": no image of it was available to check, and it
would need its own lift (community tools/regen_pal.sh). Exit 4 = not NFSU2 at all.
Nothing of the game is in the DMG; everything here comes from the player's disc.
"""
import hashlib
import os
import shutil
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import xiso  # noqa: E402

XBE_SHA1 = "428b5a70b9400f19cc5be7679db6c72a6f80a1c9"   # Need for Speed Underground 2 (USA), default.xbe
TITLE_ID = 0x4541005A                                      # NFSU2, every edition
REGIONS = {1: "USA", 2: "Japan", 4: "Europe/PAL"}


def certificate(data):
    """(title ID, region name) from the XBE certificate, or (None, None)."""
    try:
        base, cert = struct.unpack_from("<II", data, 0x104)[0], struct.unpack_from("<I", data, 0x118)[0]
        o = cert - base
        tid, = struct.unpack_from("<I", data, o + 8)
        reg, = struct.unpack_from("<I", data, o + 0xA0)
    except struct.error:
        return None, None
    names = [n for bit, n in REGIONS.items() if reg & bit]
    return tid, "+".join(names) or f"region {reg:#x}"


def main():
    iso, data = sys.argv[1], sys.argv[2]
    dest = os.path.join(data, "game", "extracted")
    tmp = dest + ".tmp"
    shutil.rmtree(tmp, ignore_errors=True)
    os.makedirs(tmp)
    print(f"import: extracting {iso} -> {dest}", flush=True)
    xiso.extract(iso, tmp, log=lambda *a: None)
    xbe = os.path.join(tmp, "default.xbe")
    if not os.path.isfile(xbe):
        print("import: no default.xbe on this disc: not an Xbox game?", flush=True)
        return 3
    with open(xbe, "rb") as f:
        data = f.read()
    sha = hashlib.sha1(data).hexdigest()
    if sha != XBE_SHA1:
        shutil.rmtree(tmp, ignore_errors=True)
        tid, region = certificate(data)
        if tid == TITLE_ID:
            print(f"import: default.xbe {sha}: Need for Speed Underground 2 ({region}): not tested", flush=True)
            return 5
        print(f"import: default.xbe {sha}: not Need for Speed Underground 2 (USA)", flush=True)
        return 4
    shutil.rmtree(dest, ignore_errors=True)
    os.rename(tmp, dest)
    print("import: done", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
