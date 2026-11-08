import RVL

/// CX Huffman decompression (CXUncompressHuffman), used by the HOME Menu's "Huf8_*" sound archives.
/// (Belongs with RVL's CX; kept here because the sound track owns only Snd files.)
public enum CXHuffman {
    public static func uncompress(_ d: [UInt8]) throws -> [UInt8] {
        guard d.count > 5, d[0] & 0xF0 == 0x20 else { throw RVLError.corrupt("not CX Huffman data") }
        let bits = Int(d[0] & 0xF)
        guard bits == 4 || bits == 8 else { throw RVLError.corrupt("bad Huffman unit \(bits)") }
        let size = Int(d[1]) | Int(d[2]) << 8 | Int(d[3]) << 16
        let root = 5
        var p = 4 + (Int(d[4]) + 1) * 2
        var out = [UInt8](); out.reserveCapacity(size)
        var cur = 0, nb = 0, pos = root
        while out.count < size {
            guard p + 4 <= d.count else { throw RVLError.corrupt("Huffman stream truncated") }
            var word = UInt32(d[p]) | UInt32(d[p + 1]) << 8 | UInt32(d[p + 2]) << 16 | UInt32(d[p + 3]) << 24
            p += 4
            for _ in 0..<32 {
                let bit = word >> 31; word <<= 1
                let node = Int(d[pos])
                let child = (pos & ~1) + (node & 0x3F) * 2 + 2
                let leaf: Bool
                if bit == 0 { leaf = node & 0x80 != 0; pos = child } else { leaf = node & 0x40 != 0; pos = child + 1 }
                if leaf {
                    cur |= Int(d[pos]) << nb; nb += bits; pos = root
                    if nb == 8 {
                        out.append(UInt8(cur)); cur = 0; nb = 0
                        if out.count >= size { break }
                    }
                }
            }
        }
        return out
    }
}
