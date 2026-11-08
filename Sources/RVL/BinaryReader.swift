import Foundation

/// Big-endian reader over Wii data. All Revolution formats are big-endian.
public struct BEReader {
    public let data: [UInt8]
    public init(_ data: [UInt8]) { self.data = data }
    public init(_ data: Data) { self.data = [UInt8](data) }

    @inline(__always) public func u8(_ o: Int) -> UInt8 { data[o] }
    @inline(__always) public func s8(_ o: Int) -> Int8 { Int8(bitPattern: data[o]) }
    @inline(__always) public func u16(_ o: Int) -> UInt16 { UInt16(data[o]) << 8 | UInt16(data[o + 1]) }
    @inline(__always) public func s16(_ o: Int) -> Int16 { Int16(bitPattern: u16(o)) }
    @inline(__always) public func u32(_ o: Int) -> UInt32 {
        UInt32(data[o]) << 24 | UInt32(data[o + 1]) << 16 | UInt32(data[o + 2]) << 8 | UInt32(data[o + 3])
    }
    @inline(__always) public func s32(_ o: Int) -> Int32 { Int32(bitPattern: u32(o)) }
    @inline(__always) public func u64(_ o: Int) -> UInt64 { UInt64(u32(o)) << 32 | UInt64(u32(o + 4)) }
    @inline(__always) public func f32(_ o: Int) -> Float { Float(bitPattern: u32(o)) }

    public func bytes(_ o: Int, _ n: Int) -> [UInt8] { Array(data[o..<(o + n)]) }
    public func slice(_ o: Int, _ n: Int) -> BEReader { BEReader(bytes(o, n)) }
    public func magic(_ o: Int) -> String { String(decoding: data[o..<(o + 4)], as: UTF8.self) }

    /// NUL-terminated string.
    public func cString(_ o: Int) -> String {
        var e = o
        while e < data.count, data[e] != 0 { e += 1 }
        return String(decoding: data[o..<e], as: UTF8.self)
    }
}

public enum RVLError: Error, CustomStringConvertible {
    case badMagic(String, expected: String)
    case corrupt(String)
    case missing(String)
    public var description: String {
        switch self {
        case let .badMagic(got, exp): "bad magic '\(got)', expected '\(exp)'"
        case let .corrupt(s): "corrupt data: \(s)"
        case let .missing(s): "missing: \(s)"
        }
    }
}

@inline(__always) public func roundUp(_ n: Int, _ a: Int) -> Int { (n + a - 1) & ~(a - 1) }
