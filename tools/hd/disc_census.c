/* disc_census.c: offline texture census of NFSU2's Xbox disc (tools/hd/disc_census.py builds and
 * runs it). Scans EA chunk files (ZZDATA*.BIN) for texture packs, rebuilds each pack's data area
 * as the game holds it in memory, hashes every texture the way the Metal back end does
 * (community/xboxrecomp/src/nv2a_metal/nv2a_metal.m tex_replace: FNV-1a 64 over tex_bytes() of
 * the top level, + the 1024-byte palette for 0x0B) and writes the decoded picture as the runtime
 * census does (NFSU2_TEX_DUMP: A8R8G8B8 decode, straight alpha) to OUT/<hash>_<fmt>_<w>x<h>.png
 * (the .py adds the ui|world kind). Index rows on stdout.
 *
 *   disc_census OUT_DIR FILE...
 *
 * TPK = chunk B3300000 { [0 pad] B3310000 { 33310001 header (u32 version, name[28], path[64],
 * hash), 33310002 hash table, 33310003 compressed entries | 33310004 infos (0x7C) + 33310005
 * format records (0x3C) }, [0 pad], B3320000 { 33320001, [0], 33320002 data (0x11 pad to 0x80) } }.
 * Info (Xbox): name[24] +0x0C, hash +0x24, data offset +0x30, palette offset +0x34, data size
 * +0x38, palette size +0x3C, w/h u16 +0x44/+0x46; format record: NV2A colour format u32 +0x0C.
 * Compressed entry (24 bytes: hash, offset from the B3300000 chunk, packed size, size, flags, 0)
 * -> a JDLZ or HUFF block = texture data + info + format record (0xB8 at the tail); the data goes
 * to the info's data offset in the rebuilt area.
 *
 * Our own code (JDLZ as tools/hd/tpk.py; HUFF = EA's Huffman/run-length codec 30FB..35FB, written
 * from its format). Reads game data only; writes only under OUT_DIR. */
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
#include <zlib.h>

static const char *g_out;
static long g_stats[24];
static uint64_t g_abase;   /* data-area offset of area[0] */
#define VM_SIZE (0x100000000ull + (64ull << 20))
static uint8_t *g_vm;      /* sparse data area for compressed packs */
static void vm_reset(uint64_t lo, uint64_t hi)
{
    uint64_t a = lo & ~0x3FFFull, e = (hi + 0x3FFF) & ~0x3FFFull;
    if (mmap(g_vm + a, e - a, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON | MAP_FIXED, -1, 0) == MAP_FAILED) { perror("mmap"); exit(1); }
}
enum { S_TPK, S_TEX, S_NODATA, S_BADBLK, S_PNG, S_DUP, S_LINEAR, S_PARTIAL, S_UNK, S_COMPTPK, S_BADOFF, S_BADJ, S_BADH, S_BADT, S_NOPAL, S_OWN };

static uint32_t rd32(const uint8_t *p) { return p[0] | p[1] << 8 | p[2] << 16 | (uint32_t)p[3] << 24; }
static uint16_t rd16(const uint8_t *p) { return (uint16_t)(p[0] | p[1] << 8); }

/* ---- JDLZ (as tools/hd/tpk.py) ---- */
static uint8_t *jdlz(const uint8_t *in, size_t n, uint32_t *outlen)
{
    uint32_t usize, f1 = 1, f2 = 1, o = 0;
    size_t i = 16;
    uint8_t *out;
    if (n < 16 || memcmp(in, "JDLZ", 4))
        return NULL;
    usize = rd32(in + 8);
    if (usize > (64u << 20) || !(out = calloc(1, usize ? usize : 1)))
        return NULL;
    while (i < n && o < usize) {
        if (f1 == 1) { if (i >= n) break; f1 = in[i++] | 0x100; }
        if (f2 == 1) { if (i >= n) break; f2 = in[i++] | 0x100; }
        if (f1 & 1) {
            uint32_t len, t;
            if (i + 1 >= n) break;
            if (f2 & 1) {
                len = (in[i + 1] | ((in[i] & 0xF0) << 4)) + 3;
                t = (in[i] & 0x0F) + 1;
            } else {
                t = (in[i + 1] | ((in[i] & 0xE0) << 3)) + 17;
                len = (in[i] & 0x1F) + 3;
            }
            i += 2;
            if (len > usize - o) len = usize - o;
            if (t > o) { free(out); return NULL; }
            while (len--) { out[o] = out[o - t]; o++; }
            f2 >>= 1;
        } else {
            out[o++] = in[i++];
        }
        f1 >>= 1;
    }
    *outlen = usize;
    return out;
}

