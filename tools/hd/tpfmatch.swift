// tpfmatch: maps community PC textures onto NFSU2's Xbox textures by content (tools/hd/community.py runs it).
//   tpfmatch --xbox DUMP_DIR[,DUMP_DIR...] --pc PC_DIR --out OUT_DIR [--tag NAME] [--maxk 4] [--maxside 2048]
//            [--thr 0.08] [--rev 0.01] [--kinds world] [--margin 1.2] [--alpha 48]
// Xbox side: NFSU2_TEX_DUMP files <hash>_<fmt>_<w>x<h>_<ui|world>.png (tools/hd/census.sh).
// PC side: .dds (DXT1/3/5, 32/24-bit), .png/.bmp/.tga/.jpg, from tools/hd/tpf.py or an unpacked mod.
// A PC texture is a candidate when its aspect ratio equals the Xbox one and it is at least 2x larger.
// Score = 0.5*(1 - NCC of 16x16 luma) + mean |RGB| /255 on 16x16 (alpha-weighted); accepted when
// score < thr, the score is within rev (0.01) of the best the PC texture reaches on any Xbox texture, the runner-up (another image) is at least margin x worse, and the alpha thumbnails differ
// by < alpha on average. Output: <hash>.png at k x the Xbox size (k = floor(pc/xbox), <= maxk, side <=
// maxside; straight alpha), manifest.tsv (our pack format, mode "community", engine = tag) and
// matches.tsv (every Xbox texture: best file, score, runner-up, verdict) for review.
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

struct Img { var w: Int; var h: Int; var px: [UInt8] }   // RGBA straight alpha, row 0 = top

func die(_ s: String) -> Never { FileHandle.standardError.write((s + "\n").data(using: .utf8)!); exit(1) }

// ── DDS ──
func rd32(_ d: [UInt8], _ o: Int) -> UInt32 { UInt32(d[o]) | UInt32(d[o+1]) << 8 | UInt32(d[o+2]) << 16 | UInt32(d[o+3]) << 24 }
func rgb565(_ c: UInt16) -> (Int, Int, Int) {
    let r = Int(c >> 11 & 31), g = Int(c >> 5 & 63), b = Int(c & 31)
    return (r << 3 | r >> 2, g << 2 | g >> 4, b << 3 | b >> 2)
}
func decodeDDS(_ d: [UInt8]) -> Img? {
    guard d.count >= 128, d[0] == 0x44, d[1] == 0x44, d[2] == 0x53, d[3] == 0x20 else { return nil }
    let h = Int(rd32(d, 12)), w = Int(rd32(d, 16)), pff = rd32(d, 80), four = rd32(d, 84)
    let bits = Int(rd32(d, 88)), rm = rd32(d, 92), gm = rd32(d, 96), bm = rd32(d, 100), am = rd32(d, 104)
    guard w > 0, h > 0, w <= 16384, h <= 16384 else { return nil }
    var px = [UInt8](repeating: 0, count: w * h * 4)
    let base = 128
    if pff & 4 != 0 {
        let fc = String(bytes: [UInt8(four & 255), UInt8(four >> 8 & 255), UInt8(four >> 16 & 255), UInt8(four >> 24)], encoding: .ascii) ?? ""
        let blk = fc == "DXT1" ? 8 : (fc == "DXT3" || fc == "DXT5" || fc == "DXT2" || fc == "DXT4") ? 16 : 0
        guard blk > 0 else { return nil }
        let bw = (w + 3) / 4, bh = (h + 3) / 4
        guard d.count >= base + bw * bh * blk else { return nil }
        for by in 0..<bh { for bx in 0..<bw {
            let o = base + (by * bw + bx) * blk
            var alpha = [Int](repeating: 255, count: 16)
            var co = o
            if blk == 16 {
                co = o + 8
                if fc == "DXT3" || fc == "DXT2" {
                    for i in 0..<16 { let v = Int(d[o + i / 2] >> (UInt8(i & 1) * 4) & 15); alpha[i] = v * 17 }
                } else {
                    let a0 = Int(d[o]), a1 = Int(d[o + 1])
                    var tab = [a0, a1, 0, 0, 0, 0, 0, 0]
                    if a0 > a1 { for i in 1...6 { tab[i + 1] = ((7 - i) * a0 + i * a1) / 7 } }
                    else { for i in 1...4 { tab[i + 1] = ((5 - i) * a0 + i * a1) / 5 }; tab[6] = 0; tab[7] = 255 }
                    var bitsA: UInt64 = 0
                    for i in 0..<6 { bitsA |= UInt64(d[o + 2 + i]) << (8 * UInt64(i)) }
                    for i in 0..<16 { alpha[i] = tab[Int(bitsA >> (3 * UInt64(i)) & 7)] }
                }
            }
            let c0 = UInt16(d[co]) | UInt16(d[co + 1]) << 8, c1 = UInt16(d[co + 2]) | UInt16(d[co + 3]) << 8
            let (r0, g0, b0) = rgb565(c0), (r1, g1, b1) = rgb565(c1)
            var pal = [(r0, g0, b0, 255), (r1, g1, b1, 255), (0, 0, 0, 255), (0, 0, 0, 255)]
            if c0 > c1 || blk == 16 {
                pal[2] = ((2 * r0 + r1) / 3, (2 * g0 + g1) / 3, (2 * b0 + b1) / 3, 255)
                pal[3] = ((r0 + 2 * r1) / 3, (g0 + 2 * g1) / 3, (b0 + 2 * b1) / 3, 255)
            } else {
                pal[2] = ((r0 + r1) / 2, (g0 + g1) / 2, (b0 + b1) / 2, 255)
                pal[3] = (0, 0, 0, 0)
            }
            let idx = rd32(d, co + 4)
            for i in 0..<16 {
                let x = bx * 4 + i % 4, y = by * 4 + i / 4
                if x >= w || y >= h { continue }
                let p = pal[Int(idx >> (2 * UInt32(i)) & 3)], q = (y * w + x) * 4
                px[q] = UInt8(p.0); px[q + 1] = UInt8(p.1); px[q + 2] = UInt8(p.2)
                px[q + 3] = UInt8(blk == 16 ? alpha[i] : p.3)
            }
        } }
        return Img(w: w, h: h, px: px)
    }
    guard pff & 0x40 != 0, bits == 32 || bits == 24 else { return nil }
    let bpp = bits / 8
    guard d.count >= base + w * h * bpp else { return nil }
    func ch(_ v: UInt32, _ m: UInt32) -> UInt8 {
        if m == 0 { return 255 }
        let sh = UInt32(m.trailingZeroBitCount), mx = m >> sh
        return UInt8(((v & m) >> sh) * 255 / mx)
    }
    for i in 0..<(w * h) {
        let o = base + i * bpp
        let v = bpp == 4 ? rd32(d, o) : UInt32(d[o]) | UInt32(d[o + 1]) << 8 | UInt32(d[o + 2]) << 16
        px[i * 4] = ch(v, rm); px[i * 4 + 1] = ch(v, gm); px[i * 4 + 2] = ch(v, bm)
        px[i * 4 + 3] = (pff & 1 != 0 && am != 0) ? ch(v, am) : 255
    }
    return Img(w: w, h: h, px: px)
}

