/// Read-only view of a DOL executable by virtual address (used to pull constant tables out of main.dol at runtime).
public struct DOLImage {
    public let bytes: [UInt8]
    private let sections: [(file: Int, addr: UInt32, size: Int)]
    public init(_ b: [UInt8]) {
        bytes = b
        let r = BEReader(b)
        sections = (0..<18).compactMap { i in
            let size = Int(r.u32(144 + i * 4))
            return size == 0 ? nil : (Int(r.u32(i * 4)), r.u32(72 + i * 4), size)
        }
    }
    public func offset(_ address: UInt32) -> Int? {
        for s in sections where address >= s.addr && address < s.addr + UInt32(s.size) { return s.file + Int(address - s.addr) }
        return nil
    }
    public func reader(_ address: UInt32) -> (BEReader, Int)? { offset(address).map { (BEReader(bytes), $0) } }
    public func u32(_ a: UInt32) -> UInt32 { offset(a).map { BEReader(bytes).u32($0) } ?? 0 }
    public func u16(_ a: UInt32) -> UInt16 { offset(a).map { BEReader(bytes).u16($0) } ?? 0 }
    public func f32(_ a: UInt32) -> Float { Float(bitPattern: u32(a)) }
}