/* ---- EA HUFF: canonical Huffman + a "clue" symbol for runs / literals; MSB-first bits ---- */
typedef struct { const uint8_t *p; size_t n, bit; } Bits;
static uint32_t bget(Bits *b, int k)
{
    uint32_t v = 0;
    while (k--) {
        size_t byte = b->bit >> 3;
        uint32_t x = byte < b->n ? (b->p[byte] >> (7 - (b->bit & 7))) & 1 : 0;
        v = v << 1 | x;
        b->bit++;
    }
    return v;
}
static uint32_t bpeek(Bits *b, int k) { Bits c = *b; return bget(&c, k); }
static uint32_t bnum(Bits *b)
{
    int n;
    if (bpeek(b, 1))
        return bget(b, 3) - 4;
    if (bpeek(b, 16)) {             /* z zeros then a one: n = z + 2 */
        int z = 0;
        while (!bget(b, 1)) z++;
        n = z + 2;
    } else {                        /* 16+ zeros: the codec's long form counts one more */
        n = 2;
        do n++; while (!bget(b, 1));
    }
    if (n > 30) return 0xFFFFFFFFu;
    return bget(b, n) + (1u << n) - 4;
}
static uint8_t *huff(const uint8_t *in, size_t n, uint32_t *outlen)
{
    Bits b = { in, n, 0 };
    uint32_t type, ulen, clue, start[33], count[33], before[33], numchars = 0, base = 0;
    uint8_t codetbl[256], leap[256];
    uint8_t *out;
    uint32_t o = 0, L, i;
    int most;
    type = bget(&b, 16);
    if ((type & 0xFF) != 0xFB || ((type >> 8) & 0x7F) < 0x30 || ((type >> 8) & 0x7F) > 0x35)
        return NULL;
    if (type & 0x8000) { if (type & 0x100) bget(&b, 32); ulen = bget(&b, 32); }
    else { if (type & 0x100) bget(&b, 24); ulen = bget(&b, 24); }
    type &= ~0x100u;
    if (ulen > (64u << 20)) return NULL;
    clue = bget(&b, 8);
    memset(count, 0, sizeof count);
    for (L = 1;; L++) {
        uint32_t k;
        if (L > 32) return NULL;
        base <<= 1;
        start[L] = base;
        before[L] = numchars;
        k = bnum(&b);
        if (k > 256) return NULL;
        count[L] = k;
        numchars += k;
        base += k;
        if (numchars > 256) return NULL;
        if (k && ((base << (16 - L)) & 0xFFFF) == 0 && L <= 16) break;
        if (L > 16 && k && base >= (1u << L)) break;
    }
    most = (int)L;
    memset(leap, 0, sizeof leap);
    {
        uint8_t next = 0xFF;
        for (i = 0; i < numchars; i++) {
            uint32_t d = bnum(&b) + 1, guard = 0;
            do {
                next++;
                if (!leap[next]) d--;
                if (++guard > 1u << 20) return NULL;
            } while (d);
            leap[next] = 1;
            codetbl[i] = next;
        }
    }
    if (!(out = calloc(1, ulen ? ulen : 1)))
        return NULL;
    while (o < ulen) {
        uint32_t c = 0, sym;
        int l, found = 0;
        if ((b.bit >> 3) > n + 8) break;
        for (l = 1; l <= most; l++) {
            c = c << 1 | bget(&b, 1);
            if (count[l] && c >= start[l] && c < start[l] + count[l]) { found = 1; break; }
        }
        if (!found) break;
        sym = codetbl[before[l] + (c - start[l])];
        if (sym != clue) { out[o++] = (uint8_t)sym; continue; }
        {
            uint32_t run = bnum(&b);
            if (run) {
                uint8_t prev = o ? out[o - 1] : 0;
                if (run > ulen - o) run = ulen - o;
                memset(out + o, prev, run);
                o += run;
                continue;
            }
        }
        if (bget(&b, 1)) break;           /* end of stream */
        out[o++] = (uint8_t)bget(&b, 8);  /* the clue value itself, literally */
    }
    if (type == 0x32FB || type == 0xB2FB) {
        uint8_t acc = 0;
        for (i = 0; i < ulen; i++) { acc += out[i]; out[i] = acc; }
    } else if (type == 0x34FB || type == 0xB4FB) {
        uint8_t acc = 0, nx = 0;
        for (i = 0; i < ulen; i++) { acc += out[i]; nx += acc; out[i] = nx; }
    }
    *outlen = ulen;
    return out;
}

