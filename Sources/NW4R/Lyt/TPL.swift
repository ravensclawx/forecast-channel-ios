import GX
import RVL

/// Revolution SDK TPL texture palette file (TPLGet / TPLBind replacement).
public struct TPLFile {
    public struct Image {
        public let width: Int, height: Int, format: GXTexFmt
        public let wrapS: UInt32, wrapT: UInt32, minFilter: UInt32, magFilter: UInt32
        public let rgba8: [UInt8]
    }
    public let images: [Image]

    public init(_ bytes: [UInt8]) throws {
        let r = BEReader(bytes)
        guard r.u32(0) == 0x0020_AF30 else { throw RVLError.badMagic(r.magic(0), expected: "TPL") }
        let n = Int(r.u32(4)), table = Int(r.u32(8))
        var imgs: [Image] = []
        for i in 0..<n {
            let ih = Int(r.u32(table + i * 8)), ph = Int(r.u32(table + i * 8 + 4))
            let h = Int(r.u16(ih)), w = Int(r.u16(ih + 2))
            let fmt = GXTexFmt(rawValue: r.u32(ih + 4)) ?? .rgba8
            let data = Int(r.u32(ih + 8))
            var palette: [UInt16] = [], palFmt: UInt32 = 2
            if ph != 0 {
                let count = Int(r.u16(ph)); palFmt = r.u32(ph + 4); let pd = Int(r.u32(ph + 8))
                palette = (0..<count).map { r.u16(pd + $0 * 2) }
            }
            imgs.append(Image(width: w, height: h, format: fmt, wrapS: r.u32(ih + 12), wrapT: r.u32(ih + 16),
                              minFilter: r.u32(ih + 20), magFilter: r.u32(ih + 24),
                              rgba8: GXTextureDecoder.decode(bytes, offset: data, width: w, height: h, format: fmt, palette: palette, paletteFormat: palFmt)))
        }
        images = imgs
    }
}
