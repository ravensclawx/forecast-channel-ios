import GX
import RVL
import simd

/// nw4r::g3d::ResMdl (MDL0, version 8/9 layout: 11 resource groups).
public struct ResMdl {
    public struct Bone {
        public let name: String, index: Int, flags: UInt32, billboard: UInt32
        public let scale: SIMD3<Float>, rotation: SIMD3<Float>, translation: SIMD3<Float>
        public let parent: Int?
        public let modelMtx: simd_float4x4 // bind-pose transform (rows of the stored 3x4)
    }

    /// Flattened polygon ready for upload: interleaved GXShaderGen.vertexStride layout, triangle list.
    public struct Shape {
        public let name: String, index: Int, bone: Int
        public var vertices: [Float]
        public var indices: [UInt32]
    }

    public struct VArray { public let values: [Float]; public let comps: Int }

    public struct DrawCall { public let material: Int, shape: Int, bone: Int, priority: Int }

    public let name: String
    public private(set) var bones: [Bone] = []
    public private(set) var materials: [ResMat] = []
    public private(set) var shapes: [Shape] = []
    public private(set) var drawOpa: [DrawCall] = []
    public private(set) var drawXlu: [DrawCall] = []

    init(_ r: BEReader, _ m: Int) throws {
        guard r.magic(m) == "MDL0" else { throw RVLError.badMagic(r.magic(m), expected: "MDL0") }
        let version = r.u32(m + 8)
        guard version == 8 || version == 9 else { throw RVLError.corrupt("MDL0 v\(version) not supported yet") }
        let sec = (0..<11).map { Int(r.s32(m + 0x10 + $0 * 4)) }
        name = r.cString(m + Int(r.s32(m + 0x3C)))
        func group(_ i: Int) -> [(String, Int)] { sec[i] == 0 ? [] : ResDic.entries(r, m + sec[i]) }

        // Bones
        let boneEntries = group(1)
        var boneOffsetToIndex: [Int: Int] = [:]
        for (i, (_, o)) in boneEntries.enumerated() { boneOffsetToIndex[o] = i }
        for (i, (nm, o)) in boneEntries.enumerated() {
            let po = Int(r.s32(o + 0x5C))
            var mtx = matrix_identity_float4x4
            for row in 0..<3 { for col in 0..<4 { mtx[col][row] = r.f32(o + 0x6C + (row * 4 + col) * 4) } }
            bones.append(Bone(name: nm, index: i, flags: r.u32(o + 0x14), billboard: r.u32(o + 0x18),
                              scale: SIMD3(r.f32(o + 0x20), r.f32(o + 0x24), r.f32(o + 0x28)),
                              rotation: SIMD3(r.f32(o + 0x2C), r.f32(o + 0x30), r.f32(o + 0x34)),
                              translation: SIMD3(r.f32(o + 0x38), r.f32(o + 0x3C), r.f32(o + 0x40)),
                              parent: po == 0 ? nil : boneOffsetToIndex[o + po], modelMtx: mtx))
        }

        // Vertex arrays, indexed by their resource "index" field
        func arrays(_ sec: Int, comps: (UInt32) -> Int) -> [Int: VArray] {
            var out: [Int: VArray] = [:]
            for (_, o) in group(sec) {
                let data = o + Int(r.s32(o + 8)), idx = Int(r.u32(o + 0x10))
                let ncomp = comps(r.u32(o + 0x14)), fmt = r.u32(o + 0x18)
                let shift = Int(r.u8(o + 0x1C)), stride = Int(r.u8(o + 0x1D)), count = Int(r.u16(o + 0x1E))
                let div = Float(1 << shift)
                var a = [Float](); a.reserveCapacity(count * ncomp)
                for v in 0..<count {
                    for c in 0..<ncomp {
                        let p = data + v * stride
                        switch fmt {
                        case 0: a.append(Float(r.u8(p + c)) / div)
                        case 1: a.append(Float(r.s8(p + c)) / div)
                        case 2: a.append(Float(r.u16(p + c * 2)) / div)
                        case 3: a.append(Float(r.s16(p + c * 2)) / div)
                        default: a.append(r.f32(p + c * 4))
                        }
                    }
                }
                out[idx] = VArray(values: a, comps: ncomp)
            }
            return out
        }
        let positions = arrays(2) { $0 == 0 ? 2 : 3 }
        let normals = arrays(3) { _ in 3 }       // NBT arrays: we use the N of each triple via stride
        let uvs = arrays(5) { $0 == 0 ? 1 : 2 }
        let colors = ResMdl.colorArrays(r, group(4))

        // Materials (need shader section offsets)
        for (i, (nm, o)) in group(6).enumerated() { materials.append(ResMat(r, o, name: nm, index: i)) }

        // Shapes
        for (nm, o) in group(8) {
            shapes.append(try ResMdl.loadShape(r, o, name: nm, positions: positions, normals: normals, colors: colors, uvs: uvs))
        }
        shapes.sort { $0.index < $1.index }

        // Draw lists
        let defs = Dictionary(uniqueKeysWithValues: group(0))
        func draws(_ key: String) -> [DrawCall] {
            guard var p = defs[key] else { return [] }
            var out: [DrawCall] = []
            while r.u8(p) == 0x04 {
                out.append(DrawCall(material: Int(r.u16(p + 1)), shape: Int(r.u16(p + 3)), bone: Int(r.u16(p + 5)), priority: Int(r.u8(p + 7))))
                p += 8
            }
            return out
        }
        drawOpa = draws("DrawOpa"); drawXlu = draws("DrawXlu")
    }

