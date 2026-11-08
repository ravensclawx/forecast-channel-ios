import CoreGraphics
import Forecast
import Foundation
import ImageIO
import NW4R
import RVL
import UniformTypeIdentifiers

// fcupscale — AI ×4 upscaling of every 2D texture and font sheet the channel draws (for the iPhone, where the
// 608-wide logical screen is shown at ~1200 px). Output is Nintendo-derived: it goes to
// ~/Library/Application Support/ForecastChannel/upscaled/ and is never committed.
//
//   swift run -c release fcupscale dump     [workDir]   decode + key every texture → workDir/src/*.png + manifest.json
//   swift run -c release fcupscale process  [workDir]   Real-ESRGAN ×4 (toolchain/realesrgan) → upscaled/<key>.png
//   swift run -c release fcupscale all      [workDir]   both
//
// Keys are content keys (TextureOverrides.key: "<w>x<h>-<fnv1a64 of the RGBA8>"), so the runtime finds an
// override for any upload of the same pixels without knowing where it came from.

let fm = FileManager.default
let args = CommandLine.arguments
let cmd = args.count > 1 ? args[1] : "all"
let work = URL(fileURLWithPath: args.count > 2 ? args[2] : NSTemporaryDirectory() + "fcupscale")
let outDir = Assets.supportDirectory.appendingPathComponent("upscaled")
let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let esrgan = repo.appendingPathComponent("toolchain/realesrgan")

struct Entry: Codable {
    var key: String, source: String, w: Int, h: Int
    var wrapS: UInt32, wrapT: UInt32
    var kind: String          // "rgba" | "font"
    var latin = false         // font sheet holding Latin-range glyphs (US build text)
    var cmpr = false          // low-precision source (CMPR blocks / 5-bit colour / palettes) → soften before upscaling
}

// MARK: - PNG I/O

func writePNG(_ px: [UInt8], _ w: Int, _ h: Int, _ url: URL, gray: Bool = false) {
    var data = px
    let cs = gray ? CGColorSpaceCreateDeviceGray() : CGColorSpaceCreateDeviceRGB()
    let info = gray ? CGImageAlphaInfo.none.rawValue : CGImageAlphaInfo.last.rawValue
    let bpr = gray ? w : w * 4
    let provider = CGDataProvider(data: Data(bytes: &data, count: data.count) as CFData)!
    let img = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: gray ? 8 : 32, bytesPerRow: bpr, space: cs,
                      bitmapInfo: CGBitmapInfo(rawValue: info), provider: provider, decode: nil, shouldInterpolate: false,
                      intent: .defaultIntent)!
    let d = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(d, img, nil); CGImageDestinationFinalize(d)
}

/// Reads any PNG as RGBA8 (straight alpha).
func readPNG(_ url: URL) -> (px: [UInt8], w: Int, h: Int)? {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
    let w = img.width, h = img.height
    var px = [UInt8](repeating: 0, count: w * h * 4)
    let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    return (px, w, h)
}

// MARK: - dump

