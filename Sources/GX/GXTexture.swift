/// GX texture formats (GXTexFmt) and decoders. Semantics follow Dolphin's TextureDecoder_Generic.cpp.
public enum GXTexFmt: UInt32, Sendable {
    case i4 = 0, i8 = 1, ia4 = 2, ia8 = 3, rgb565 = 4, rgb5a3 = 5, rgba8 = 6
    case c4 = 8, c8 = 9, c14x2 = 10, cmpr = 14

    /// Block (tile) dimensions in texels.
    public var block: (w: Int, h: Int) {
        switch self {
        case .i4, .c4, .cmpr: (8, 8)
        case .i8, .ia4, .c8: (8, 4)
        default: (4, 4)
        }
    }
    public var bitsPerPixel: Int {
        switch self {
        case .i4, .c4, .cmpr: 4
        case .i8, .ia4, .c8: 8
        case .rgba8: 32
        default: 16
        }
    }
    public func byteSize(width: Int, height: Int) -> Int {
        let b = block
        return roundUpGX(width, b.w) * roundUpGX(height, b.h) * bitsPerPixel / 8
    }
}

@inline(__always) func roundUpGX(_ n: Int, _ a: Int) -> Int { (n + a - 1) / a * a }

public enum GXTextureDecoder {
    @inline(__always) static func c5(_ v: Int) -> UInt8 { UInt8((v << 3) | (v >> 2)) }
    @inline(__always) static func c6(_ v: Int) -> UInt8 { UInt8((v << 2) | (v >> 4)) }
    @inline(__always) static func c4(_ v: Int) -> UInt8 { UInt8((v << 4) | v) }
    @inline(__always) static func c3(_ v: Int) -> UInt8 { UInt8((v << 5) | (v << 2) | (v >> 1)) }

    static func rgb565(_ v: UInt16) -> (UInt8, UInt8, UInt8) {
        (c5(Int(v >> 11) & 0x1F), c6(Int(v >> 5) & 0x3F), c5(Int(v) & 0x1F))
    }

    static func rgb5a3(_ v: UInt16) -> (UInt8, UInt8, UInt8, UInt8) {
        if v & 0x8000 != 0 { return (c5(Int(v >> 10) & 0x1F), c5(Int(v >> 5) & 0x1F), c5(Int(v) & 0x1F), 255) }
        return (c4(Int(v >> 8) & 0xF), c4(Int(v >> 4) & 0xF), c4(Int(v) & 0xF), c3(Int(v >> 12) & 0x7))
    }