    static func colorArrays(_ r: BEReader, _ entries: [(String, Int)]) -> [Int: [Float]] {
        var out: [Int: [Float]] = [:]
        for (_, o) in entries {
            let data = o + Int(r.s32(o + 8)), idx = Int(r.u32(o + 0x10)), fmt = r.u32(o + 0x18)
            let stride = Int(r.u8(o + 0x1C)), count = Int(r.u16(o + 0x1E))
            var a = [Float]()
            for v in 0..<count {
                let p = data + v * stride
                var c: (Float, Float, Float, Float)
                switch fmt {
                case 0: let x = Int(r.u16(p)); c = (Float((x >> 11) & 31) / 31, Float((x >> 5) & 63) / 63, Float(x & 31) / 31, 1)
                case 1, 2: c = (Float(r.u8(p)) / 255, Float(r.u8(p + 1)) / 255, Float(r.u8(p + 2)) / 255, 1)
                case 3: let x = Int(r.u16(p)); c = (Float((x >> 12) & 15) / 15, Float((x >> 8) & 15) / 15, Float((x >> 4) & 15) / 15, Float(x & 15) / 15)
                case 4: let x = Int(r.u8(p)) << 16 | Int(r.u8(p + 1)) << 8 | Int(r.u8(p + 2))
                    c = (Float((x >> 18) & 63) / 63, Float((x >> 12) & 63) / 63, Float((x >> 6) & 63) / 63, Float(x & 63) / 63)
                default: c = (Float(r.u8(p)) / 255, Float(r.u8(p + 1)) / 255, Float(r.u8(p + 2)) / 255, Float(r.u8(p + 3)) / 255)
                }
                a += [c.0, c.1, c.2, c.3]
            }
            out[idx] = a
        }
        return out
    }

