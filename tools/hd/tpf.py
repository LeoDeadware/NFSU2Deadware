#!/usr/bin/env python3
"""tpf.py PACK.tpf OUT_DIR  -- unpacks a TexMod/uMod .tpf (community texture pack) with the stdlib only.

A .tpf is a ZIP whose bytes are XOR-ed with 0x3FA43FA4 (per little-endian 32-bit word, the tail
bytes with 0xA4) and whose entries use ZipCrypto with TexMod's fixed password. Inside:
texmod.def ("0x<PC CRC32>|<file>" per line) and the textures (.dds, sometimes .png/.bmp/.tga).
The PC CRC is a hash of the PC Direct3D texture data: it does not exist on the Xbox, so
tools/hd/tpfmatch.swift maps the textures onto our Xbox dumps by content.

Downloaded packs are untrusted data: run as `python3 -I tools/hd/tpf.py <pack> <empty dir>`;
names are sanitised (no paths, no ..), nothing in the pack is executed.
Also accepts a plain .zip or an already decoded ZIP (no XOR). Writes OUT_DIR/texmod.def and
OUT_DIR/files/<n>_<name>; prints counts. --password-hex overrides the built-in password.
"""
import argparse
import os
import re
import struct
import sys
import zipfile
import zlib
import io

XOR = 0x3FA43FA4
# TexMod's ZIP password (the same in TexMod, OpenTexMod and uMod: uMod_File.cpp)
PASSWORD = bytes([0x73, 0x2A, 0x63, 0x7D, 0x5F, 0x0A, 0xA6, 0xBD, 0x7D, 0x65, 0x7E, 0x67, 0x61, 0x2A,
                  0x7F, 0x7F, 0x74, 0x61, 0x67, 0x5B, 0x60, 0x70, 0x45, 0x74, 0x5C, 0x22, 0x74, 0x5D,
                  0x6E, 0x6A, 0x73, 0x41, 0x77, 0x6E, 0x46, 0x47, 0x77, 0x49, 0x0C, 0x4B, 0x46, 0x6F])
SAFE = re.compile(r"[^A-Za-z0-9._-]")


def unxor(b):
    n = len(b) // 4
    words = struct.unpack_from("<%dI" % n, b)
    out = bytearray(struct.pack("<%dI" % n, *[w ^ XOR for w in words]))
    out += bytes(c ^ (XOR & 0xFF) for c in b[n * 4:])
    return bytes(out)


# ── ZipCrypto (PKWARE traditional encryption), for archives whose central directory is damaged ──
CRC = [0] * 256
for i in range(256):
    c = i
    for _ in range(8):
        c = (c >> 1) ^ 0xEDB88320 if c & 1 else c >> 1
    CRC[i] = c


class ZipCrypto:
    def __init__(self, pw):
        self.k = [0x12345678, 0x23456789, 0x34567890]
        for ch in pw:
            self.upd(ch)

    def upd(self, ch):
        k = self.k
        k[0] = (k[0] >> 8) ^ CRC[(k[0] ^ ch) & 0xFF]
        k[1] = ((k[1] + (k[0] & 0xFF)) * 134775813 + 1) & 0xFFFFFFFF
        k[2] = (k[2] >> 8) ^ CRC[(k[2] ^ (k[1] >> 24)) & 0xFF]

    def dec(self, data):
        out = bytearray(len(data))
        for i, c in enumerate(data):
            t = (self.k[2] | 2) & 0xFFFF
            p = c ^ (((t * (t ^ 1)) >> 8) & 0xFF)
            self.upd(p)
            out[i] = p
        return bytes(out)