func decodeCG(_ url: URL) -> Img? {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
    let w = img.width, h = img.height
    var px = [UInt8](repeating: 0, count: w * h * 4)
    let ok: Bool = px.withUnsafeMutableBytes { p in
        guard let c = CGContext(data: p.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        c.setBlendMode(.copy); c.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h)); return true
    }
    if !ok { return nil }
    for i in stride(from: 0, to: px.count, by: 4) {
        let a = Int(px[i + 3]); if a == 0 || a == 255 { continue }
        for k in 0..<3 { px[i + k] = UInt8(min(255, (Int(px[i + k]) * 255 + a / 2) / a)) }
    }
    return Img(w: w, h: h, px: px)
}

func load(_ path: String) -> Img? {
    if path.lowercased().hasSuffix(".dds") {
        guard let d = FileManager.default.contents(atPath: path) else { return nil }
        return decodeDDS([UInt8](d)) ?? decodeCG(URL(fileURLWithPath: path))
    }
    return decodeCG(URL(fileURLWithPath: path))
}

// premultiplied area-average resample (straight alpha in and out)
func resize(_ s: Img, _ W: Int, _ H: Int) -> Img {
    var out = [UInt8](repeating: 0, count: W * H * 4)
    let sx = Double(s.w) / Double(W), sy = Double(s.h) / Double(H)
    for y in 0..<H {
        let y0 = Int(Double(y) * sy), y1 = max(y0 + 1, Int((Double(y + 1) * sy).rounded(.up)))
        for x in 0..<W {
            let x0 = Int(Double(x) * sx), x1 = max(x0 + 1, Int((Double(x + 1) * sx).rounded(.up)))
            var r = 0.0, g = 0.0, b = 0.0, a = 0.0, n = 0.0
            for yy in y0..<min(y1, s.h) { for xx in x0..<min(x1, s.w) {
                let q = (yy * s.w + xx) * 4, al = Double(s.px[q + 3])
                r += Double(s.px[q]) * al; g += Double(s.px[q + 1]) * al; b += Double(s.px[q + 2]) * al; a += al; n += 1
            } }
            let o = (y * W + x) * 4
            if a > 0 { out[o] = UInt8(min(255, r / a)); out[o + 1] = UInt8(min(255, g / a)); out[o + 2] = UInt8(min(255, b / a)) }
            out[o + 3] = UInt8(min(255, (a / max(n, 1)).rounded()))
        }
    }
    return Img(w: W, h: H, px: out)
}

