/// Replacement for the RVL SDK ARC library (U8 archives, magic 0x55AA382D).
/// Paths resolve like ARCOpen/ARCConvertPathToEntrynum: "/arc/blyt/forecast.brlyt".
public struct ARCArchive {
    public struct Entry { public let name: String; public let isDir: Bool; public let offset: Int; public let size: Int }
    public let data: [UInt8]
    public private(set) var files: [String: Range<Int>] = [:]

    public init(_ bytes: [UInt8]) throws {
        let r = BEReader(bytes)
        guard r.u32(0) == 0x55AA_382D else { throw RVLError.badMagic(r.magic(0), expected: "U8") }
        data = bytes
        let root = Int(r.u32(4))
        let count = Int(r.u32(root + 8))
        let strings = root + count * 12
        var stack: [(end: Int, path: String)] = [(count, "")]
        var i = 1
        while i < count {
            while let top = stack.last, i >= top.end { stack.removeLast() }
            let e = root + i * 12
            let type = r.u8(e)
            let nameOff = Int(r.u32(e) & 0x00FF_FFFF)
            let a = Int(r.u32(e + 4)), b = Int(r.u32(e + 8))
            let name = r.cString(strings + nameOff)
            // "." directories are the archive's current-dir root (ARCConvertPathToEntrynum skips them).
            let path = name == "." ? (stack.last?.path ?? "") : (stack.last?.path ?? "") + "/" + name
            if type == 1 { stack.append((b, path)) } else { files[path] = a..<(a + b) }
            i += 1
        }
    }

    public func file(_ path: String) -> [UInt8]? {
        let p = path.hasPrefix("/") ? path : "/" + path
        if let r = files[p] { return Array(data[r]) }
        // ARC lookups are case-insensitive on the console.
        if let (_, r) = files.first(where: { $0.key.caseInsensitiveCompare(p) == .orderedSame }) { return Array(data[r]) }
        return nil
    }

    /// Find a file by name anywhere in the archive (the channel often opens by bare name).
    public func find(_ name: String) -> [UInt8]? {
        if let hit = files.first(where: { $0.key.split(separator: "/").last.map(String.init)?.caseInsensitiveCompare(name) == .orderedSame }) {
            return Array(data[hit.value])
        }
        return nil
    }
}