    /// Emulates the GX vertex loader over the polygon's primitive display list.
    static func loadShape(_ r: BEReader, _ o: Int, name: String, positions: [Int: VArray], normals: [Int: VArray],
                          colors: [Int: [Float]], uvs: [Int: VArray]) throws -> Shape {
        let vcdLo = r.u32(o + 0x0C), vcdHi = r.u32(o + 0x10)
        let primSize = Int(r.u32(o + 0x24)), primOff = o + 0x24 + Int(r.s32(o + 0x2C))
        let index = Int(r.u32(o + 0x3C))
        let posID = Int(r.s16(o + 0x48)), nrmID = Int(r.s16(o + 0x4A)), clrID = Int(r.s16(o + 0x4C))
        let uvIDs = (0..<8).map { Int(r.s16(o + 0x50 + $0 * 2)) }

        // Attribute list in GX order with their encodings (0 none, 1 direct, 2 idx8, 3 idx16)
        let pnmtx = vcdLo & 1, texmtx = (0..<8).map { (vcdLo >> (1 + $0)) & 1 }
        let pos = (vcdLo >> 9) & 3, nrm = (vcdLo >> 11) & 3, clr0 = (vcdLo >> 13) & 3, clr1 = (vcdLo >> 15) & 3
        let tex = (0..<8).map { (vcdHi >> ($0 * 2)) & 3 }
        for (kind, v) in [("pos", pos), ("nrm", nrm), ("clr0", clr0), ("clr1", clr1)] + tex.enumerated().map({ ("tex\($0.offset)", $0.element) }) where v == 1 {
            throw RVLError.corrupt("\(name): direct \(kind) attributes need VAT decoding (not used by NW4R models)")
        }
        func idxSize(_ v: UInt32) -> Int { v == 2 ? 1 : v == 3 ? 2 : 0 }

        var verts: [Float] = [], indices: [UInt32] = []
        var p = primOff
        let end = primOff + primSize
        let stride = GXShaderGen.vertexStride / 4
        let P = posID >= 0 ? positions[posID] : nil, N = nrmID >= 0 ? normals[nrmID] : nil
        let C = clrID >= 0 ? colors[clrID] : nil
        let T = uvIDs.map { $0 >= 0 ? uvs[$0] : nil }

        func readIdx(_ enc: UInt32) -> Int {
            switch enc { case 2: defer { p += 1 }; return Int(r.u8(p)); case 3: defer { p += 2 }; return Int(r.u16(p)); default: return -1 }
        }
        while p < end {
            let cmd = r.u8(p)
            switch cmd {
            case 0x00: p += 1; continue
            case 0x20, 0x28, 0x30, 0x38: p += 5; continue // indexed XF matrix loads (skinning); single-bind models ignore
            case 0x80...0xBF:
                let prim = cmd & 0xF8, count = Int(r.u16(p + 1)); p += 3
                let base = UInt32(verts.count / stride)
                for _ in 0..<count {
                    if pnmtx != 0 { p += 1 }
                    for t in texmtx where t != 0 { p += 1 }
                    var v = [Float](repeating: 0, count: stride)
                    v[6] = 1; v[7] = 1; v[8] = 1; v[9] = 1
                    let pi = readIdx(pos)
                    if let P, pi >= 0 { for k in 0..<P.comps { v[k] = P.values[pi * P.comps + k] } }
                    let ni = readIdx(nrm)
                    if let N, ni >= 0 { for k in 0..<3 { v[3 + k] = N.values[ni * 3 + k] } }
                    let ci = readIdx(clr0)
                    if let C, ci >= 0 { for k in 0..<4 { v[6 + k] = C[ci * 4 + k] } }
                    _ = readIdx(clr1)
                    for t in 0..<8 {
                        let ti = readIdx(tex[t])
                        if let arr = T[t], ti >= 0 { for k in 0..<arr.comps { v[10 + t * 2 + k] = arr.values[ti * arr.comps + k] } }
                    }
                    verts += v
                }
                indices += ResMdl.triangulate(prim: prim, count: count, base: base)
                _ = idxSize
            default:
                throw RVLError.corrupt("\(name): unknown GX command 0x\(String(cmd, radix: 16)) at \(p - primOff)")
            }
        }
        return Shape(name: name, index: index, bone: Int(r.s32(o + 0x08)), vertices: verts, indices: indices)
    }

    /// GX primitive → triangle list, preserving GX winding (strip parity as the hardware does).
    static func triangulate(prim: UInt8, count: Int, base: UInt32) -> [UInt32] {
        var out: [UInt32] = []
        switch prim {
        case 0x90: for i in stride(from: 0, to: count - 2, by: 3) { out += [base + UInt32(i), base + UInt32(i + 1), base + UInt32(i + 2)] }
        case 0x98:
            for i in 0..<max(count - 2, 0) {
                let a = base + UInt32(i)
                out += i & 1 == 0 ? [a, a + 1, a + 2] : [a + 1, a, a + 2]
            }
        case 0xA0: for i in 1..<max(count - 1, 1) { out += [base, base + UInt32(i), base + UInt32(i + 1)] }
        case 0x80, 0x88:
            for i in stride(from: 0, to: count - 3, by: 4) {
                let a = base + UInt32(i)
                out += [a, a + 1, a + 2, a, a + 2, a + 3]
            }
        default: break // lines/points: not used by g3d models here
        }
        return out
    }
}

