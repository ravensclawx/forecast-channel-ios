import Foundation
import RVL

/// Big-endian byte writer.
struct BEWriter {
    var bytes: [UInt8] = []
    var count: Int { bytes.count }
    mutating func u8(_ v: UInt8) { bytes.append(v) }
    mutating func s8(_ v: Int8) { bytes.append(UInt8(bitPattern: v)) }
    mutating func u16(_ v: UInt16) { bytes += [UInt8(v >> 8), UInt8(v & 0xFF)] }
    mutating func s16(_ v: Int16) { u16(UInt16(bitPattern: v)) }
    mutating func u32(_ v: UInt32) { bytes += [UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }
    mutating func pad(to a: Int) { while bytes.count % a != 0 { bytes.append(0) } }
    mutating func put32(_ v: UInt32, at o: Int) {
        bytes[o] = UInt8(v >> 24); bytes[o + 1] = UInt8((v >> 16) & 0xFF); bytes[o + 2] = UInt8((v >> 8) & 0xFF); bytes[o + 3] = UInt8(v & 0xFF)
    }
    /// UTF-16BE, NUL-terminated.
    mutating func utf16(_ s: String) { for u in s.utf16 { u16(u) }; u16(0) }
}

/// LZ10 ("LZ77 type 0x10") encoder — the inverse of CXUncompressLZ.
public enum LZ10 {
    public static func compress(_ src: [UInt8]) -> [UInt8] {
        var out: [UInt8] = [0x10]
        if src.count < 0x100_0000 {
            out += [UInt8(src.count & 0xFF), UInt8((src.count >> 8) & 0xFF), UInt8((src.count >> 16) & 0xFF)]
        } else {
            out += [0, 0, 0, UInt8(src.count & 0xFF), UInt8((src.count >> 8) & 0xFF), UInt8((src.count >> 16) & 0xFF), UInt8(src.count >> 24)]
        }
        // hash chains over 3-byte prefixes, window 4096, match 3...18
        var head = [Int](repeating: -1, count: 1 << 15)
        var prev = [Int](repeating: -1, count: src.count)
        func h(_ i: Int) -> Int { (Int(src[i]) << 7 ^ Int(src[i + 1]) << 3 ^ Int(src[i + 2])) & 0x7FFF }
        func insert(_ i: Int) { guard i + 2 < src.count else { return }; let k = h(i); prev[i] = head[k]; head[k] = i }
        var i = 0
        while i < src.count {
            let flagPos = out.count; out.append(0)
            var flags: UInt8 = 0
            for bit in 0..<8 where i < src.count {
                var bestLen = 0, bestDist = 0
                if i + 2 < src.count {
                    var c = head[h(i)], tries = 0
                    while c >= 0 && i - c <= 0x1000 && tries < 64 {
                        var l = 0
                        while l < 18 && i + l < src.count && src[c + l] == src[i + l] { l += 1 }
                        if l > bestLen { bestLen = l; bestDist = i - c; if l == 18 { break } }
                        c = prev[c]; tries += 1
                    }
                }
                if bestLen >= 3 {
                    flags |= 0x80 >> UInt8(bit)
                    let d = bestDist - 1
                    out.append(UInt8((bestLen - 3) << 4 | (d >> 8)))
                    out.append(UInt8(d & 0xFF))
                    for k in 0..<bestLen { insert(i + k) }
                    i += bestLen
                } else {
                    out.append(src[i]); insert(i); i += 1
                }
            }
            out[flagPos] = flags
        }
        while out.count % 4 != 0 { out.append(0) }
        return out
    }
}

/// WiiConnect24 download container as served at weather.wapp.wii.com/<lang>/<country>/{forecast,short}.bin:
///   0x000  0x40  header (zero for unencrypted content)
///   0x040  0x100 RSA-2048 PKCS#1 v1.5 SHA-1 signature over the payload
///   0x140  …     LZ-compressed payload (the forecast.bin / short.bin bytes)
/// On the console, NWC24 (IOS) verifies the signature against Nintendo's key before storing the payload in the
/// WC24 VF ("3.bin" forecast, "4.bin" short); the channel itself only LZ-decompresses (CXGetCompressionType /
/// CXUncompressLZ in WiiConnect24.cpp) and runs fn_8000C734. The port, like Dolphin + RiiConnect24/WiiLink
/// setups, does not verify the signature; our generator writes a zero signature.
public enum WC24Container {
    public static let headerSize = 0x140

    public static func wrap(_ payload: [UInt8]) -> [UInt8] {
        [UInt8](repeating: 0, count: headerSize) + LZ10.compress(payload)
    }

    /// Accepts the full container, a bare LZ payload, or an already-decompressed file.
    public static func unwrap(_ data: [UInt8]) throws -> [UInt8] {
        var body = data
        if data.count > headerSize, data[0..<0x40].allSatisfy({ $0 == 0 }), data[headerSize] == 0x10 || data[headerSize] == 0x11 {
            body = Array(data[headerSize...])
        }
        if let first = body.first, first == 0x10 || first == 0x11 {
            do { return try CX.uncompressLZ(body) } catch { throw WeatherDataError.container("\(error)") }
        }
        return body
    }
}
