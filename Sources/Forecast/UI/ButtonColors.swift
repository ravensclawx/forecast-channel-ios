/// Button colour schemes. Every screen's CLayout passes the table lbl_801D7060 (4 × 0x3C) to its CPaneCtls
/// (CLayout_ctor r6 → CPaneCtl +04); it is filled by the static initialiser fn_80010728 from .sdata2 constants.
/// (InitButtonColorSchemes / lbl_801F6B68 is only CPaneCtl's fallback for a NULL table — red hover — and no
/// screen uses it.) Offsets: +00/+04 body normal c0/c1, +08/+0C icon normal, +10 text normal, +14/+18 body
/// pressed/hover, +1C/+20 icon pressed, +24 text pressed, +28/+2C body selected, +30/+34 icon selected, +38 text
/// selected. Alpha bytes are 0 in the table; CPaneCtl_PreDraw writes alpha separately.
public enum ButtonColors {
    public typealias RGBA = SIMD4<UInt8>
    static func c(_ v: UInt32) -> RGBA { RGBA(UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)) }
    //                     +00 body n c0  +04 c1      +08 icon n   +0C          +10 text n   +14 body p   +18 body p c1
    //                     +1C icon p     +20         +24 text p   +28 body s   +2C          +30 icon s   +34          +38 text s
    static func scheme(text: UInt32, hover: UInt32, textHover: UInt32) -> [RGBA] {
        [0x0000_0000, 0xFFFF_FF00, 0x0000_0000, 0xFFFF_FF00, text, 0x0000_0000, hover,
         0xFFFF_FF00, 0x0000_0000, textHover, 0xC100_0000, 0xC100_0000, 0xFFFF_FF00, 0xFFFF_FF00, 0x0000_0000].map(c)
    }
    public static let schemes: [[RGBA]] = [
        scheme(text: 0x0000_0000, hover: 0x00C0_FF00, textHover: 0xFFFF_FF00),   // 0: black text, light-blue hover
        scheme(text: 0xFFFF_FF00, hover: 0xFFFF_FF00, textHover: 0x0000_0000),   // 1: white text, white hover
        scheme(text: 0xFFFF_FF00, hover: 0x00C0_FF00, textHover: 0xFFFF_FF00),   // 2: white text, light-blue hover
        scheme(text: 0x0000_0000, hover: 0x59DD_FF00, textHover: 0xFFFF_FF00),   // 3: black text, cyan hover
    ] + Array(repeating: Array(repeating: RGBA(0, 0, 0, 0), count: 15), count: 12)
    /// Word index by byte offset.
    public static func at(_ scheme: Int, _ off: Int) -> RGBA { schemes[min(max(scheme, 0), 15)][off / 4] }
    /// fn_800370F8: per-channel lerp a→b by n/max.
    public static func lerp(_ a: RGBA, _ b: RGBA, _ n: Int, _ max: Int) -> RGBA {
        guard max > 0 else { return a }
        var o = RGBA(0, 0, 0, 0)
        for i in 0..<4 { o[i] = UInt8(Int(a[i]) + (Int(b[i]) - Int(a[i])) * n / max) }
        return o
    }
}