/// nw4r::g3d::ResMat + its ResShp-independent shader (ResTev).
public struct ResMat {
    public struct Layer {
        public let texture: String, texMap: Int, wrapS: Int, wrapT: Int, minFilter: Int, magFilter: Int, lodBias: Float
    }
    /// ResMatTexCoordGen SRT (per layer slot) and TexMtxEffect.
    public struct TexSRT { public var scale: SIMD2<Float>, rotation: Float, translation: SIMD2<Float> }
    public struct TexEffect { public var camera: Int8, light: Int8, mapMode: UInt8, identity: Bool, matrix: [Float] }

    public let name: String, index: Int
    public let isXlu: Bool
    public let cullMode: UInt32
    public let lightSet: Int8, fogSet: Int8
    public let layers: [Layer]
    public let texMtxMode: UInt32
    public let srtFlags: UInt32
    public var srt: [TexSRT]
    public var effects: [TexEffect]
    public var gx: GXState

    init(_ r: BEReader, _ o: Int, name: String, index: Int) {
        self.name = name; self.index = index
        isXlu = r.u32(o + 0x10) & 0x8000_0000 != 0
        cullMode = r.u32(o + 0x18)
        lightSet = r.s8(o + 0x1D); fogSet = r.s8(o + 0x1E)
        var gx = GXState()
        gx.numTexGens = Int(r.u8(o + 0x14)); gx.numChans = Int(r.u8(o + 0x15))
        gx.numTevStages = Int(r.u8(o + 0x16)); gx.numIndStages = Int(r.u8(o + 0x17))

        let ntex = Int(r.u32(o + 0x2C)), layerOff = o + Int(r.s32(o + 0x30))
        layers = (0..<ntex).map { i in
            let l = layerOff + i * 0x34
            return Layer(texture: r.cString(l + Int(r.s32(l))), texMap: Int(r.u32(l + 0x10)),
                         wrapS: Int(r.u32(l + 0x18)), wrapT: Int(r.u32(l + 0x1C)),
                         minFilter: Int(r.u32(l + 0x20)), magFilter: Int(r.u32(l + 0x24)), lodBias: r.f32(l + 0x28))
        }
        srtFlags = r.u32(o + 0x1A4); texMtxMode = r.u32(o + 0x1A8)
        srt = (0..<8).map { i in
            let s = o + 0x1AC + i * 0x14
            return TexSRT(scale: SIMD2(r.f32(s), r.f32(s + 4)), rotation: r.f32(s + 8), translation: SIMD2(r.f32(s + 12), r.f32(s + 16)))
        }
        effects = (0..<8).map { i in
            let e = o + 0x24C + i * 0x34
            return TexEffect(camera: r.s8(e), light: r.s8(e + 1), mapMode: r.u8(e + 2), identity: r.u8(e + 3) & 1 == 1,
                             matrix: (0..<12).map { r.f32(e + 4 + $0 * 4) })
        }
        // Light channels (nw4r programs these with GXSetChanCtrl / GXSetChanMatColor / GXSetChanAmbColor).
        for c in 0..<2 {
            let ch = o + 0x3EC + c * 0x14
            gx.chanMatColor[c] = r.u32(ch + 4); gx.chanAmbColor[c] = r.u32(ch + 8)
            gx.chanColorCtrl[c] = r.u32(ch + 0xC); gx.chanAlphaCtrl[c] = r.u32(ch + 0x10)
        }
        // Shader (TEV) display list, then the material's own display list.
        let sh = o + Int(r.s32(o + 0x28))
        gx.apply(displayList: r.bytes(sh + 0x20, Int(r.u32(sh)) - 0x20))
        let dlOff = o + Int(r.s32(o + 0x38)), size = Int(r.u32(o))
        gx.apply(displayList: r.bytes(dlOff, o + size - dlOff))
        self.gx = gx
    }
}