func dump() throws {
    let assets = try Assets()
    try? fm.removeItem(at: work); try fm.createDirectory(at: work.appendingPathComponent("src"), withIntermediateDirectories: true)
    var entries: [String: Entry] = [:]
    // Wrap modes per texture name from every layout's materials (a tiled texture must be padded by wrapping).
    var wrap: [String: (UInt32, UInt32)] = [:]
    func scanLayouts(_ arc: ARCArchive) {
        for (path, _) in arc.files where path.hasSuffix(".brlyt") {
            guard let d = arc.file(path), let l = try? Layout(d) else { continue }
            for m in l.materials { for tm in m.texMaps where tm.texture < l.textureNames.count {
                let n = l.textureNames[tm.texture]; let o = wrap[n] ?? (0, 0)
                wrap[n] = (max(o.0, tm.wrapS), max(o.1, tm.wrapT))
            } }
        }
    }
    func add(_ px: [UInt8], _ w: Int, _ h: Int, source: String, wrapS: UInt32, wrapT: UInt32, kind: String, latin: Bool = false, cmpr: Bool = false) {
        guard w > 0, h > 0, px.count >= w * h * 4 else { return }
        let key = TextureOverrides.key(px, w, h)
        if entries[key] != nil { return }
        let raw = Array(px.prefix(w * h * 4))
        try? Data(raw).write(to: work.appendingPathComponent("src/\(key).rgba"))
        writePNG(raw, w, h, work.appendingPathComponent("src/\(key).png"))   // for inspection only
        entries[key] = Entry(key: key, source: source, w: w, h: h, wrapS: wrapS, wrapT: wrapT, kind: kind, latin: latin, cmpr: cmpr)
    }
    func addTPL(_ d: [UInt8], _ source: String, name: String? = nil) {
        guard let t = try? TPLFile(CX.uncompressIfNeeded(d)) else { return }
        for (i, im) in t.images.enumerated() {
            let lw = name.flatMap { wrap[$0] } ?? (0, 0)
            add(im.rgba8, im.width, im.height, source: "\(source)#\(i)", wrapS: max(im.wrapS, lw.0), wrapT: max(im.wrapT, lw.1), kind: "rgba",
                cmpr: [.cmpr, .rgb5a3, .rgb565, .c4, .c8, .c14x2].contains(im.format))
        }
    }
    func addFont(_ d: [UInt8], _ source: String) {
        guard let f = try? ResFont(CX.uncompressIfNeeded(d)) else { return }
        // Sheets that hold any glyph the US build can show: ASCII, Latin-1, Latin Extended-A, punctuation, °.
        let ranges: [ClosedRange<UInt16>] = [0x20...0x7E, 0xA0...0x17F, 0x2010...0x203A, 0x2122...0x2122]
        var latinSheets = Set<Int>()
        for r in ranges { for c in r where f.hasGlyph(c) { latinSheets.insert(f.glyph(c).sheet) } }
        for (i, s) in f.sheets.enumerated() {
            add(s, f.sheetWidth, f.sheetHeight, source: "\(source)#\(i)", wrapS: 0, wrapT: 0, kind: "font", latin: latinSheets.contains(i))
        }
    }
    func walk(_ arc: ARCArchive, _ label: String) {
        scanLayouts(arc)
        for (path, _) in arc.files.sorted(by: { $0.key < $1.key }) {
            guard let d = arc.file(path) else { continue }
            let lower = path.lowercased(), name = String(path.split(separator: "/").last ?? "")
            if lower.hasSuffix(".tpl") || lower.hasSuffix(".tpl.lz") { addTPL(d, "\(label):\(path)", name: name) }
            else if lower.contains(".brfnt") || lower.hasSuffix(".brfna") { addFont(d, "\(label):\(path)") }
            else if lower.hasSuffix(".arc") || lower.hasSuffix(".arc.lz") {
                if let sub = try? ARCArchive(CX.uncompressIfNeeded(d)) { walk(sub, "\(label):\(path)") }
            }
        }
    }
    // Layout archive first so its wrap table covers /arc/timg.
    let layoutArc = try assets.weatherLayoutArchive()
    scanLayouts(layoutArc)
    walk(layoutArc, "weather_layout")
    walk(try assets.archive(.weather), "content9")
    walk(try assets.archive(.systemFonts), "content7")
    if let hbm = try? assets.archive(.homeButton) { walk(hbm, "content6") }
    let list = entries.values.sorted { $0.key < $1.key }
    try JSONEncoder().encode(list).write(to: work.appendingPathComponent("manifest.json"))
    let px = list.reduce(0) { $0 + $1.w * $1.h }
    print("dumped \(list.count) textures (\(list.filter { $0.kind == "font" }.count) font sheets), \(px) px → ×4 = \(px * 16 * 4 / 1_048_576) MB RGBA8")
}

// MARK: - process

/// Pad by `p` texels per side: wrapped on a repeating axis, edge-clamped otherwise (so the network sees the
/// right neighbourhood at the borders and no seams appear).
func pad(_ px: [UInt8], _ w: Int, _ h: Int, _ p: Int, wrapS: UInt32, wrapT: UInt32) -> [UInt8] {
    let W = w + 2 * p, H = h + 2 * p
    var o = [UInt8](repeating: 0, count: W * H * 4)
    func sx(_ x: Int) -> Int { wrapS != 0 ? ((x % w) + w) % w : min(max(x, 0), w - 1) }
    func sy(_ y: Int) -> Int { wrapT != 0 ? ((y % h) + h) % h : min(max(y, 0), h - 1) }
    for y in 0..<H { for x in 0..<W {
        let s = (sy(y - p) * w + sx(x - p)) * 4, d = (y * W + x) * 4
        o[d] = px[s]; o[d + 1] = px[s + 1]; o[d + 2] = px[s + 2]; o[d + 3] = px[s + 3]
    } }
    return o
}

