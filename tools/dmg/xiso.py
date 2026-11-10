"""Xbox XDVDFS image (XISO or a full Redump image) listing and extraction.
From HP2Port tools/xiso_extract.py; streams files (never whole-file in RAM)."""
import os
import struct

SECTOR = 2048
MAGIC = b"MICROSOFT*XBOX*MEDIA"
# XISO: game partition at 0; Redump full image: 0x18300000 (others: older dumps).
PARTITION_OFFSETS = (0, 0x18300000, 0x0FD90000, 0x02080000)
ATTR_DIR = 0x10


def find_partition(f):
    for base in PARTITION_OFFSETS:
        f.seek(base + 32 * SECTOR)
        if f.read(len(MAGIC)) == MAGIC:
            return base
    raise ValueError("not an XDVDFS image")


def _walk(f, base, sector, size, prefix, out):
    f.seek(base + sector * SECTOR)
    table = f.read(size)

    def node(off):
        if off + 14 > len(table):
            return
        left, right, start, length, attr, nlen = struct.unpack_from("<HHIIBB", table, off)
        if left == 0xFFFF and right == 0xFFFF:
            return
        name = table[off + 14:off + 14 + nlen].decode("latin-1")
        path = f"{prefix}/{name}" if prefix else name
        if left:
            node(left * 4)
        if attr & ATTR_DIR:
            out.append((path, None, None))
            if length:
                _walk(f, base, start, length, path, out)
        else:
            out.append((path, start, length))
        if right:
            node(right * 4)

    if size:
        node(0)


def entries(image):
    """[(path, start_sector|None for dirs, length|None)], partition base."""
    with open(image, "rb") as f:
        base = find_partition(f)
        f.seek(base + 32 * SECTOR + len(MAGIC))
        root_sector, root_size = struct.unpack("<II", f.read(8))
        out = []
        _walk(f, base, root_sector, root_size, "", out)
    return out, base


def extract(image, dest, log=print):
    ents, base = entries(image)
    total = 0
    with open(image, "rb") as f:
        for path, start, length in ents:
            target = os.path.join(dest, path)
            if start is None:
                os.makedirs(target, exist_ok=True)
                continue
            os.makedirs(os.path.dirname(target), exist_ok=True)
            if os.path.exists(target) and os.path.getsize(target) == length:
                total += length
                continue  # resumable: already extracted
            f.seek(base + start * SECTOR)
            with open(target + ".part", "wb") as o:
                left = length
                while left:
                    chunk = f.read(min(left, 1 << 20))
                    if not chunk:
                        raise IOError(f"short read in {path}")
                    o.write(chunk)
                    left -= len(chunk)
            os.replace(target + ".part", target)
            total += length
    log(f"extracted {len(ents)} entries, {total / 2**20:.1f} MiB, partition at {base:#x} -> {dest}")
    return ents
