#!/usr/bin/env python3
"""Static check of the Ukrainian fonts: reads the NFSU2_UA_DUMP=<dir> files a run writes
(font_uk.m: header w,h,n,late; original records; patched records; composed ARGB atlas) and
  - checks every letter of the Ukrainian alphabet (+ the symbols the text uses) has a record,
    whose atlas rect holds ink, shares no pixels with another letter's rect (lookalikes may
    reuse their Latin twin's rect exactly), and whose advance fits the painted glyph;
  - lays out the alphabet and test words with the game's own record fields (u v w h xoff yoff
    adv) into <dir>/<font>.png (2x, nearest) for checking by eye.
usage: font_sheet.py <dump dir>      exit 1 on any problem"""
import os, struct, sys, zlib

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from build_uk import to_game, CYR  # noqa: E402

WORDS = ['Швидка гонка', 'Тип гонки', 'Продовжити', 'Кар\'єра «Ґанок»', 'ЇЖАК їжак Щука щука Ч ч І і',
         'Гараж Налаштування Вихід', 'Quick Race Continue']
LOOK = set('АВЕКМНОРСТХІаеорсухіЇї')


def png(path, w, h, rgba):
    raw = b''.join(b'\0' + bytes(rgba[y * w * 4:(y + 1) * w * 4]) for y in range(h))
    def chunk(t, d):
        return struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d) & 0xffffffff)
    with open(path, 'wb') as f:
        f.write(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 6, 0, 0, 0))
                + chunk(b'IDAT', zlib.compress(raw, 6)) + chunk(b'IEND', b''))


def recs(b, n):
    out = {}
    for i in range(n):
        code, w, h, u, v, z, xo, yo, kc, ki, adv = struct.unpack_from('<HBBHHBbBBHH', b, i * 16)
        out[code] = dict(w=w, h=h, u=u, v=v, xoff=xo, yoff=yo, adv=adv)
    return out


def check(path):
    d = open(path, 'rb').read()
    W, H, n, late = struct.unpack_from('<4I', d)
    orig = recs(d[16:16 + 16 * n], n)
    out = recs(d[16 + 16 * n:16 + 32 * n], n)
    atlas = d[16 + 32 * n:]
    alpha = lambda x, y: atlas[(y * W + x) * 4 + 3]   # ARGB little-endian: A is byte 3
    name = os.path.basename(path)[:-5]
    bad = []
    chars = list(CYR) + list('«»')
    owner = {}
    for ch in chars:
        bs = to_game(ch)
        code = bs[0] if bs else None
        r = out.get(code)
        if r is None:
            bad.append('%s: no record' % ch); continue
        if r['w'] == 0 or r['h'] == 0:
            bad.append('%s: empty rect' % ch); continue
        ink = sum(alpha(x, y) > 0x40 for y in range(r['v'], r['v'] + r['h']) for x in range(r['u'], r['u'] + r['w']))
        if ink < 3:
            bad.append('%s: rect %d,%d %dx%d has no ink' % (ch, r['u'], r['v'], r['w'], r['h']))
        # inked columns -> painted width; the advance must cover it (minus italic overhang)
        cols = [x for x in range(r['u'], r['u'] + r['w'])
                if any(alpha(x, y) > 0x40 for y in range(r['v'], r['v'] + r['h']))]
        pw = (max(cols) - min(cols) + 1) if cols else 0
        if pw and not (pw * 0.55 <= r['adv'] <= pw * 1.6 + 4):
            bad.append('%s: advance %d vs painted width %d' % (ch, r['adv'], pw))
        key = (r['u'], r['v'], r['w'], r['h'])
        for (u, v, w, h), other in owner.items():
            if other == ch:
                continue
            if (u, v, w, h) == key and not (ch in LOOK or other in LOOK):
                bad.append('%s and %s share a rect' % (ch, other))
            elif (u, v, w, h) != key and u < key[0] + key[2] and key[0] < u + w and v < key[1] + key[3] and key[1] < v + h:
                bad.append('%s overlaps %s' % (ch, other))
        owner.setdefault(key, ch)
    # sheet: alphabet + test words laid out as the game does
    S = 2
    lines = [''.join(chars[:33]), ''.join(chars[33:66]), ''.join(chars[66:])] + WORDS
    lh = max(r['yoff'] + r['h'] for r in out.values() if r['h']) + 4
    def layout(s):
        x, items = 2, []
        for c in to_game(s):
            r = out.get(c)
            if r is None:
                x += 8; continue
            items.append((x + r['xoff'], r)); x += r['adv']
        return x + 2, items
    width = max(layout(s)[0] for s in lines)
    sw, sh = width * S, lh * len(lines) * S
    img = bytearray(b'\x20\x20\x28\xff' * (sw * sh))
    for li, s in enumerate(lines):
        _, items = layout(s)
        for gx, r in items:
            for y in range(r['h']):
                for x in range(r['w']):
                    a = alpha(r['u'] + x, r['v'] + y)
                    if not a:
                        continue
                    for yy in range(S):
                        for xx in range(S):
                            px, py = (gx + x) * S + xx, (li * lh + r['yoff'] + y + 2) * S + yy
                            if 0 <= px < sw and 0 <= py < sh:
                                o = (py * sw + px) * 4
                                for k in range(3):
                                    img[o + k] = max(img[o + k], a)
    png(os.path.join(os.path.dirname(path), name + '.png'), sw, sh, img)
    print('%s: %ux%u atlas, %u records%s, %d problems' % (name, W, H, n, ' (late)' if late else '', len(bad)))
    for b in bad[:30]:
        print('  ', b)
    return len(bad)


if __name__ == '__main__':
    dd = sys.argv[1]
    fs = sorted(f for f in os.listdir(dd) if f.endswith('.font'))
    if not fs:
        print('no .font dumps in', dd); sys.exit(1)
    sys.exit(1 if sum(check(os.path.join(dd, f)) for f in fs) else 0)