/// Fill the RGB of fully transparent texels from their nearest visible neighbours (iterative dilation), so the
/// colour network never sees black fringes that would turn into halos.
func bleed(_ px: inout [UInt8], _ w: Int, _ h: Int) {
    var known = (0..<(w * h)).map { px[$0 * 4 + 3] > 0 }
    if !known.contains(true) { return }
    var frontier = true
    while frontier {
        frontier = false
        var next = known
        for y in 0..<h { for x in 0..<w where !known[y * w + x] {
            var r = 0, g = 0, b = 0, n = 0
            for (dx, dy) in [(-1, 0), (1, 0), (0, -1), (0, 1), (-1, -1), (1, 1), (-1, 1), (1, -1)] {
                let nx = x + dx, ny = y + dy
                guard nx >= 0, ny >= 0, nx < w, ny < h, known[ny * w + nx] else { continue }
                let s = (ny * w + nx) * 4; r += Int(px[s]); g += Int(px[s + 1]); b += Int(px[s + 2]); n += 1
            }
            if n > 0 {
                let d = (y * w + x) * 4
                px[d] = UInt8(r / n); px[d + 1] = UInt8(g / n); px[d + 2] = UInt8(b / n)
                next[y * w + x] = true; frontier = true
            }
        } }
        known = next
    }
}

/// High-quality resample (Core Graphics, high interpolation) — for textures too small for the network.
func resample(_ px: [UInt8], _ w: Int, _ h: Int, _ W: Int, _ H: Int) -> [UInt8] {
    var src = px
    let provider = CGDataProvider(data: Data(bytes: &src, count: src.count) as CFData)!
    let img = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider, decode: nil,
                      shouldInterpolate: true, intent: .defaultIntent)!
    var out = [UInt8](repeating: 0, count: W * H * 4)
    let ctx = CGContext(data: &out, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: W, height: H))
    return out
}

/// Runs Real-ESRGAN ×4 over a folder of PNGs.
func esrganFolder(_ input: URL, _ output: URL, model: String) throws {
    try fm.createDirectory(at: output, withIntermediateDirectories: true)
    let p = Process()
    p.executableURL = esrgan.appendingPathComponent("realesrgan-ncnn-vulkan")
    p.currentDirectoryURL = esrgan
    p.arguments = ["-i", input.path, "-o", output.path, "-n", model, "-s", "4", "-f", "png"]
    p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
    try p.run(); p.waitUntilExit()
    guard p.terminationStatus == 0 else { throw NSError(domain: "esrgan", code: Int(p.terminationStatus)) }
}

let P = 8          // padding texels per side
let deblock = ProcessInfo.processInfo.environment["FC_UPSCALE_DEBLOCK"] != "0"

/// Light 3×3 [1 2 1]² blur, alpha-weighted for colour — removes CMPR 4×4 block steps that the network would
/// otherwise sharpen into flat painted patches.
func soften(_ px: [UInt8], _ w: Int, _ h: Int) -> [UInt8] {
    var o = px
    let k = [1, 2, 1]
    for y in 0..<h { for x in 0..<w {
        var r = 0, g = 0, b = 0, a = 0, wa = 0, wsum = 0
        for j in -1...1 { for i in -1...1 {
            let xx = min(max(x + i, 0), w - 1), yy = min(max(y + j, 0), h - 1)
            let s = (yy * w + xx) * 4, wt = k[i + 1] * k[j + 1]
            let al = Int(px[s + 3])
            r += Int(px[s]) * wt * al; g += Int(px[s + 1]) * wt * al; b += Int(px[s + 2]) * wt * al
            a += al * wt; wa += wt * al; wsum += wt
        } }
        let d = (y * w + x) * 4
        if wa > 0 { o[d] = UInt8(r / wa); o[d + 1] = UInt8(g / wa); o[d + 2] = UInt8(b / wa) }
        o[d + 3] = UInt8(a / wsum)
    } }
    return o
}
let model = ProcessInfo.processInfo.environment["FC_UPSCALE_MODEL"] ?? "realesrgan-x4plus"