static uint8_t *unpack(const uint8_t *in, size_t n, uint32_t *outlen)
{
    if (n >= 16 && !memcmp(in, "JDLZ", 4)) return jdlz(in, n, outlen);
    if (n >= 16 && !memcmp(in, "HUFF", 4)) return huff(in + 16, n - 16, outlen);
    return NULL;
}

/* ---- textures ---- */
static uint64_t fnv64(const uint8_t *p, size_t n, uint64_t h)
{
    size_t i;
    for (i = 0; i < n; i++) h = (h ^ p[i]) * 0x100000001B3ull;
    return h;
}
static uint32_t tex_bytes(uint32_t c, uint32_t w, uint32_t h)
{
    if (c == 0x0C) return ((w + 3) / 4) * ((h + 3) / 4) * 8;
    if (c == 0x0E || c == 0x0F) return ((w + 3) / 4) * ((h + 3) / 4) * 16;
    return w * h * 4;
}
static uint32_t swz(uint32_t u, uint32_t v, uint32_t w, uint32_t h)
{
    uint32_t out = 0, bit = 0, mw = w - 1, mh = h - 1, m;
    for (m = 1; mw >= m || mh >= m; m <<= 1) {
        if (mw >= m) { if (u & m) out |= 1u << bit; bit++; }
        if (mh >= m) { if (v & m) out |= 1u << bit; bit++; }
    }
    return out;
}
static uint32_t ex(uint32_t v, uint32_t bits) { return v * 255u / ((1u << bits) - 1u); }
static uint32_t bpp_of(uint32_t c)  /* bytes per texel of the swizzled formats we decode, 0 = no */
{
    switch (c) {
    case 0x00: case 0x19: case 0x0B: return 1;
    case 0x02: case 0x03: case 0x04: case 0x05: return 2;
    case 0x06: case 0x07: return 4;
    default: return 0;
    }
}
static void dxt_texel(const uint8_t *base, uint32_t fmt, uint32_t u, uint32_t v, uint32_t w, uint32_t *argb)
{
    uint32_t bb = fmt == 0x0C ? 8 : 16, bpr = (w + 3) / 4, bx = u & 3, by = v & 3, texel = by * 4 + bx;
    uint32_t c[4], idx, alpha = 255, c0, c1, i;
    const uint8_t *b = base + ((size_t)(v >> 2) * bpr + (u >> 2)) * bb;
    if (bb == 16) {
        if (fmt == 0x0E) {
            uint32_t nib = b[texel >> 1];
            alpha = ex((texel & 1) ? (nib >> 4) : (nib & 15), 4);
        } else {
            uint32_t a0 = b[0], a1 = b[1], a[8], sel;
            uint64_t bits = 0;
            for (i = 0; i < 6; i++) bits |= (uint64_t)b[2 + i] << (8 * i);
            a[0] = a0; a[1] = a1;
            if (a0 > a1) for (i = 1; i < 7; i++) a[i + 1] = ((7 - i) * a0 + i * a1) / 7;
            else { for (i = 1; i < 5; i++) a[i + 1] = ((5 - i) * a0 + i * a1) / 5; a[6] = 0; a[7] = 255; }
            sel = (uint32_t)((bits >> (3 * texel)) & 7);
            alpha = a[sel];
        }
        b += 8;
    }
    c0 = b[0] | b[1] << 8;
    c1 = b[2] | b[3] << 8;
    for (i = 0; i < 2; i++) {
        uint32_t rgb = i ? c1 : c0;
        c[i] = ex((rgb >> 11) & 31, 5) << 16 | ex((rgb >> 5) & 63, 6) << 8 | ex(rgb & 31, 5);
    }
    c[2] = c[3] = 0;
    if (c0 > c1 || bb == 16) {
        for (i = 0; i < 3; i++) {
            uint32_t sh = i * 8, m0 = (c[0] >> sh) & 255, m1 = (c[1] >> sh) & 255;
            c[2] |= ((2 * m0 + m1) / 3) << sh;
            c[3] |= ((m0 + 2 * m1) / 3) << sh;
        }
    } else {
        for (i = 0; i < 3; i++) {
            uint32_t sh = i * 8, m0 = (c[0] >> sh) & 255, m1 = (c[1] >> sh) & 255;
            c[2] |= ((m0 + m1) / 2) << sh;
        }
    }
    idx = (rd32(b + 4) >> (2 * texel)) & 3;
    if (bb == 8 && c0 <= c1 && idx == 3) alpha = 0;
    *argb = alpha << 24 | (c[idx] & 0xFFFFFF);
}
/* A8R8G8B8 per texel (the runtime's decode); 0 = format not decoded. */
static int decode(const uint8_t *p, const uint8_t *pal, uint32_t c, uint32_t w, uint32_t h, uint32_t *out)
{
    uint32_t x, y;
    for (y = 0; y < h; y++)
        for (x = 0; x < w; x++) {
            uint32_t *o = &out[(size_t)y * w + x], i = swz(x, y, w, h), t;
            switch (c) {
            case 0x0C: case 0x0E: case 0x0F: dxt_texel(p, c, x, y, w, o); continue;
            case 0x06: *o = rd32(p + 4 * i); break;
            case 0x07: *o = rd32(p + 4 * i) | 0xFF000000u; break;
            case 0x0B: *o = pal ? rd32(pal + 4 * p[i]) : 0xFFFF00FFu; break;
            case 0x19: *o = (uint32_t)p[i] << 24 | 0xFFFFFF; break;
            case 0x00: t = p[i]; *o = 0xFF000000u | t << 16 | t << 8 | t; break;
            case 0x02: t = rd16(p + 2 * i); *o = (t & 0x8000 ? 0xFF000000u : 0) | ex((t >> 10) & 31, 5) << 16 | ex((t >> 5) & 31, 5) << 8 | ex(t & 31, 5); break;
            case 0x03: t = rd16(p + 2 * i); *o = 0xFF000000u | ex((t >> 10) & 31, 5) << 16 | ex((t >> 5) & 31, 5) << 8 | ex(t & 31, 5); break;
            case 0x04: t = rd16(p + 2 * i); *o = ex(t >> 12, 4) << 24 | ex((t >> 8) & 15, 4) << 16 | ex((t >> 4) & 15, 4) << 8 | ex(t & 15, 4); break;
            case 0x05: t = rd16(p + 2 * i); *o = 0xFF000000u | ex(t >> 11, 5) << 16 | ex((t >> 5) & 63, 6) << 8 | ex(t & 31, 5); break;
            default: return 0;
            }
        }
    return 1;
}

