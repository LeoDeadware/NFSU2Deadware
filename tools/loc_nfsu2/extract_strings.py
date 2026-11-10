#!/usr/bin/env python3
"""Dump NFSU2 language chunks (0x00039000) from a ZZDATA pack: hash -> text (Latin-1).
usage: extract_strings.py ZZDATA2.BIN out_dir"""
import struct, sys, os, json
pack, out = sys.argv[1], sys.argv[2]
d = open(pack, 'rb').read()
os.makedirs(out, exist_ok=True)
tables = []
for off in range(0, len(d) - 32, 0x800):
    if struct.unpack_from('<I', d, off)[0] != 0x39000: continue
    size = struct.unpack_from('<I', d, off + 4)[0]
    b = off + 8
    hdr, count, tab, pool = struct.unpack_from('<4I', d, b)
    if hdr != 0x10 or not count: continue
    rows = []
    for k in range(count):
        h, o = struct.unpack_from('<II', d, b + tab + 8 * k)
        s = d[b + pool + o: d.index(b'\0', b + pool + o)]
        rows.append((h, s.decode('latin-1')))
    tables.append((off, size, rows))
    print(hex(off), size, count, repr(next((s for h, s in rows if h == 0x45A6A9CE), ''))[:60])
for off, size, rows in tables:
    if any(h == 0x45A6A9CE and s == 'Please press START to begin' for h, s in rows):
        with open(os.path.join(out, 'en.tsv'), 'w', encoding='utf-8') as f:
            for h, s in rows:
                f.write('%08X\t%s\n' % (h, s.replace('\\', '\\\\').replace('\n', '\\n').replace('\t', '\\t')))
        print('english at', hex(off), len(rows)); break
