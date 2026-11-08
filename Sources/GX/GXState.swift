/// A software model of the GX register state that matters for shading.
/// Display lists from NW4R resources (material/shader DLs) are fed through `apply(displayList:)`,
/// exactly as the console's command processor would consume them. Bitfields follow Dolphin's
/// BPMemory.h / XFMemory.h.
public struct GXState: Hashable, Sendable {
    // genMode (nw4r sets this from ResMat counts via GXSetNumTexGens/NumChans/NumTevStages/NumIndStages)
    public var numTexGens = 0
    public var numChans = 0
    public var numTevStages = 1
    public var numIndStages = 0

    // BP memory (raw, 0x00-0xFF), with masked writes.
    public var bp = [UInt32](repeating: 0, count: 256)
    // Konst colors (BP 0xE0-0xE7 with type bit set) and TEV color registers (prev, c0, c1, c2) are
    // split by the "konst" bit on write.
    public var konst = [SIMD4<Int32>](repeating: .zero, count: 4)
    public var tevRegs = [SIMD4<Int32>](repeating: .zero, count: 4)

    // XF texgen registers: 0x1040+i TexMtxInfo, 0x1050+i PostMtxInfo.
    public var texMtxInfo = [UInt32](repeating: 0, count: 8)
    public var postMtxInfo = [UInt32](repeating: 0, count: 8)
    // XF color channel controls (0x100E-0x1011): color0, color1, alpha0, alpha1.
    public var chanColorCtrl = [UInt32](repeating: 0, count: 2)
    public var chanAlphaCtrl = [UInt32](repeating: 0, count: 2)
    public var chanMatColor = [UInt32](repeating: 0xFFFF_FFFF, count: 2)
    public var chanAmbColor = [UInt32](repeating: 0, count: 2)

    private var bpMask: UInt32 = 0xFF_FFFF

    public init() {}

    public mutating func writeBP(_ reg: UInt8, _ value: UInt32) {
        let r = Int(reg)
        if r == 0xFE { bpMask = value & 0xFF_FFFF; return }
        let v = (bp[r] & ~bpMask) | (value & bpMask)
        bpMask = 0xFF_FFFF
        bp[r] = v
        if (0xE0...0xE7).contains(r) {
            let i = (r - 0xE0) / 2
            let isKonst = v & (1 << 23) != 0
            let lo = (Int32(v & 0x7FF) << 21) >> 21
            let hi = (Int32((v >> 12) & 0x7FF) << 21) >> 21
            if r & 1 == 0 { // RA
                if isKonst { konst[i].x = lo; konst[i].w = hi } else { tevRegs[i].x = lo; tevRegs[i].w = hi }
            } else {        // BG
                if isKonst { konst[i].z = lo; konst[i].y = hi } else { tevRegs[i].z = lo; tevRegs[i].y = hi }
            }
        }
    }

    public mutating func writeXF(_ addr: UInt16, _ v: UInt32) {
        switch addr {
        case 0x1040...0x1047: texMtxInfo[Int(addr - 0x1040)] = v
        case 0x1050...0x1057: postMtxInfo[Int(addr - 0x1050)] = v
        case 0x100E...0x100F: chanColorCtrl[Int(addr - 0x100E)] = v
        case 0x1010...0x1011: chanAlphaCtrl[Int(addr - 0x1010)] = v
        case 0x100A...0x100B: chanAmbColor[Int(addr - 0x100A)] = v
        case 0x100C...0x100D: chanMatColor[Int(addr - 0x100C)] = v
        default: break
        }
    }

    /// Consume a GX display list containing register loads (0x61 BP, 0x10 XF, 0x08 CP, NOPs).
    public mutating func apply(displayList d: [UInt8]) {
        var i = 0
        while i < d.count {
            switch d[i] {
            case 0x00: i += 1
            case 0x61:
                guard i + 5 <= d.count else { return }
                writeBP(d[i + 1], UInt32(d[i + 2]) << 16 | UInt32(d[i + 3]) << 8 | UInt32(d[i + 4])); i += 5
            case 0x10:
                guard i + 5 <= d.count else { return }
                let n = Int(UInt16(d[i + 1]) << 8 | UInt16(d[i + 2])) + 1
                let a = UInt16(d[i + 3]) << 8 | UInt16(d[i + 4])
                for k in 0..<n {
                    let o = i + 5 + k * 4
                    writeXF(a + UInt16(k), UInt32(d[o]) << 24 | UInt32(d[o + 1]) << 16 | UInt32(d[o + 2]) << 8 | UInt32(d[o + 3]))
                }
                i += 5 + n * 4
            case 0x08: i += 6 // CP register load; vertex format state is handled by the vertex loader
            default: return // primitives or unknown: stop (register DLs never contain them)
            }
        }
    }

    // MARK: - Decoded views

    public struct TevStage: Hashable, Sendable {
        public var cc: UInt32, ac: UInt32, ind: UInt32
        public var texMap: Int, texCoord: Int, texEnable: Bool, colorChan: Int
        public var kcsel: Int, kasel: Int
    }