static void png_chunk(FILE *f, const char *type, const uint8_t *d, uint32_t n)
{
    uint8_t hdr[8] = { n >> 24, n >> 16, n >> 8, n, type[0], type[1], type[2], type[3] };
    uint32_t crc = crc32(0, hdr + 4, 4);
    uint8_t t[4];
    crc = crc32(crc, d, n);
    fwrite(hdr, 1, 8, f);
    fwrite(d, 1, n, f);
    t[0] = crc >> 24; t[1] = crc >> 16; t[2] = crc >> 8; t[3] = crc;
    fwrite(t, 1, 4, f);
}
static int write_png(const char *path, const uint32_t *argb, uint32_t w, uint32_t h)
{
    size_t raw_n = (size_t)(w * 4 + 1) * h, x, y;
    uint8_t *raw = malloc(raw_n), ihdr[13];
    uLongf zn = compressBound(raw_n);
    uint8_t *z = malloc(zn);
    FILE *f;
    if (!raw || !z) { free(raw); free(z); return 0; }
    for (y = 0; y < h; y++) {
        uint8_t *r = raw + y * (w * 4 + 1);
        r[0] = 0;
        for (x = 0; x < w; x++) {
            uint32_t c = argb[y * w + x];
            r[1 + 4 * x] = c >> 16; r[2 + 4 * x] = c >> 8; r[3 + 4 * x] = c; r[4 + 4 * x] = c >> 24;
        }
    }
    compress2(z, &zn, raw, raw_n, 6);
    f = fopen(path, "wb");
    if (!f) { free(raw); free(z); return 0; }
    fwrite("\x89PNG\r\n\x1a\n", 1, 8, f);
    ihdr[0] = w >> 24; ihdr[1] = w >> 16; ihdr[2] = w >> 8; ihdr[3] = w;
    ihdr[4] = h >> 24; ihdr[5] = h >> 16; ihdr[6] = h >> 8; ihdr[7] = h;
    ihdr[8] = 8; ihdr[9] = 6; ihdr[10] = ihdr[11] = ihdr[12] = 0;
    png_chunk(f, "IHDR", ihdr, 13);
    png_chunk(f, "IDAT", z, (uint32_t)zn);
    png_chunk(f, "IEND", NULL, 0);
    fclose(f);
    free(raw); free(z);
    return 1;
}