func writePNG(_ m: Img, _ path: String) -> Bool {
    let data = Data(m.px)
    guard let prov = CGDataProvider(data: data as CFData),
          let img = CGImage(width: m.w, height: m.h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: m.w * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                            provider: prov, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
          let dst = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { return false }
    CGImageDestinationAddImage(dst, img, nil)
    return CGImageDestinationFinalize(dst)
}

struct Feat { var luma: [Double]; var rgb: [Double]; var alpha: [Double]; var flat: Bool }
func feat(_ m: Img) -> Feat {
    let t = resize(m, 16, 16)
    var l = [Double](), c = [Double](), a = [Double]()
    for i in 0..<256 {
        let r = Double(t.px[i * 4]), g = Double(t.px[i * 4 + 1]), b = Double(t.px[i * 4 + 2])
        l.append(0.299 * r + 0.587 * g + 0.114 * b); c += [r, g, b]; a.append(Double(t.px[i * 4 + 3]))
    }
    let mu = l.reduce(0, +) / 256
    let sd = sqrt(l.map { ($0 - mu) * ($0 - mu) }.reduce(0, +) / 256)
    let ln = sd > 1e-6 ? l.map { ($0 - mu) / sd } : [Double](repeating: 0, count: 256)
    return Feat(luma: ln, rgb: c, alpha: a, flat: sd < 2)
}
func score(_ x: Feat, _ p: Feat) -> (Double, Double) {
    var ncc = 0.0
    for i in 0..<256 { ncc += x.luma[i] * p.luma[i] }
    ncc /= 256
    var mad = 0.0, wsum = 0.0, ad = 0.0
    for i in 0..<256 {
        let w = max(x.alpha[i], 16) / 255
        for k in 0..<3 { mad += abs(x.rgb[i * 3 + k] - p.rgb[i * 3 + k]) * w }
        wsum += 3 * w; ad += abs(x.alpha[i] - p.alpha[i])
    }
    return (0.5 * (1 - ncc) + mad / wsum / 255, ad / 256)
}

// ── arguments ──
var args: [String: String] = [:]
var it = CommandLine.arguments.dropFirst().makeIterator()
while let k = it.next() { guard k.hasPrefix("--"), let v = it.next() else { die("bad argument \(k)") }; args[String(k.dropFirst(2))] = v }
guard let xdirs = args["xbox"], let pcdir = args["pc"], let out = args["out"] else {
    die("usage: tpfmatch --xbox DIR[,DIR] --pc DIR --out DIR [--tag N] [--maxk 4] [--maxside 2048] [--thr 0.08] [--margin 1.2] [--alpha 48]")
}
let tag = args["tag"] ?? "community", maxk = Int(args["maxk"] ?? "4")!, maxside = Int(args["maxside"] ?? "2048")!
let thr = Double(args["thr"] ?? "0.08")!, margin = Double(args["margin"] ?? "1.2")!, athr = Double(args["alpha"] ?? "48")!
let fm = FileManager.default
try? fm.createDirectory(atPath: out, withIntermediateDirectories: true)

let re = try! NSRegularExpression(pattern: "^([0-9a-f]{16})_([0-9a-f]{2})_(\\d+)x(\\d+)_(ui|world)\\.png$")
struct X { var hash: String; var fmt: String; var w: Int; var h: Int; var kind: String; var f: Feat }
var xs: [X] = [], seen = Set<String>()
for dir in xdirs.split(separator: ",").map(String.init) {
    let en = fm.enumerator(atPath: dir)
    while let rel = en?.nextObject() as? String {
        let name = (rel as NSString).lastPathComponent
        guard let mt = re.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) else { continue }
        func g(_ i: Int) -> String { String(name[Range(mt.range(at: i), in: name)!]) }
        if seen.contains(g(1)) { continue }
        guard let m = load(dir + "/" + rel) else { continue }
        seen.insert(g(1))
        xs.append(X(hash: g(1), fmt: g(2), w: Int(g(3))!, h: Int(g(4))!, kind: g(5), f: feat(m)))
    }
}
struct P { var path: String; var w: Int; var h: Int; var f: Feat }
var ps: [P] = []
let exts: Set<String> = ["dds", "png", "bmp", "tga", "jpg", "jpeg"]
let pen = fm.enumerator(atPath: pcdir)
var unread = 0
while let rel = pen?.nextObject() as? String {
    guard exts.contains((rel as NSString).pathExtension.lowercased()) else { continue }
    let p = pcdir + "/" + rel
    guard let m = load(p) else { unread += 1; continue }
    ps.append(P(path: rel, w: m.w, h: m.h, f: feat(m)))
}
FileHandle.standardError.write("tpfmatch: \(xs.count) Xbox textures, \(ps.count) PC textures (\(unread) unreadable)\n".data(using: .utf8)!)