def scan_local(z, pw):
    """Walks the local file headers (PK\\3\\4) when zipfile cannot read the central directory."""
    pos = 0
    while True:
        pos = z.find(b"PK\x03\x04", pos)
        if pos < 0 or pos + 30 > len(z):
            return
        (_, _, flag, meth, _, _, crc, csize, usize, nlen, xlen) = struct.unpack_from("<IHHHHHIIIHH", z, pos)
        name = z[pos + 30:pos + 30 + nlen].decode("cp437", "replace")
        start = pos + 30 + nlen + xlen
        if flag & 8 or csize == 0:      # sizes in a data descriptor: up to the next header
            nxt = z.find(b"PK\x03\x04", start)
            end = nxt if nxt >= 0 else len(z)
            m = z.rfind(b"PK\x07\x08", start, end)
            if m >= 0:
                crc, csize, usize = struct.unpack_from("<III", z, m + 4)
                end = m
            data = z[start:end]
        else:
            data = z[start:start + csize]
        if flag & 1:
            zc = ZipCrypto(pw)
            data = zc.dec(data)[12:]
        try:
            raw = zlib.decompress(data, -15) if meth == 8 else data if meth == 0 else None
        except zlib.error:
            raw = None
        if raw is not None and (zlib.crc32(raw) & 0xFFFFFFFF) != crc and crc:
            raw = None
        yield name, raw
        pos = start + max(len(data), 1)


def entries(blob, pw):
    for cand in (unxor(blob), blob):
        try:
            zf = zipfile.ZipFile(io.BytesIO(cand))
            zf.setpassword(pw)
            out = []
            for info in zf.infolist():
                if info.is_dir():
                    continue
                try:
                    out.append((info.filename, zf.read(info)))
                except (RuntimeError, zipfile.BadZipFile, zlib.error):
                    out.append((info.filename, None))
            if out and any(d is not None for _, d in out):
                return out, "zip" if cand is blob else "tpf"
        except zipfile.BadZipFile:
            pass
    for cand, kind in ((unxor(blob), "tpf-scan"), (blob, "zip-scan")):
        out = list(scan_local(cand, pw))
        if out and any(d is not None for _, d in out):
            return out, kind
    return [], "unknown"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("pack")
    ap.add_argument("out")
    ap.add_argument("--password-hex")
    a = ap.parse_args()
    pw = bytes.fromhex(a.password_hex) if a.password_hex else PASSWORD
    if os.path.exists(a.out) and os.listdir(a.out):
        sys.exit("tpf: %s is not empty" % a.out)
    os.makedirs(os.path.join(a.out, "files"), exist_ok=True)
    blob = open(a.pack, "rb").read()
    items, kind = entries(blob, pw)
    if not items:
        sys.exit("tpf: no readable entries (not a TexMod pack, or another password: --password-hex)")
    ok = bad = 0
    defs = []
    for i, (name, data) in enumerate(items):
        base = SAFE.sub("_", name.replace("\\", "/").split("/")[-1])[:120] or "entry"
        if data is None:
            bad += 1
            continue
        if base.lower() == "texmod.def":
            defs.append(data.decode("latin-1"))
            continue
        with open(os.path.join(a.out, "files", "%05d_%s" % (i, base)), "wb") as f:
            f.write(data)
        ok += 1
    # texmod.def names refer to the archive names: rewrite them to the files we wrote
    names = {SAFE.sub("_", n.replace("\\", "/").split("/")[-1])[:120]: "%05d_%s" % (i, SAFE.sub("_", n.replace("\\", "/").split("/")[-1])[:120])
             for i, (n, _) in enumerate(items)}
    lines = []
    for d in defs:
        for ln in d.splitlines():
            if "|" not in ln:
                continue
            crc, fn = ln.split("|", 1)
            fn = SAFE.sub("_", fn.strip().replace("\\", "/").split("/")[-1])[:120]
            lines.append("%s\t%s" % (crc.strip(), names.get(fn, fn)))
    with open(os.path.join(a.out, "texmod.def"), "w") as f:
        f.write("# pc_crc\tfile\n" + "\n".join(lines) + "\n")
    print("tpf: %s, %d files, %d unreadable, %d texmod.def lines -> %s" % (kind, ok, bad, len(lines), a.out))


if __name__ == "__main__":
    main()