/* seen hashes (open addressing) */
static uint64_t *g_seen; static size_t g_seen_cap, g_seen_n;
static int seen_add(uint64_t h)
{
    size_t i;
    if (!h) h = 1;
    if (g_seen_n * 2 >= g_seen_cap) {
        uint64_t *old = g_seen; size_t oc = g_seen_cap, k;
        g_seen_cap = oc ? oc * 2 : 1 << 16;
        g_seen = calloc(g_seen_cap, 8);
        g_seen_n = 0;
        for (k = 0; k < oc; k++) if (old[k]) seen_add(old[k]);
        free(old);
    }
    for (i = (size_t)(h * 0x9E3779B97F4A7C15ull) & (g_seen_cap - 1); g_seen[i]; i = (i + 1) & (g_seen_cap - 1))
        if (g_seen[i] == h) return 0;
    g_seen[i] = h; g_seen_n++;
    return 1;
}

static void sanitize(char *s)
{
    for (; *s; s++) if (*s < 0x20 || *s == '\t' || *s > 0x7E) *s = '_';
}

/* One texture: info (0x7C) + format record (0x3C); area = the pack's data area in memory. */
static void texture(const uint8_t *info, const uint8_t *rec, const uint8_t *area, size_t area_n,
                    const char *tpk, const char *file, uint64_t where, const char *how)
{
    char name[25], path[4096];
    uint32_t off = (uint32_t)(rd32(info + 0x30) - g_abase), poff = (uint32_t)(rd32(info + 0x34) - g_abase), size = rd32(info + 0x38), psize = rd32(info + 0x3C);
    uint32_t w = rd16(info + 0x44), h = rd16(info + 0x46), c = rd32(rec + 0x0C), n;
    uint64_t hash;
    const uint8_t *pal = NULL;
    int partial = 0, dup;
    uint32_t *argb;
    memcpy(name, info + 0x0C, 24); name[24] = 0; sanitize(name);
    g_stats[S_TEX]++;
    if (!w || !h || w > 4096 || h > 4096 || (uint64_t)off + size > area_n) { g_stats[S_NODATA]++; return; }
    if (!bpp_of(c) && c != 0x0C && c != 0x0E && c != 0x0F) {
        g_stats[(c >= 0x10 && c <= 0x13) || (c >= 0x1C && c <= 0x1F) ? S_LINEAR : S_UNK]++;
        printf("skip\t%02x\t%u\t%u\t%s\t%s\t%s\t%llu\t%s\n", c, w, h, tpk, name, file, (unsigned long long)where, how);
        return;
    }
    n = tex_bytes(c, w, h);
    if ((uint64_t)off + n > area_n) partial = 1;
    if (partial) {
        uint8_t *tmp = calloc(1, n);
        memcpy(tmp, area + off, area_n - off);
        hash = fnv64(tmp, n, 0xCBF29CE484222325ull);
        free(tmp);
    } else
        hash = fnv64(area + off, n, 0xCBF29CE484222325ull);
    if (c == 0x0B) {
        uint8_t z[1024] = { 0 };
        if (psize >= 4 && (uint64_t)poff + 1024 <= area_n) pal = area + poff;
        else if (psize >= 4 && (uint64_t)poff + psize <= area_n) { memcpy(z, area + poff, psize > 1024 ? 1024 : psize); pal = NULL; partial = 1; }
        else partial = 1;
        hash = fnv64(pal ? pal : z, 1024, hash);
        if (!pal) pal = z;
        if (partial) g_stats[S_PARTIAL]++;
        {   /* an all-zero palette is one the game fills at run time (vinyls, door lines, wheel masks are
             * recoloured from the paint choice): no picture and no hash to reproduce offline */
            int k, any = 0;
            for (k = 0; k < 1024 && !any; k++) any = pal[k] != 0;
            if (!any) {
                g_stats[S_NOPAL]++;
                printf("nopal\t%016llx\t%02x\t%u\t%u\t%s\t%s\t%s\t%llu\t%s\n", (unsigned long long)hash, c, w, h, tpk, name,
                       file, (unsigned long long)where, how);
                return;
            }
        }
        dup = !seen_add(hash);
        printf("tex\t%016llx\t%02x\t%u\t%u\t%s\t%s\t%s\t%llu\t%s%s\n", (unsigned long long)hash, c, w, h, tpk, name, file,
               (unsigned long long)where, how, partial ? ",partial" : "");
        if (dup) { g_stats[S_DUP]++; return; }
        argb = malloc((size_t)w * h * 4);
        if (bpp_of(c) * w * h > size) { /* top level larger than the data: leave it */ }
        decode(area + off, pal, c, w, h, argb);
    } else {
        if (partial) g_stats[S_PARTIAL]++;
        dup = !seen_add(hash);
        printf("tex\t%016llx\t%02x\t%u\t%u\t%s\t%s\t%s\t%llu\t%s%s\n", (unsigned long long)hash, c, w, h, tpk, name, file,
               (unsigned long long)where, how, partial ? ",partial" : "");
        if (dup) { g_stats[S_DUP]++; return; }
        if ((c == 0x0C || c == 0x0E || c == 0x0F) ? n > size : bpp_of(c) * w * h > size) return;
        argb = malloc((size_t)w * h * 4);
        decode(area + off, NULL, c, w, h, argb);
    }
    snprintf(path, sizeof path, "%s/%016llx_%02x_%ux%u.png", g_out, (unsigned long long)hash, c, w, h);
    if (write_png(path, argb, w, h)) g_stats[S_PNG]++;
    free(argb);
}