var man = "# hash\tkind\tfmt\tw\th\tk\tmode\tengine\n", rep = "# hash\tw\th\tverdict\tscore\trunner_up\talpha_diff\tk\tpc_file\tpc_w\tpc_h\n"
var nOK = 0
// reverse check: the best score each PC texture reaches over all Xbox textures; an Xbox texture takes a PC
// one only when it is about as close as that best (else it is a look-alike: another road, another frame)
let rev = Double(args["rev"] ?? "0.01")!
// world only by default: the PC front end differs from the Xbox one (other menus, other fonts)
let kinds = Set((args["kinds"] ?? "world").split(separator: ",").map(String.init))
var pbest = [Double](repeating: .infinity, count: ps.count)
for x in xs where !x.f.flat && kinds.contains(x.kind) {
    for (j, p) in ps.enumerated() where p.w * x.h == p.h * x.w && p.w >= 2 * x.w && !p.f.flat {
        pbest[j] = min(pbest[j], score(x.f, p.f).0)
    }
}
for x in xs {
    var best = (Double.infinity, -1, 0.0), second = Double.infinity, sj = -1
    if !kinds.contains(x.kind) { rep += "\(x.hash)\t\(x.w)\t\(x.h)\tkind-\(x.kind)\t-\t-\t-\t-\t-\t-\t-\n"; continue }
    if x.f.flat { rep += "\(x.hash)\t\(x.w)\t\(x.h)\tflat\t-\t-\t-\t-\t-\t-\t-\n"; continue }
    for (j, p) in ps.enumerated() where p.w * x.h == p.h * x.w && p.w >= 2 * x.w && !p.f.flat {
        let (s, ad) = score(x.f, p.f)
        if s < best.0 { if best.1 >= 0 { second = best.0; sj = best.1 }; best = (s, j, ad) } else if s < second { second = s; sj = j }
    }
    guard best.1 >= 0 else { rep += "\(x.hash)\t\(x.w)\t\(x.h)\tno-candidate\t-\t-\t-\t-\t-\t-\t-\n"; continue }
    let p = ps[best.1]
    var k = min(maxk, p.w / x.w)
    while k > 1 && max(x.w, x.h) * k > maxside { k -= 1 }
    var verdict = "ok"
    // a runner-up that is the same picture (a duplicate file in the pack) is no ambiguity
    let dup = sj >= 0 && score(ps[best.1].f, ps[sj].f).0 < 0.02
    if best.0 >= thr { verdict = "weak" } else if second < best.0 * margin && !dup { verdict = "ambiguous" }
    else if best.0 > pbest[best.1] + rev { verdict = "look-alike" }
    else if best.2 >= athr { verdict = "alpha" } else if k < 2 { verdict = "small" }
    rep += String(format: "%@\t%d\t%d\t%@\t%.4f\t%.4f\t%.1f\t%d\t%@\t%d\t%d\n", x.hash, x.w, x.h, verdict, best.0,
                  second.isFinite ? second : 9, best.2, k, p.path, p.w, p.h)
    guard verdict == "ok", let src = load(pcdir + "/" + p.path) else { continue }
    if writePNG(resize(src, x.w * k, x.h * k), out + "/" + x.hash + ".png") {
        man += "\(x.hash)\t\(x.kind)\t\(x.fmt)\t\(x.w)\t\(x.h)\t\(k)\tcommunity\t\(tag)\n"; nOK += 1
    }
}
try! man.write(toFile: out + "/manifest.tsv", atomically: true, encoding: .utf8)
try! rep.write(toFile: out + "/matches.tsv", atomically: true, encoding: .utf8)
print("tpfmatch: \(nOK) of \(xs.count) Xbox textures replaced from \(tag) -> \(out)")
