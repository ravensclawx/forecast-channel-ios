import Foundation

/// SaveData_Load (fn_8000BAD4) / SaveData_Store (fn_8000BCCC): NAND "noerase/savedata.dat", 0x20 bytes.
///   +0 'HAF0'  +4 country  +8 location ID  +C temp unit (0 °C, 1 °F)  +10 wind unit (0 mph, 1 km/h)  +1C CRC32(0..1B)
/// Stored under ~/Library/Application Support/ForecastChannel/noerase/savedata.dat.
public struct SaveData: Equatable {
    public var country: UInt32 = 0
    public var location: UInt32 = 0
    public var tempUnit: UInt32 = 0
    public var windUnit: UInt32 = 0

    public static let size = 0x20
    public static var url: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("ForecastChannel/noerase/savedata.dat")

    /// Load result codes as returned by SaveData_Load: 0 ok, 1 no file, 2 broken, 3 NAND error.
    public enum LoadResult: Int { case ok = 0, noFile, broken, nandError }

    public static func load(from url: URL = SaveData.url) -> (LoadResult, SaveData) {
        guard FileManager.default.fileExists(atPath: url.path) else { return (.noFile, SaveData()) }
        guard let d = try? Data(contentsOf: url) else { return (.nandError, SaveData()) }
        let b = [UInt8](d)
        guard b.count == size else { return (.broken, SaveData()) }
        func u32(_ o: Int) -> UInt32 { UInt32(b[o]) << 24 | UInt32(b[o + 1]) << 16 | UInt32(b[o + 2]) << 8 | UInt32(b[o + 3]) }
        guard CRC32.checksum(b[0..<0x1C]) == u32(0x1C) else { return (.broken, SaveData()) }
        guard b[0..<4].elementsEqual("HAF0".utf8) else { return (.broken, SaveData()) }
        return (.ok, SaveData(country: u32(4), location: u32(8), tempUnit: u32(0xC), windUnit: u32(0x10)))
    }

    public func bytes() -> [UInt8] {
        var b = [UInt8](repeating: 0, count: SaveData.size)
        b.replaceSubrange(0..<4, with: Array("HAF0".utf8))
        func put(_ o: Int, _ v: UInt32) { for i in 0..<4 { b[o + i] = UInt8((v >> (24 - 8 * UInt32(i))) & 0xFF) } }
        put(4, country); put(8, location); put(0xC, tempUnit); put(0x10, windUnit)
        put(0x1C, CRC32.checksum(b[0..<0x1C]))
        return b
    }

    /// Store result: 0 ok, 3 NAND error (anything else the original maps to "unable to save").
    @discardableResult
    public func store(to url: URL = SaveData.url) -> Int {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(bytes()).write(to: url, options: .atomic)
            return 0
        } catch { return 3 }
    }
}
