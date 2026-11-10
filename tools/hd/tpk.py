#!/usr/bin/env python3
"""tpk.py PACK.BIN OUT_DIR  -- extracts the textures of an NFSU2 PC texture pack (TPK, e.g. a mod's
TRACKS/LOC4DYNTEX.BIN) as .dds files (top mip level only), for tools/hd/tpfmatch.swift.

Chunks are (u32 id, u32 size); B3300000 = TPK, inside B3310000 (header: 33310001 name, 33310002 hash
table, 33310003 compressed blocks or 33310004 texture infos) and B3320000 (33320002 data).
Compressed packs (NFS-TexEd): each 33310003 entry (24 bytes: hash, file offset, packed size, size,
flags, 0) points to a JDLZ block = texture data followed by its texture info. The texture info (as in
the uncompressed 33310004 list): name[24] at +0x0C, hash +0x24, data offset +0x2C, data size +0x34,
width/height u16 +0x44/+0x46, FourCC (or D3DFORMAT) in the trailing compression record.

Downloaded mods are untrusted data: run as `python3 -I tools/hd/tpk.py <bin> <empty dir>`; only
parses bytes, names are sanitised. Writes OUT_DIR/<n>_<name>.dds and prints counts.
"""
import os
import re
import struct
import sys

SAFE = re.compile(r"[^A-Za-z0-9._-]")


def jdlz(inp):
    if inp[:4] != b"JDLZ":
        raise ValueError("not JDLZ")
    usize = struct.unpack_from("<I", inp, 8)[0]
    out = bytearray(usize)
    f1 = f2 = 1
    i, o = 16, 0
    n_in = len(inp)
    while i < n_in and o < usize:
        if f1 == 1:
            f1 = inp[i] | 0x100
            i += 1
        if f2 == 1:
            f2 = inp[i] | 0x100
            i += 1
        if f1 & 1:
            if f2 & 1:
                n = (inp[i + 1] | ((inp[i] & 0xF0) << 4)) + 3
                t = (inp[i] & 0x0F) + 1
            else:
                t = (inp[i + 1] | ((inp[i] & 0xE0) << 3)) + 17
                n = (inp[i] & 0x1F) + 3
            i += 2
            n = min(n, usize - o)
            if t >= n:
                out[o:o + n] = out[o - t:o - t + n]
                o += n
            else:
                for _ in range(n):
                    out[o] = out[o - t]
                    o += 1
            f2 >>= 1
        else:
            out[o] = inp[i]
            o += 1
            i += 1
        f1 >>= 1
    return bytes(out)


def chunks(b, o, end):
    while o + 8 <= end:
        cid, size = struct.unpack_from("<II", b, o)
        yield cid, o + 8, min(o + 8 + size, end)
        o += 8 + size


def dds(w, h, fmt, data):
    """DDS file for DXT1/3/5 (FourCC) or 32-bit A8R8G8B8 (D3DFORMAT 21)."""
    if fmt in (b"DXT1", b"DXT3", b"DXT5"):
        bs = 8 if fmt == b"DXT1" else 16
        size = max(1, (w + 3) // 4) * max(1, (h + 3) // 4) * bs
        pf = struct.pack("<II4sIIIII", 32, 4, fmt, 0, 0, 0, 0, 0)
    elif fmt in (struct.pack("<I", 21), b"\x15\x00\x00\x00"):
        size = w * h * 4
        pf = struct.pack("<II4sIIIII", 32, 0x41, b"\0\0\0\0", 32, 0xFF0000, 0xFF00, 0xFF, 0xFF000000)
    else:
        return None
    if len(data) < size:
        return None
    hdr = struct.pack("<4sIIIIIII", b"DDS ", 124, 0x1007, h, w, size, 0, 1) + b"\0" * 44 + pf + \
        struct.pack("<IIIII", 0x1000, 0, 0, 0, 0)
    return hdr + data[:size]


def info(rec):
    """Texture info record (0x7C+ bytes) -> name, data offset, size, w, h."""
    name = rec[0x0C:0x24].split(b"\0")[0].decode("latin-1")
    off, size = struct.unpack_from("<I", rec, 0x2C)[0], struct.unpack_from("<I", rec, 0x34)[0]
    w, h = struct.unpack_from("<HH", rec, 0x44)
    return name, off, size, w, h


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    src, out = sys.argv[1], sys.argv[2]
    if os.path.exists(out) and os.listdir(out):
        sys.exit("tpk: %s is not empty" % out)
    os.makedirs(out, exist_ok=True)
    b = open(src, "rb").read()
    ok = skip = 0
    n = 0

    def write(name, w, h, fmt, data):
        nonlocal ok, skip, n
        d = dds(w, h, fmt, data) if 0 < w <= 8192 and 0 < h <= 8192 else None
        n += 1
        if d is None:
            skip += 1
            return
        with open(os.path.join(out, "%05d_%s.dds" % (n, SAFE.sub("_", name)[:100] or "tex")), "wb") as f:
            f.write(d)
        ok += 1

    for cid, s, e in chunks(b, 0, len(b)):
        if cid != 0xB3300000:
            continue
        infos, fmts, data, comp = [], [], None, []
        for c2, s2, e2 in chunks(b, s, e):
            if c2 == 0xB3310000:
                for c3, s3, e3 in chunks(b, s2, e2):
                    if c3 == 0x33310003:
                        comp = [struct.unpack_from("<IIII", b, p) for p in range(s3, e3 - 23, 24)]
                    elif c3 == 0x33310004:
                        infos = [b[p:p + 0x7C] for p in range(s3, e3 - 0x7B, 0x7C)]
                    elif c3 == 0x33310005:
                        fmts = [b[p + 0x0C:p + 0x10] for p in range(s3, e3 - 0x1F, 0x20)]
            elif c2 == 0xB3320000:
                for c3, s3, e3 in chunks(b, s2, e2):
                    if c3 == 0x33320002:
                        data = (s3, e3)
        for _, off, csize, usize in comp:
            try:
                blk = jdlz(b[off:off + csize])
            except (ValueError, IndexError):
                skip += 1
                continue
            # texture info + compression record (FourCC 12 bytes from the end) at the block's tail
            rec = blk[-156:]
            fmt = blk[-12:-8]
            name, doff, dsize, w, h = info(rec)
            write(name, w, h, fmt, blk[doff:doff + dsize])
        if infos and data:
            base = data[0]
            while base < data[1] and b[base] == 0x11:   # alignment padding
                base += 1
            for k, rec in enumerate(infos):
                name, doff, dsize, w, h = info(rec)
                fmt = fmts[k] if k < len(fmts) else b""
                write(name, w, h, fmt, b[base + doff:base + doff + dsize])
    print("tpk: %d textures, %d skipped -> %s" % (ok, skip, out))


if __name__ == "__main__":
    main()