typedef struct { uint32_t id; const uint8_t *s, *e; } Chunk;
static int subchunks(const uint8_t *s, const uint8_t *e, Chunk *out, int max)
{
    int k = 0;
    while (s + 8 <= e && k < max) {
        uint32_t id = rd32(s), sz = rd32(s + 4);
        if (sz > (size_t)(e - s - 8)) return -1;
        out[k].id = id; out[k].s = s + 8; out[k].e = s + 8 + sz; k++;
        s += 8 + sz;
    }
    return s == e ? k : -1;
}

/* Parses a TPK at p (chunk header included, n bytes total). Returns 1 when it was one. */
static int tpk(const uint8_t *p, size_t n, const char *file, uint64_t where)
{
    Chunk top[16], hdr[16];
    int nt = subchunks(p + 8, p + n, top, 16), nh = -1, i;
    const Chunk *info = NULL, *rec = NULL, *comp = NULL, *data = NULL, *head = NULL;
    char name[29] = "?";
    if (nt <= 0) return 0;
    for (i = 0; i < nt; i++) {
        if (top[i].id == 0xB3310000) nh = subchunks(top[i].s, top[i].e, hdr, 16);
        else if (top[i].id == 0xB3320000) {
            Chunk d[8];
            int nd = subchunks(top[i].s, top[i].e, d, 8), k;
            for (k = 0; k < nd; k++) if (d[k].id == 0x33320002) data = &top[i], top[i] = d[k];
        } else if (top[i].id != 0) return 0;
    }
    if (nh <= 0) return 0;
    for (i = 0; i < nh; i++) {
        if (hdr[i].id == 0x33310001) head = &hdr[i];
        if (hdr[i].id == 0x33310003) comp = &hdr[i];
        if (hdr[i].id == 0x33310004) info = &hdr[i];
        if (hdr[i].id == 0x33310005) rec = &hdr[i];
    }
    if (!head || head->e - head->s < 0x20) return 0;
    memcpy(name, head->s + 4, 28); name[28] = 0; sanitize(name);
    g_stats[S_TPK]++;
    if (info && rec && data) {
        const uint8_t *base = data->s;
        size_t ni = (info->e - info->s) / 0x7C, nr = (rec->e - rec->s) / 0x3C, k;
        while (base < data->e && *base == 0x11 && ((base - p + where) & 0x7F)) base++;
        for (k = 0; k < ni && k < nr; k++)
            texture(info->s + k * 0x7C, rec->s + k * 0x3C, base, data->e - base, name, file, where, "raw");
    } else if (comp) {
        /* Blocks carry their data-area offsets (u32; a car's VINYL pack spans ~600 MB), so each
         * is copied straight to its offset in a sparse 4.5 GB anonymous mapping: only touched pages
         * cost memory, gaps read as zero. */
        size_t ne = (comp->e - comp->s) / 24, k;
        uint8_t *tails = calloc(ne ? ne : 1, 0xB8), *ok = calloc(ne ? ne : 1, 1);
        uint64_t lo = UINT64_MAX, hi = 0, *rs = calloc(2 * ne + 1, 8), *re = calloc(2 * ne + 1, 8);
        size_t nr = 0;
        g_stats[S_COMPTPK]++;
        for (k = 0; k < ne; k++) {
            const uint8_t *e = comp->s + k * 24, *t;
            uint32_t off = rd32(e + 4), cs = rd32(e + 8), ds, ps, bn;
            uint8_t *blk;
            if ((uint64_t)off + cs > n || off < 8 || (memcmp(p + off, "JDLZ", 4) && memcmp(p + off, "HUFF", 4))) { g_stats[S_BADOFF]++; continue; }
            blk = unpack(p + off, cs, &bn);
            if (!blk) { g_stats[p[off] == 'J' ? S_BADJ : S_BADH]++; g_stats[S_BADBLK]++; continue; }
            t = blk + bn - 0xB8;
            ds = bn >= 0xB8 ? rd32(t + 0x38) : 0; ps = bn >= 0xB8 ? rd32(t + 0x3C) : 0;
            if (bn < 0xB8 || ds > bn - 0xB8) { free(blk); g_stats[S_BADBLK]++; g_stats[S_BADT]++; continue; }
            {
                uint64_t d0 = rd32(t + 0x30), d1 = d0 + ds, p0 = rd32(t + 0x34), p1 = p0 + ps;
                /* the palette sits in the block where it sits in the data area: poff - off (after the
                 * data, 0x40-aligned) */
                uint64_t pin = p0 >= d0 ? p0 - d0 : ds;
                int haspal = ps && pin >= ds && pin + ps <= bn - 0xB8, clash = 0;
                size_t q;
                for (q = 0; q < nr && !clash; q++)
                    clash = (d0 < re[q] && rs[q] < d1) || (haspal && p0 < re[q] && rs[q] < p1);
                if (clash) {
                    /* offsets reused inside the pack (VINYL: each vinyl is loaded on its own at run time):
                     * this texture is hashed and decoded from its own block */
                    uint64_t a0 = haspal && p0 < d0 ? p0 : d0, a1 = haspal && p1 > d1 ? p1 : d1;
                    uint8_t *own = calloc(1, (size_t)(a1 - a0));
                    memcpy(own + (d0 - a0), blk, ds);
                    if (haspal) memcpy(own + (p0 - a0), blk + pin, ps);
                    g_abase = a0;
                    texture(t, t + 0x7C, own, (size_t)(a1 - a0), name, file, where, "comp,own");
                    g_abase = 0;
                    g_stats[S_OWN]++;
                    free(own); free(blk);
                    continue;
                }
                memcpy(g_vm + d0, blk, ds);
                rs[nr] = d0; re[nr++] = d1;
                if (d0 < lo) lo = d0;
                if (d1 > hi) hi = d1;
                if (haspal) {
                    memcpy(g_vm + p0, blk + pin, ps);
                    rs[nr] = p0; re[nr++] = p1;
                    if (p0 < lo) lo = p0;
                    if (p1 > hi) hi = p1;
                }
            }
            memcpy(tails + k * 0xB8, t, 0xB8);
            ok[k] = 1;
            free(blk);
        }
        if (getenv("DC_DEBUG")) fprintf(stderr, "comp tpk %s @%llu: %zu entries, area %llx..%llx\n", name, (unsigned long long)where, ne, (unsigned long long)lo, (unsigned long long)hi);
        if (lo != UINT64_MAX) {
            /* the area the game sees is the whole pack; reads past its end hash as zero */
            size_t span = (size_t)(hi - lo) + (16u << 20);
            for (k = 0; k < ne; k++)
                if (ok[k]) {
                    g_abase = lo;
                    texture(tails + k * 0xB8, tails + k * 0xB8 + 0x7C, g_vm + lo, span, name, file, where, "comp");
                    g_abase = 0;
                }
            vm_reset(lo, hi);
        }
        free(tails); free(ok); free(rs); free(re);
    }
    return 1;
}