func process() throws {
    let all = try JSONDecoder().decode([Entry].self, from: Data(contentsOf: work.appendingPathComponent("manifest.json")))
    // Optional record of keys the app really uploaded (FC_UPSCALE_RECORD) — always included.
    let used = Set(((try? String(contentsOf: work.appendingPathComponent("used.txt"), encoding: .utf8)) ?? "").split(separator: "\n").map(String.init))
    func wanted(_ e: Entry) -> Bool {
        if used.contains(e.key) { return true }
        if e.kind == "font" { return e.latin }
        if e.source.hasPrefix("weather_layout") || e.source.hasPrefix("content9") { return true }
        // HOME Menu: shared + English archives only.
        return e.source.hasPrefix("content6") && (!e.source.contains("homeBtn_") || e.source.contains("homeBtn_ENG"))
    }
    let only = ProcessInfo.processInfo.environment["FC_UPSCALE_ONLY"].map { Set($0.split(separator: ",").map(String.init)) }
    let list = all.filter { e in only.map { $0.contains(e.key) } ?? wanted(e) }
    let planesIn = work.appendingPathComponent("planes_in"), planesOut = work.appendingPathComponent("planes_out")
    try? fm.removeItem(at: planesIn); try? fm.removeItem(at: planesOut)
    try fm.createDirectory(at: planesIn, withIntermediateDirectories: true)
    try fm.createDirectory(at: outDir, withIntermediateDirectories: true)

    enum Plan { case single, colourAlpha, colourOnly, resample }
    var plans: [String: Plan] = [:]
    var originals: [String: [UInt8]] = [:]
    for e in list {
        guard let raw = try? Data(contentsOf: work.appendingPathComponent("src/\(e.key).rgba")) else { continue }
        let px0 = [UInt8](raw), w = e.w, h = e.h
        originals[e.key] = px0
        // Tiny textures and 1-texel strips (gradients, lines) are resampled, not hallucinated.
        if min(w, h) < 4 || w * h < 64 { plans[e.key] = .resample; continue }
        var px = pad(px0, w, h, P, wrapS: e.wrapS, wrapT: e.wrapT)
        if e.cmpr && deblock { px = soften(px, w + 2 * P, h + 2 * P) }
        let W = w + 2 * P, H = h + 2 * P
        var single = true, opaque = true
        for i in stride(from: 0, to: px.count, by: 4) {
            if px[i] != px[i + 1] || px[i] != px[i + 2] || px[i] != px[i + 3] { single = false }
            if px[i + 3] != 255 { opaque = false }
        }
        if single && !opaque {
            // I4/I8 font sheets and coverage masks: one plane → upscale once, copy to all four channels.
            writePNG((0..<(W * H)).map { px[$0 * 4] }, W, H, planesIn.appendingPathComponent("\(e.key)_a.png"), gray: true)
            plans[e.key] = .single
        } else {
            var c = px
            if !opaque { bleed(&c, W, H) }
            for i in stride(from: 3, to: c.count, by: 4) { c[i] = 255 }
            writePNG(c, W, H, planesIn.appendingPathComponent("\(e.key)_c.png"))
            if !opaque { writePNG((0..<(W * H)).map { px[$0 * 4 + 3] }, W, H, planesIn.appendingPathComponent("\(e.key)_a.png"), gray: true) }
            plans[e.key] = opaque ? .colourOnly : .colourAlpha
        }
    }
    print("Real-ESRGAN (\(model)) on \(try fm.contentsOfDirectory(atPath: planesIn.path).count) planes…")
    try esrganFolder(planesIn, planesOut, model: model)

    var written = 0
    for e in list {
        guard let plan = plans[e.key], let orig = originals[e.key] else { continue }
        let w = e.w, h = e.h, W4 = w * 4, H4 = h * 4
        var out = [UInt8](repeating: 0, count: W4 * H4 * 4)
        func crop(_ img: (px: [UInt8], w: Int, h: Int), channel: Int) -> [UInt8] {
            // The padded plane came back ×4: drop 4·P texels per side.
            var o = [UInt8](repeating: 0, count: W4 * H4)
            for y in 0..<H4 { for x in 0..<W4 { o[y * W4 + x] = img.px[((y + 4 * P) * img.w + x + 4 * P) * 4 + channel] } }
            return o
        }
        switch plan {
        case .resample:
            // Colour (bled, opaque) and alpha resampled as separate opaque planes — CG would premultiply.
            var c = orig; bleed(&c, w, h)
            for i in stride(from: 3, to: c.count, by: 4) { c[i] = 255 }
            var ap = [UInt8](repeating: 255, count: w * h * 4)
            for i in 0..<(w * h) { let v = orig[i * 4 + 3]; ap[i * 4] = v; ap[i * 4 + 1] = v; ap[i * 4 + 2] = v }
            let cu = resample(c, w, h, W4, H4), au = resample(ap, w, h, W4, H4)
            for i in 0..<(W4 * H4) { out[i * 4] = cu[i * 4]; out[i * 4 + 1] = cu[i * 4 + 1]; out[i * 4 + 2] = cu[i * 4 + 2]; out[i * 4 + 3] = au[i * 4] }
        case .single:
            guard let a = readPNG(planesOut.appendingPathComponent("\(e.key)_a.png")) else { continue }
            let v = crop(a, channel: 0)
            for i in 0..<(W4 * H4) { out[i * 4] = v[i]; out[i * 4 + 1] = v[i]; out[i * 4 + 2] = v[i]; out[i * 4 + 3] = v[i] }
        case .colourOnly, .colourAlpha:
            guard let c = readPNG(planesOut.appendingPathComponent("\(e.key)_c.png")) else { continue }
            let r = crop(c, channel: 0), g = crop(c, channel: 1), b = crop(c, channel: 2)
            var a = [UInt8](repeating: 255, count: W4 * H4)
            if plan == .colourAlpha, let ai = readPNG(planesOut.appendingPathComponent("\(e.key)_a.png")) { a = crop(ai, channel: 0) }
            for i in 0..<(W4 * H4) { out[i * 4] = r[i]; out[i * 4 + 1] = g[i]; out[i * 4 + 2] = b[i]; out[i * 4 + 3] = a[i] }
        }
        // Tiers: fonts and big images (≥256 texels) ship at ×2 (the phone shows ~2 px per logical unit; text is
        // rarely magnified), small sprites/UI art at ×4 (they are often drawn magnified in portrait).
        if e.kind == "font" || max(w, h) >= 256 {
            var c = out; var ap = [UInt8](repeating: 255, count: W4 * H4 * 4)
            for i in 0..<(W4 * H4) { c[i * 4 + 3] = 255; let v = out[i * 4 + 3]; ap[i * 4] = v; ap[i * 4 + 1] = v; ap[i * 4 + 2] = v }
            let cd = resample(c, W4, H4, w * 2, h * 2), ad = resample(ap, W4, H4, w * 2, h * 2)
            var o2 = [UInt8](repeating: 0, count: w * h * 16)
            for i in 0..<(w * h * 4) { o2[i * 4] = cd[i * 4]; o2[i * 4 + 1] = cd[i * 4 + 1]; o2[i * 4 + 2] = cd[i * 4 + 2]; o2[i * 4 + 3] = ad[i * 4] }
            writePNG(o2, w * 2, h * 2, outDir.appendingPathComponent("\(e.key).png"))
        } else {
            writePNG(out, W4, H4, outDir.appendingPathComponent("\(e.key).png"))
        }
        written += 1
    }
    try JSONEncoder().encode(list).write(to: outDir.appendingPathComponent("manifest.json"))
    let mem = list.reduce(0) { $0 + (($1.kind == "font" || max($1.w, $1.h) >= 256) ? 4 : 16) * $1.w * $1.h * 4 }
    print("wrote \(written) upscaled textures (\(mem / 1_048_576) MB if all resident) → \(outDir.path)")
}

do {
    switch cmd {
    case "dump": try dump()
    case "process": try process()
    case "identity":
        // Test set: every selected texture enlarged ×4 by nearest neighbour (same image content) → identityDir.
        let dir = URL(fileURLWithPath: args.count > 3 ? args[3] : NSTemporaryDirectory() + "fcupscale_identity")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let list = try JSONDecoder().decode([Entry].self, from: Data(contentsOf: work.appendingPathComponent("manifest.json")))
        for e in list {
            guard let raw = try? Data(contentsOf: work.appendingPathComponent("src/\(e.key).rgba")) else { continue }
            let px = [UInt8](raw), W = e.w * 4, H = e.h * 4
            var o = [UInt8](repeating: 0, count: W * H * 4)
            for y in 0..<H { for x in 0..<W { let s = ((y / 4) * e.w + x / 4) * 4, d = (y * W + x) * 4
                o[d] = px[s]; o[d + 1] = px[s + 1]; o[d + 2] = px[s + 2]; o[d + 3] = px[s + 3] } }
            writePNG(o, W, H, dir.appendingPathComponent("\(e.key).png"))
        }
        print("identity set: \(list.count) → \(dir.path)")
    default: try dump(); try process()
    }
} catch { print("error: \(error)"); exit(1) }
