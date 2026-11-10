#!/usr/bin/env python3
"""List NFSU2 font chunks (0x00030201, FNTX) in a pack: name, glyphs, metrics extent.
usage: fonts.py PACK [dump_name]"""
import struct, sys
d = open(sys.argv[1], 'rb').read()
want = sys.argv[2] if len(sys.argv) > 2 else None
i = 0
while True:
    i = d.find(b'FNTX', i)
    if i < 0: break
    c = i - 0x208
    if c < 0 or struct.unpack_from('<I', d, c)[0] != 0x30201:
        i += 4; continue
    name = d[c + 8:c + 8 + 0x40].split(b'\0')[0].decode('latin-1')
    f = i
    tot = struct.unpack_from('<I', d, f + 4)[0]
    h = struct.unpack_from('<4H', d, f + 8)
    gt, kt, tx = struct.unpack_from('<3I', d, f + 0x14)
    n = h[1]
    mu = mv = 0; recs = []
    for k in range(n):
        r = struct.unpack_from('<HBBHHBbBBHH', d, f + gt + 16 * k)
        recs.append(r)
        mu = max(mu, r[3] + r[1]); mv = max(mv, r[4] + r[2])
    print('%08x %-28s glyphs %3d hdr %s ext %dx%d tot %x gt %x kt %x tx %x' % (c, name, n, h, mu, mv, tot, gt, kt, tx))
    if want and want == name:
        print(' '.join('%02x' % b for b in d[f:f + 0x80]))
        for r in recs: print(r)
    i += 4