int main(int argc, char **argv)
{
    int a;
    if (argc < 3) { fprintf(stderr, "usage: disc_census OUT_DIR FILE...\n"); return 2; }
    g_out = argv[1];
    g_vm = mmap(NULL, VM_SIZE, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    if (g_vm == MAP_FAILED) { perror("mmap"); return 1; }
    mkdir(g_out, 0755);
    setvbuf(stdout, NULL, _IOFBF, 1 << 16);
    for (a = 2; a < argc; a++) {
        int fd = open(argv[a], O_RDONLY);
        struct stat st;
        const uint8_t *b;
        size_t n, o;
        const char *base = strrchr(argv[a], '/') ? strrchr(argv[a], '/') + 1 : argv[a];
        if (fd < 0 || fstat(fd, &st)) { perror(argv[a]); return 1; }
        n = (size_t)st.st_size;
        b = mmap(NULL, n, PROT_READ, MAP_PRIVATE, fd, 0);
        if (b == MAP_FAILED) { perror("mmap"); return 1; }
        for (o = 0; o + 16 <= n; o += 4) {
            uint32_t sz;
            if (rd32(b + o) != 0xB3300000u) continue;
            sz = rd32(b + o + 4);
            if (sz < 16 || sz > n - o - 8) {
                if (sz >= 16 && sz < (64u << 20)) fprintf(stderr, "%s: TPK at %zu runs past the file end\n", base, o);
                continue;
            }
            if (rd32(b + o + 8) != 0 && rd32(b + o + 8) != 0xB3310000u) continue;
            if (tpk(b + o, sz + 8, base, o))
                o += ((sz + 8) & ~3u) - 4;     /* past the pack: no false packs inside it */
        }
        munmap((void *)b, n);
        close(fd);
        fprintf(stderr, "%s: tpk %ld (compressed %ld), textures %ld, png %ld, dup %ld, bad blocks %ld, no data %ld, "
                "linear %ld, unknown fmt %ld, partial %ld, no palette %ld, own-block %ld, bad offsets %ld (jdlz %ld huff %ld tail %ld)\n", base, g_stats[S_TPK], g_stats[S_COMPTPK], g_stats[S_TEX],
                g_stats[S_PNG], g_stats[S_DUP], g_stats[S_BADBLK], g_stats[S_NODATA], g_stats[S_LINEAR], g_stats[S_UNK],
                g_stats[S_PARTIAL], g_stats[S_NOPAL], g_stats[S_OWN], g_stats[S_BADOFF], g_stats[S_BADJ], g_stats[S_BADH], g_stats[S_BADT]);
        fflush(stdout);
    }
    return 0;
}
