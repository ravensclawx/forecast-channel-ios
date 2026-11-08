import GX
import RVL

/// nw4r::g3d::ResFile — a BRRES container ("bres").
public struct ResFile {
    public let r: BEReader
    public private(set) var models: [String: ResMdl] = [:]
    public private(set) var textures: [String: ResTex] = [:]

    public init(_ bytes: [UInt8]) throws {
        r = BEReader(bytes)
        guard r.magic(0) == "bres" else { throw RVLError.badMagic(r.magic(0), expected: "bres") }
        let root = Int(r.u16(0xC))
        for (folder, fo) in ResDic.entries(r, root + 8) {
            for (name, o) in ResDic.entries(r, fo) {
                switch folder {
                case "3DModels(NW4R)": models[name] = try ResMdl(r, o)
                case "Textures(NW4R)": textures[name] = ResTex(r, o, name: name)
                default: break // animations (CHR0/CLR0/SRT0/PAT0/VIS0/SHP0/SCN0) parsed when the game needs them
                }
            }
        }
    }
}

/// nw4r::g3d::ResDic — the Patricia-tree dictionary used by every NW4R resource group.
public enum ResDic {
    /// Returns (name, absolute data offset) in dictionary order (entries 1...n).
    public static func entries(_ r: BEReader, _ off: Int) -> [(String, Int)] {
        let n = Int(r.u32(off + 4))
        return (1...max(n, 1)).compactMap { i in
            guard n > 0 else { return nil }
            let e = off + 8 + i * 16
            return (r.cString(off + Int(r.s32(e + 8))), off + Int(r.s32(e + 12)))
        }
    }
}

/// nw4r::g3d::ResTex (TEX0).
public struct ResTex {
    public let name: String
    public let width: Int, height: Int
    public let format: GXTexFmt
    public let mipCount: Int
    public let isCI: Bool
    let r: BEReader
    let dataOffset: Int

    init(_ r: BEReader, _ o: Int, name: String) {
        self.r = r; self.name = name
        isCI = r.u32(o + 0x18) != 0
        width = Int(r.u16(o + 0x1C)); height = Int(r.u16(o + 0x1E))
        format = GXTexFmt(rawValue: r.u32(o + 0x20)) ?? .rgba8
        mipCount = Int(r.u32(o + 0x24))
        dataOffset = o + Int(r.s32(o + 0x10))
    }

    public func rgba8() -> [UInt8] { GXTextureDecoder.decode(r.data, offset: dataOffset, width: width, height: height, format: format) }
    public func bc1() -> [UInt8]? {
        format == .cmpr ? GXTextureDecoder.cmprToBC1(r.data, offset: dataOffset, width: width, height: height) : nil
    }
}