    /// Decode to linear RGBA8. `palette` (RGB5A3/RGB565/IA8 entries, big-endian u16) needed for C4/C8/C14X2.
    public static func decode(_ src: [UInt8], offset: Int = 0, width: Int, height: Int, format: GXTexFmt,
                              palette: [UInt16] = [], paletteFormat: UInt32 = 2) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: width * height * 4)
        let (bw, bh) = format.block
        var p = offset
        func put(_ x: Int, _ y: Int, _ r: UInt8, _ g: UInt8, _ b: UInt8, _ a: UInt8) {
            guard x < width, y < height else { return }
            let o = (y * width + x) * 4
            out[o] = r; out[o + 1] = g; out[o + 2] = b; out[o + 3] = a
        }
        func pal(_ i: Int, _ x: Int, _ y: Int) {
            let v = i < palette.count ? palette[i] : 0
            switch paletteFormat {
            case 0: put(x, y, UInt8(v & 0xFF), UInt8(v & 0xFF), UInt8(v & 0xFF), UInt8(v >> 8)) // IA8
            case 1: let c = rgb565(v); put(x, y, c.0, c.1, c.2, 255)
            default: let c = rgb5a3(v); put(x, y, c.0, c.1, c.2, c.3)
            }
        }
        @inline(__always) func u16(_ o: Int) -> UInt16 { UInt16(src[o]) << 8 | UInt16(src[o + 1]) }

        for by in stride(from: 0, to: height, by: bh) {
            for bx in stride(from: 0, to: width, by: bw) {
                switch format {
                case .i4:
                    for y in 0..<8 { for x in stride(from: 0, to: 8, by: 2) {
                        let v = src[p]; p += 1
                        let a = c4(Int(v >> 4)), b = c4(Int(v & 0xF))
                        put(bx + x, by + y, a, a, a, a); put(bx + x + 1, by + y, b, b, b, b)
                    } }
                case .i8:
                    for y in 0..<4 { for x in 0..<8 { let v = src[p]; p += 1; put(bx + x, by + y, v, v, v, v) } }
                case .ia4:
                    for y in 0..<4 { for x in 0..<8 {
                        let v = src[p]; p += 1
                        let i = c4(Int(v & 0xF)); put(bx + x, by + y, i, i, i, c4(Int(v >> 4)))
                    } }
                case .ia8:
                    for y in 0..<4 { for x in 0..<4 {
                        let a = src[p], i = src[p + 1]; p += 2; put(bx + x, by + y, i, i, i, a)
                    } }
                case .rgb565:
                    for y in 0..<4 { for x in 0..<4 { let c = rgb565(u16(p)); p += 2; put(bx + x, by + y, c.0, c.1, c.2, 255) } }
                case .rgb5a3:
                    for y in 0..<4 { for x in 0..<4 { let c = rgb5a3(u16(p)); p += 2; put(bx + x, by + y, c.0, c.1, c.2, c.3) } }
                case .rgba8:
                    for i in 0..<16 {
                        let x = i % 4, y = i / 4
                        put(bx + x, by + y, src[p + i * 2 + 1], src[p + 32 + i * 2], src[p + 32 + i * 2 + 1], src[p + i * 2])
                    }
                    p += 64
                case .c4:
                    for y in 0..<8 { for x in stride(from: 0, to: 8, by: 2) {
                        let v = src[p]; p += 1; pal(Int(v >> 4), bx + x, by + y); pal(Int(v & 0xF), bx + x + 1, by + y)
                    } }
                case .c8:
                    for y in 0..<4 { for x in 0..<8 { pal(Int(src[p]), bx + x, by + y); p += 1 } }
                case .c14x2:
                    for y in 0..<4 { for x in 0..<4 { pal(Int(u16(p) & 0x3FFF), bx + x, by + y); p += 2 } }
                case .cmpr:
                    for sub in 0..<4 {
                        let sx = bx + (sub & 1) * 4, sy = by + (sub >> 1) * 4
                        let pal = cmprPalette(u16(p), u16(p + 2))
                        for y in 0..<4 {
                            let row = src[p + 4 + y]
                            for x in 0..<4 {
                                let c = pal[Int(row >> (6 - x * 2)) & 3]
                                put(sx + x, sy + y, c.0, c.1, c.2, c.3)
                            }
                        }
                        p += 8
                    }
                }
            }
        }
        return out
    }

    /// Dolphin's CMPR palette: GX uses 3/8 + 5/8 style weights ((2a+b)/3 approximated) — we follow Dolphin exactly.
    static func cmprPalette(_ c0: UInt16, _ c1: UInt16) -> [(UInt8, UInt8, UInt8, UInt8)] {
        let a = rgb565(c0), b = rgb565(c1)
        func mix(_ x: UInt8, _ y: UInt8, _ wx: Int, _ wy: Int, _ d: Int) -> UInt8 { UInt8((Int(x) * wx + Int(y) * wy) / d) }
        if c0 > c1 {
            // Dolphin: DXTBlend(v1, v2) = ((v1 * 3 + v2 * 5) >> 3)
            return [(a.0, a.1, a.2, 255), (b.0, b.1, b.2, 255),
                    (mix(b.0, a.0, 3, 5, 8), mix(b.1, a.1, 3, 5, 8), mix(b.2, a.2, 3, 5, 8), 255),
                    (mix(a.0, b.0, 3, 5, 8), mix(a.1, b.1, 3, 5, 8), mix(a.2, b.2, 3, 5, 8), 255)]
        }
        // GX quirk (unlike DXT1): index 3 is the midpoint color with alpha 0, not transparent black.
        let m = (UInt8((Int(a.0) + Int(b.0)) / 2), UInt8((Int(a.1) + Int(b.1)) / 2), UInt8((Int(a.2) + Int(b.2)) / 2))
        return [(a.0, a.1, a.2, 255), (b.0, b.1, b.2, 255), (m.0, m.1, m.2, 255), (m.0, m.1, m.2, 0)]
    }

    /// Lossless-ish CMPR → BC1 (DXT1) block reorder for GPUs with BC support (Apple Silicon Macs).
    /// GX: 8x8 tiles of four 4x4 sub-blocks, big-endian colors, MSB-first 2-bit indices.
    /// BC1: row-major 4x4 blocks, little-endian colors, LSB-first indices.
    /// (Interpolation weights differ slightly from GX's; use `decode` when exactness matters.)
    public static func cmprToBC1(_ src: [UInt8], offset: Int = 0, width: Int, height: Int) -> [UInt8] {
        let bw = width / 4, bh = height / 4
        var out = [UInt8](repeating: 0, count: bw * bh * 8)
        var p = offset
        for ty in stride(from: 0, to: bh, by: 2) {
            for tx in stride(from: 0, to: bw, by: 2) {
                for sub in 0..<4 {
                    let x = tx + (sub & 1), y = ty + (sub >> 1)
                    if x < bw, y < bh {
                        let o = (y * bw + x) * 8
                        out[o] = src[p + 1]; out[o + 1] = src[p]
                        out[o + 2] = src[p + 3]; out[o + 3] = src[p + 2]
                        for r in 0..<4 {
                            let v = src[p + 4 + r]
                            out[o + 4 + r] = (v >> 6) & 3 | ((v >> 4) & 3) << 2 | ((v >> 2) & 3) << 4 | (v & 3) << 6
                        }
                    }
                    p += 8
                }
            }
        }
        return out
    }
}
