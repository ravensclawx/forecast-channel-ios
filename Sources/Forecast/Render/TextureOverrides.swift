import Foundation
import ImageIO
import Metal

/// AI-upscaled replacements for the channel's 2D textures and font sheets (made offline by `fcupscale`, never
/// committed). Every upload goes through `GXMetal.makeTexture2D`: when an override exists for the original pixels,
/// the ×4 image is uploaded (with a full mip chain) instead — but the texture keeps its ORIGINAL logical size
/// (`logicalSize(of:)`), which every geometry / UV / GX texcoord-quantisation path uses, so nothing on screen moves.
public enum TextureOverrides {
    /// On by default on the iPhone; on the Mac set FC_UPSCALE=1 (the Wii look stays the default there).
    public static var enabled: Bool = {
        #if os(iOS)
        return ProcessInfo.processInfo.environment["FC_UPSCALE"] != "0"
        #else
        return ProcessInfo.processInfo.environment["FC_UPSCALE"] == "1"
        #endif
    }()
    /// Folder with `<key>.png` files; defaults to `<assets dir>/upscaled` (set by SceneContext).
    public static var directory: URL? = ProcessInfo.processInfo.environment["FC_UPSCALE_DIR"].map { URL(fileURLWithPath: $0) }

    /// FC_UPSCALE_RECORD=<file>: append the key of every texture the app uploads (fcupscale processes only these).
    static let recordURL: URL? = ProcessInfo.processInfo.environment["FC_UPSCALE_RECORD"].map { URL(fileURLWithPath: $0) }
    static func record(_ px: [UInt8], _ w: Int, _ h: Int) {
        guard let u = recordURL else { return }
        let line = key(px, w, h) + "\n"
        if let fh = try? FileHandle(forWritingTo: u) { fh.seekToEndOfFile(); fh.write(Data(line.utf8)); try? fh.close() }
        else { try? Data(line.utf8).write(to: u) }
    }

    /// Content key: "<w>x<h>-<FNV-1a 64 of the RGBA8 bytes>".
    public static func key(_ px: [UInt8], _ w: Int, _ h: Int) -> String {
        var hsh: UInt64 = 0xcbf2_9ce4_8422_2325
        px.withUnsafeBufferPointer { b in for v in b.prefix(w * h * 4) { hsh = (hsh ^ UInt64(v)) &* 0x100_0000_01b3 } }
        return "\(w)x\(h)-" + String(hsh, radix: 16)
    }

    /// The upscaled RGBA8 (straight alpha) for these original pixels, if one was made.
    static func lookup(_ px: [UInt8], _ w: Int, _ h: Int) -> (px: [UInt8], w: Int, h: Int)? {
        guard enabled, let dir = directory else { return nil }
        let url = dir.appendingPathComponent(key(px, w, h) + ".png")
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let W = img.width, H = img.height
        guard W >= w, H >= h else { return nil }
        // Decode straight (unpremultiplied) RGBA: draw the colour with alpha forced opaque, then the alpha alone.
        guard let provider = img.dataProvider, let data = provider.data, img.bitsPerComponent == 8 else { return nil }
        let bytes = CFDataGetBytePtr(data)!, bpr = img.bytesPerRow, bpp = img.bitsPerPixel / 8
        guard bpp == 4 || bpp == 3 || bpp == 1 else { return nil }
        let alphaFirst = [CGImageAlphaInfo.first, .premultipliedFirst, .noneSkipFirst].contains(img.alphaInfo)
        let premult = [CGImageAlphaInfo.premultipliedLast, .premultipliedFirst].contains(img.alphaInfo)
        var out = [UInt8](repeating: 255, count: W * H * 4)
        for y in 0..<H { for x in 0..<W {
            let s = y * bpr + x * bpp, d = (y * W + x) * 4
            if bpp == 1 { let v = bytes[s]; out[d] = v; out[d + 1] = v; out[d + 2] = v; out[d + 3] = v; continue }
            var r = bytes[s], g = bytes[s + 1], b = bytes[s + 2], a: UInt8 = 255
            if bpp == 4 { if alphaFirst { a = bytes[s]; r = bytes[s + 1]; g = bytes[s + 2]; b = bytes[s + 3] } else { a = bytes[s + 3] } }
            if premult && a > 0 && a < 255 {
                r = UInt8(min(255, Int(r) * 255 / Int(a))); g = UInt8(min(255, Int(g) * 255 / Int(a))); b = UInt8(min(255, Int(b) * 255 / Int(a)))
            }
            out[d] = r; out[d + 1] = g; out[d + 2] = b; out[d + 3] = a
        } }
        return (out, W, H)
    }

    // MARK: logical sizes

    private static var sizes: [ObjectIdentifier: SIMD2<Int>] = [:]
    private static let lock = NSLock()
    static func setLogicalSize(_ t: MTLTexture, _ w: Int, _ h: Int) {
        lock.lock(); sizes[ObjectIdentifier(t)] = SIMD2(w, h); lock.unlock()
    }
    /// The size the original texture had — use this (never `texture.width`) for geometry and UV math.
    public static func logicalSize(of t: MTLTexture) -> SIMD2<Int> {
        lock.lock(); defer { lock.unlock() }
        return sizes[ObjectIdentifier(t)] ?? SIMD2(t.width, t.height)
    }
}

extension MTLTexture {
    /// Original (pre-upscale) texel size; equals width/height for textures without an override.
    public var logicalWidth: Int { TextureOverrides.logicalSize(of: self).x }
    public var logicalHeight: Int { TextureOverrides.logicalSize(of: self).y }
}