    public func tevStage(_ n: Int) -> TevStage {
        let order = bp[0x28 + n / 2] >> (n & 1 == 1 ? 12 : 0)
        let ksel = bp[0xF6 + n / 2]
        return TevStage(
            cc: bp[0xC0 + n * 2], ac: bp[0xC1 + n * 2], ind: bp[0x10 + n],
            texMap: Int(order & 7), texCoord: Int((order >> 3) & 7), texEnable: (order >> 6) & 1 == 1,
            colorChan: Int((order >> 7) & 7),
            kcsel: Int((ksel >> (n & 1 == 1 ? 14 : 4)) & 0x1F), kasel: Int((ksel >> (n & 1 == 1 ? 19 : 9)) & 0x1F))
    }

    /// Swap table i → (r,g,b,a) channel indices.
    public func swapTable(_ i: Int) -> [Int] {
        let rg = bp[0xF6 + i * 2], ba = bp[0xF6 + i * 2 + 1]
        return [Int(rg & 3), Int((rg >> 2) & 3), Int(ba & 3), Int((ba >> 2) & 3)]
    }

    /// Indirect stage i → (texMap, texCoord) from RAS1_IREF (0x27).
    public func indRef(_ i: Int) -> (map: Int, coord: Int) {
        let v = bp[0x27] >> (i * 6)
        return (Int(v & 7), Int((v >> 3) & 7))
    }

    /// Indirect coordinate scale shifts (RAS1_SS0/SS1) for stage i → (s, t).
    public func indScale(_ i: Int) -> (Int, Int) {
        let v = bp[0x25 + i / 2] >> ((i & 1) * 8)
        return (Int(v & 0xF), Int((v >> 4) & 0xF))
    }

    /// Indirect matrix m (0..2): rows (ma mc me), (mb md mf) as s11 ints, plus Dolphin's `17 - scale` shift.
    public func indMatrix(_ m: Int) -> (row0: SIMD3<Int32>, row1: SIMD3<Int32>, shift: Int32) {
        let a = bp[0x06 + m * 3], b = bp[0x07 + m * 3], c = bp[0x08 + m * 3]
        func s11(_ v: UInt32) -> Int32 { (Int32(v & 0x7FF) << 21) >> 21 }
        let scale = Int32((a >> 22) & 3) | Int32((b >> 22) & 3) << 2 | Int32((c >> 22) & 1) << 4
        return (SIMD3(s11(a), s11(b), s11(c)), SIMD3(s11(a >> 11), s11(b >> 11), s11(c >> 11)), 17 - scale)
    }

    /// GXSetIndTexMatrix(id, offset[2][3], scaleExp): entries in [-1,1) as s11 (x1024), scale biased by 17.
    public mutating func setIndMatrix(_ m: Int, row0: SIMD3<Float>, row1: SIMD3<Float>, scaleExp: Int32) {
        func s11(_ v: Float) -> UInt32 { UInt32(bitPattern: Int32((v * 1024).rounded(.towardZero))) & 0x7FF }
        let scale = UInt32(bitPattern: scaleExp + 17)
        bp[0x06 + m * 3] = s11(row0.x) | s11(row1.x) << 11 | (scale & 3) << 22
        bp[0x07 + m * 3] = s11(row0.y) | s11(row1.y) << 11 | ((scale >> 2) & 3) << 22
        bp[0x08 + m * 3] = s11(row0.z) | s11(row1.z) << 11 | ((scale >> 4) & 1) << 22
    }

    public struct AlphaCompare: Hashable, Sendable { public var ref0: Int, ref1: Int, comp0: Int, comp1: Int, logic: Int }
    public var alphaCompare: AlphaCompare {
        let v = bp[0xF3]
        return AlphaCompare(ref0: Int(v & 0xFF), ref1: Int((v >> 8) & 0xFF), comp0: Int((v >> 16) & 7),
                            comp1: Int((v >> 19) & 7), logic: Int((v >> 22) & 3))
    }

    public struct ZMode: Hashable, Sendable { public var test: Bool, function: Int, update: Bool }
    public var zMode: ZMode { let v = bp[0x40]; return ZMode(test: v & 1 == 1, function: Int((v >> 1) & 7), update: (v >> 4) & 1 == 1) }

    public struct BlendMode: Hashable, Sendable {
        public var enable: Bool, logicOp: Bool, subtract: Bool, srcFactor: Int, dstFactor: Int, logicMode: Int
    }
    public var blendMode: BlendMode {
        let v = bp[0x41]
        return BlendMode(enable: v & 1 == 1, logicOp: (v >> 1) & 1 == 1, subtract: (v >> 11) & 1 == 1,
                         srcFactor: Int((v >> 8) & 7), dstFactor: Int((v >> 5) & 7), logicMode: Int((v >> 12) & 0xF))
    }

    public struct TexGen: Hashable, Sendable {
        public var projectionSTQ: Bool, inputABC1: Bool, type: Int, sourceRow: Int, embossSource: Int, embossLight: Int
        public var postMatrix: Int, normalize: Bool
    }
    public func texGen(_ i: Int) -> TexGen {
        let v = texMtxInfo[i], p = postMtxInfo[i]
        return TexGen(projectionSTQ: (v >> 1) & 1 == 1, inputABC1: (v >> 2) & 1 == 1, type: Int((v >> 4) & 7),
                      sourceRow: Int((v >> 7) & 0x1F), embossSource: Int((v >> 12) & 7), embossLight: Int((v >> 15) & 7),
                      postMatrix: Int(p & 0x3F), normalize: (p >> 8) & 1 == 1)
    }
}
