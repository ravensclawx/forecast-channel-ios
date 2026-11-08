/// Replacement for the RVL SDK CX (compression) library.
/// main.dol calls CXGetCompressionType / CXGetUncompressedSize / CXUncompressLZ / CXIsFinisiedUncompLZ
/// (see the "CX... data is not LZ." strings near 0x8019C11C).
public enum CX {
    public enum CompressionType: UInt8 { case lz = 0x10, lzExtended = 0x11, huffman = 0x20, rl = 0x30, none = 0x00 }

    public static func compressionType(_ d: [UInt8]) -> CompressionType? {
        guard let first = d.first else { return nil }
        return CompressionType(rawValue: first & 0xF0 == 0x10 ? first : first & 0xF0)
    }

    public static func uncompressedSize(_ d: [UInt8]) -> Int {
        let s = Int(d[1]) | Int(d[2]) << 8 | Int(d[3]) << 16
        if s != 0 { return s }
        return Int(d[4]) | Int(d[5]) << 8 | Int(d[6]) << 16 | Int(d[7]) << 24
    }

    /// LZ77 (types 0x10 and the 0x11 extended variant). Also accepts an "LZ77" prefixed stream.
    public static func uncompressLZ(_ input: [UInt8]) throws -> [UInt8] {
        var d = input[...]
        if d.count >= 4, d.prefix(4).elementsEqual("LZ77".utf8) { d = d.dropFirst(4) }
        let src = Array(d)
        guard src.count >= 4, src[0] == 0x10 || src[0] == 0x11 else { throw RVLError.corrupt("CXGetCompressionType() data is not LZ.") }
        let ext = src[0] == 0x11
        let size = uncompressedSize(src)
        var p = (Int(src[1]) | Int(src[2]) << 8 | Int(src[3]) << 16) == 0 ? 8 : 4
        var out = [UInt8](); out.reserveCapacity(size)
        while out.count < size {
            guard p < src.count else { throw RVLError.corrupt("CXIsFinisiedUncompLZ() is false.") }
            let flags = src[p]; p += 1
            for bit in 0..<8 where out.count < size {
                if flags & (0x80 >> bit) == 0 { out.append(src[p]); p += 1; continue }
                var len: Int, disp: Int
                if !ext {
                    len = Int(src[p] >> 4) + 3
                    disp = (Int(src[p] & 0xF) << 8 | Int(src[p + 1])) + 1; p += 2
                } else {
                    switch src[p] >> 4 {
                    case 0:
                        len = (Int(src[p] & 0xF) << 4 | Int(src[p + 1] >> 4)) + 0x11
                        disp = (Int(src[p + 1] & 0xF) << 8 | Int(src[p + 2])) + 1; p += 3
                    case 1:
                        len = (Int(src[p] & 0xF) << 12 | Int(src[p + 1]) << 4 | Int(src[p + 2] >> 4)) + 0x111
                        disp = (Int(src[p + 2] & 0xF) << 8 | Int(src[p + 3])) + 1; p += 4
                    default:
                        len = Int(src[p] >> 4) + 1
                        disp = (Int(src[p] & 0xF) << 8 | Int(src[p + 1])) + 1; p += 2
                    }
                }
                for _ in 0..<len { out.append(out[out.count - disp]) }
            }
        }
        return out
    }

    /// Files named *.LZ in this title are sometimes stored already-decompressed; detect by header.
    public static func uncompressIfNeeded(_ d: [UInt8]) throws -> [UInt8] {
        guard d.count > 8, d[0] == 0x10 || d[0] == 0x11 else { return d }
        let size = uncompressedSize(d)
        guard size > 0, size < 64 << 20 else { return d }
        return try uncompressLZ(d)
    }
}
