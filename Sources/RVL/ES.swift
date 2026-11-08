import CommonCrypto
import Foundation

/// Minimal ES (eticket services) replacement: opens an installable WAD the way IOS would,
/// decrypts the title key with the common key and exposes decrypted contents by TMD index.
/// Equivalent to Dolphin's IOS::ES import path, but reading from the WAD directly.
public final class ESTitle {
    public struct Content { public let id: UInt32; public let index: UInt16; public let type: UInt16; public let size: Int; public let sha1: [UInt8] }

    public let titleID: UInt64
    public let titleVersion: UInt16
    public let contents: [Content]
    private let titleKey: [UInt8]
    private let wad: [UInt8]
    private let contentOffsets: [Int]
    private var cache: [UInt16: [UInt8]] = [:]

    public init(wadURL: URL, commonKey: [UInt8]) throws {
        wad = [UInt8](try Data(contentsOf: wadURL))
        let r = BEReader(wad)
        guard r.u32(0) == 0x20, r.u16(4) == 0x4973 else { throw RVLError.badMagic(r.magic(4), expected: "Is") }
        let certSize = Int(r.u32(8)), tikSize = Int(r.u32(0x10)), tmdSize = Int(r.u32(0x14))
        let tik = 0x40 + roundUp(certSize, 0x40)
        let tmd = tik + roundUp(tikSize, 0x40)
        var off = tmd + roundUp(tmdSize, 0x40)

        titleID = r.u64(tmd + 0x18C)
        titleVersion = r.u16(tmd + 0x1DC)
        let n = Int(r.u16(tmd + 0x1DE))
        var cs: [Content] = [], offs: [Int] = []
        for i in 0..<n {
            let c = tmd + 0x1E4 + i * 36
            let ct = Content(id: r.u32(c), index: r.u16(c + 4), type: r.u16(c + 6), size: Int(r.u64(c + 8)), sha1: r.bytes(c + 16, 20))
            cs.append(ct); offs.append(off)
            off += roundUp(roundUp(ct.size, 16), 0x40)
        }
        contents = cs; contentOffsets = offs

        var iv = r.bytes(tik + 0x1DC, 8) + [UInt8](repeating: 0, count: 8)
        titleKey = try ESTitle.aesCBCDecrypt(key: commonKey, iv: &iv, r.bytes(tik + 0x1BF, 16))
    }

    /// Decrypted content by TMD index (what the channel sees via CNTOpen / contents of its own title).
    public func content(index: UInt16) throws -> [UInt8] {
        if let c = cache[index] { return c }
        guard let i = contents.firstIndex(where: { $0.index == index }) else { throw RVLError.missing("content index \(index)") }
        let c = contents[i]
        var iv = [UInt8(index >> 8), UInt8(index & 0xFF)] + [UInt8](repeating: 0, count: 14)
        let enc = Array(wad[contentOffsets[i]..<(contentOffsets[i] + roundUp(c.size, 16))])
        let dec = Array(try ESTitle.aesCBCDecrypt(key: titleKey, iv: &iv, enc).prefix(c.size))
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        dec.withUnsafeBytes { _ = CC_SHA1($0.baseAddress, CC_LONG(dec.count), &digest) }
        guard digest == c.sha1 else { throw RVLError.corrupt("content \(index) hash mismatch") }
        cache[index] = dec
        return dec
    }

    /// Content index → U8 archive.
    public func archive(index: UInt16) throws -> ARCArchive { try ARCArchive(content(index: index)) }

    static func aesCBCDecrypt(key: [UInt8], iv: inout [UInt8], _ data: [UInt8]) throws -> [UInt8] {
        var out = [UInt8](repeating: 0, count: data.count)
        var moved = 0
        let status = CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES128), 0,
                             key, key.count, &iv, data, data.count, &out, out.count, &moved)
        guard status == kCCSuccess else { throw RVLError.corrupt("AES status \(status)") }
        return out
    }
}
