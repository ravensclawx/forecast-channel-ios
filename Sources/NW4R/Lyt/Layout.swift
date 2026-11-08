import GX
import RVL
import simd

/// nw4r::lyt — layout resources (RLYT v8) and the runtime pane tree.
public final class Layout {
    public let width: Float, height: Float
    public let originCentered: Bool
    public let textureNames: [String]
    public let fontNames: [String]
    public let materials: [LytMaterial]
    public let root: Pane
    public private(set) var groups: [String: [Pane]] = [:]

    public init(_ bytes: [UInt8]) throws {
        let r = BEReader(bytes)
        guard r.magic(0) == "RLYT" else { throw RVLError.badMagic(r.magic(0), expected: "RLYT") }
        var o = Int(r.u16(0xC))
        let count = Int(r.u16(0xE))
        var w: Float = 608, h: Float = 456, centered = true
        var texNames: [String] = [], fntNames: [String] = [], mats: [LytMaterial] = []
        var rootPane: Pane? = nil
        var last: Pane? = nil
        var stack: [Pane] = []
        var groupNames: [String: [String]] = [:]

        func nameList(_ s: Int) -> [String] {
            let n = Int(r.u16(s + 8)), base = s + 12
            return (0..<n).map { r.cString(base + Int(r.u32(base + $0 * 8))) }
        }
        for _ in 0..<count {
            let magic = r.magic(o), size = Int(r.u32(o + 4))
            switch magic {
            case "lyt1": centered = r.u8(o + 8) != 0; w = r.f32(o + 12); h = r.f32(o + 16)
            case "txl1": texNames = nameList(o)
            case "fnl1": fntNames = nameList(o)
            case "mat1":
                let n = Int(r.u16(o + 8))
                mats = (0..<n).map { LytMaterial(r, o + Int(r.u32(o + 12 + $0 * 4))) }
            case "pan1", "pic1", "txt1", "wnd1", "bnd1":
                let p: Pane
                switch magic {
                case "pic1": p = Picture(r, o)
                case "txt1": p = TextBox(r, o)
                case "wnd1": p = Window(r, o)
                case "bnd1": p = Bounding(r, o)
                default: p = Pane(r, o)
                }
                if let parent = stack.last { parent.append(p) } else if rootPane == nil { rootPane = p }
                last = p
            case "pas1": if let l = last { stack.append(l) }
            case "pae1": _ = stack.popLast()
            case "grp1":
                let name = r.cString(o + 8)
                let n = Int(r.u16(o + 0x18))
                groupNames[name] = (0..<n).map { r.cString(o + 0x1C + $0 * 16) }
            default: break
            }
            o += size
        }
        width = w; height = h; originCentered = centered
        textureNames = texNames; fontNames = fntNames; materials = mats
        root = rootPane ?? Pane(name: "RootPane")
        for (g, names) in groupNames { groups[g] = names.compactMap { root.find($0) } }
        // Bind materials/fonts by index
        root.forEach { p in
            if let pic = p as? Picture { pic.material = mats[safe: pic.materialIndex] }
            if let t = p as? TextBox { t.material = mats[safe: t.materialIndex]; t.fontName = fntNames[safe: t.fontIndex] }
            if let wnd = p as? Window { wnd.material = mats[safe: wnd.contentMaterialIndex] }
        }
    }

    /// Pane::FindPaneByName (recursive)
    public func find(_ name: String) -> Pane? { root.find(name) }
}

extension Array { public subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil } }

// MARK: - Panes

/// nw4r::lyt::Pane
public class Pane {
    public let name: String
    public var userData: String = ""
    public var visible = true
    public var influencedAlpha = false
    public var locationAdjust = false
    public var basePosition: UInt8 = 4   // 0..8: x = %3 (left,center,right), y = /3 (top,center,bottom)
    public var alpha: UInt8 = 255
    public var translate = SIMD3<Float>(0, 0, 0)
    public var rotate = SIMD3<Float>(0, 0, 0)
    public var scale = SIMD2<Float>(1, 1)
    public var size = SIMD2<Float>(0, 0)
    public private(set) var children: [Pane] = []
    public private(set) weak var parent: Pane?

    // Calculated each frame (Pane::CalculateMtx)
    public internal(set) var globalMtx = matrix_identity_float4x4
    public internal(set) var globalAlpha: UInt8 = 255

    init(name: String) { self.name = name }

    init(_ r: BEReader, _ o: Int) {
        let flags = r.u8(o + 8)
        visible = flags & 1 != 0; influencedAlpha = flags & 2 != 0; locationAdjust = flags & 4 != 0
        basePosition = r.u8(o + 9); alpha = r.u8(o + 0xA)
        name = r.cString(o + 0xC)
        userData = r.cString(o + 0x1C)
        translate = SIMD3(r.f32(o + 0x24), r.f32(o + 0x28), r.f32(o + 0x2C))
        rotate = SIMD3(r.f32(o + 0x30), r.f32(o + 0x34), r.f32(o + 0x38))
        scale = SIMD2(r.f32(o + 0x3C), r.f32(o + 0x40))
        size = SIMD2(r.f32(o + 0x44), r.f32(o + 0x48))
    }

    func append(_ c: Pane) { c.parent = self; children.append(c) }

    public func find(_ n: String) -> Pane? {
        if name == n { return self }
        for c in children { if let f = c.find(n) { return f } }
        return nil
    }
    public func forEach(_ body: (Pane) -> Void) { body(self); children.forEach { $0.forEach(body) } }

    /// Top-left of the pane rectangle in pane space (y up), from basePosition.
    public var vertexOrigin: SIMD2<Float> {
        let h = Int(basePosition % 3), v = Int(basePosition / 3)
        let x: Float = h == 0 ? 0 : (h == 1 ? -size.x / 2 : -size.x)
        let y: Float = v == 0 ? 0 : (v == 1 ? size.y / 2 : size.y)
        return SIMD2(x, y)
    }

    /// Pane::CalculateMtx — local = T · Rz · Ry · Rx · S; global = parent · local; glbAlpha propagation.
    /// `locationAdjust` = DrawInfo::GetLocationAdjustScale when DrawInfo::IsLocationAdjust (widescreen): panes
    /// flagged "location adjust" keep their position but have their own scale multiplied, undoing the stretch.
    public func calculate(parentMtx: simd_float4x4, parentAlpha: UInt8, locationAdjust: SIMD2<Float>? = nil, alphaScale: Int = 255) {
        func rot(_ deg: Float, _ axis: SIMD3<Float>) -> simd_float4x4 {
            deg == 0 ? matrix_identity_float4x4 : simd_float4x4(simd_quatf(angle: deg * .pi / 180, axis: axis))
        }
        var t = matrix_identity_float4x4; t.columns.3 = SIMD4(translate, 1)
        var sc = scale
        if let a = locationAdjust, self.locationAdjust { sc *= a }
        var s = matrix_identity_float4x4; s.columns.0.x = sc.x; s.columns.1.y = sc.y
        let local = t * rot(rotate.z, SIMD3(0, 0, 1)) * rot(rotate.y, SIMD3(0, 1, 0)) * rot(rotate.x, SIMD3(1, 0, 0)) * s
        globalMtx = parentMtx * local
        globalAlpha = influencedAlpha ? UInt8(Int(alpha) * Int(parentAlpha) / 255) : alpha
        let scale = alphaScale * Int(subtreeAlpha ?? 255) / 255
        let own = globalAlpha
        for c in children { c.calculate(parentMtx: globalMtx, parentAlpha: own, locationAdjust: locationAdjust, alphaScale: scale) }
        if scale < 255 { globalAlpha = UInt8(Int(globalAlpha) * scale / 255) }
    }
    /// fn_8003A35C → fn_8003927C: the hub's per-layout alpha. On the Wii it lands on each root pane's mGlbAlpha; the
    /// port applies it to the whole group so nested art (belt, wind strip) fades with its page.
    public var subtreeAlpha: UInt8?
    /// Never drawn, whatever the game sets `visible` to (iPhone: Wii-Remote button glyphs).
    public var suppressed = false
}

public final class Bounding: Pane {}

/// nw4r::lyt::Picture
public final class Picture: Pane {
    public var vtxColors: [SIMD4<UInt8>]     // TL, TR, BL, BR
    public let materialIndex: Int
    public var texCoords: [[SIMD2<Float>]]   // per texcoord set: TL, TR, BL, BR
    public var material: LytMaterial?
    /// iPhone portrait: an extra strip drawn past the picture's local bottom (or top) edge, starting `overlap` units inside
    /// the art (covers its edge highlight), `height` local units tall, every
    /// row sampling the texture at fraction `t` between its top (0) and bottom (1) texcoords — extends button art
    /// (and its live hover colours) to the screen edge without stretching the art itself.
    public var edgeStrip: (height: Float, t: Float, localTop: Bool, overlap: Float)?

    override init(_ r: BEReader, _ o: Int) {
        vtxColors = (0..<4).map { SIMD4(r.u8(o + 0x4C + $0 * 4), r.u8(o + 0x4D + $0 * 4), r.u8(o + 0x4E + $0 * 4), r.u8(o + 0x4F + $0 * 4)) }
        materialIndex = Int(r.u16(o + 0x5C))
        let n = Int(r.u8(o + 0x5E))
        texCoords = (0..<n).map { i in (0..<4).map { SIMD2(r.f32(o + 0x60 + i * 32 + $0 * 8), r.f32(o + 0x64 + i * 32 + $0 * 8)) } }
        super.init(r, o)
    }
}

/// nw4r::lyt::TextBox
public final class TextBox: Pane {
    public let bufferChars: Int
    public var text: [UInt16]
    public let materialIndex: Int, fontIndex: Int
    public var textPosition: UInt8, textAlignment: UInt8
    public var topColor: SIMD4<UInt8>, bottomColor: SIMD4<UInt8>
    public var fontSize: SIMD2<Float>
    public var charSpace: Float, lineSpace: Float
    public var material: LytMaterial?
    public var fontName: String?
    /// Font bound at runtime (the game supplies ResFont objects; nw4r resolves by fnl1 name).
    public var font: ResFont?

    override init(_ r: BEReader, _ o: Int) {
        bufferChars = Int(r.u16(o + 0x4C)) / 2
        let strBytes = Int(r.u16(o + 0x4E))
        materialIndex = Int(r.u16(o + 0x50)); fontIndex = Int(r.u16(o + 0x52))
        textPosition = r.u8(o + 0x54); textAlignment = r.u8(o + 0x55)
        let strOff = o + Int(r.u32(o + 0x58))
        topColor = SIMD4(r.u8(o + 0x5C), r.u8(o + 0x5D), r.u8(o + 0x5E), r.u8(o + 0x5F))
        bottomColor = SIMD4(r.u8(o + 0x60), r.u8(o + 0x61), r.u8(o + 0x62), r.u8(o + 0x63))
        fontSize = SIMD2(r.f32(o + 0x64), r.f32(o + 0x68))
        charSpace = r.f32(o + 0x6C); lineSpace = r.f32(o + 0x70)
        var t: [UInt16] = []
        var p = strOff
        while p + 1 < strOff + strBytes { let c = r.u16(p); if c == 0 { break }; t.append(c); p += 2 }
        text = t
        super.init(r, o)
    }

    /// TextBox::SetString
    public func setString(_ s: String) { text = Array(s.utf16).prefix(max(bufferChars, s.utf16.count)).map { $0 } }
    public var string: String { String(utf16CodeUnits: text, count: text.count) }
}

/// nw4r::lyt::Window (content + frames). Only the content quad is drawn for now.
public final class Window: Pane {
    public let contentMaterialIndex: Int
    public var material: LytMaterial?
    public var vtxColors: [SIMD4<UInt8>]
    public var texCoords: [[SIMD2<Float>]]
    override init(_ r: BEReader, _ o: Int) {
        let content = o + Int(r.u32(o + 0x60))
        vtxColors = (0..<4).map { SIMD4(r.u8(content + $0 * 4), r.u8(content + 1 + $0 * 4), r.u8(content + 2 + $0 * 4), r.u8(content + 3 + $0 * 4)) }
        contentMaterialIndex = Int(r.u16(content + 0x10))
        let n = Int(r.u8(content + 0x12))
        texCoords = (0..<n).map { i in (0..<4).map { SIMD2(r.f32(content + 0x14 + i * 32 + $0 * 8), r.f32(content + 0x18 + i * 32 + $0 * 8)) } }
        super.init(r, o)
    }
}

// MARK: - Material

/// nw4r::lyt::Material (resource form + runtime colors). `setupGX` is a port of fn_800E0568.
public final class LytMaterial {
    public struct TexMap { public let texture: Int; public var wrapS: UInt32, wrapT: UInt32; public let minFilter: UInt32, magFilter: UInt32 }
    public struct TexSRT { public var translate: SIMD2<Float>; public var rotate: Float; public var scale: SIMD2<Float> }
    public struct TexCoordGen { public let type: UInt32, src: UInt32, mtx: UInt32 }

    public let name: String
    public var tevColors: [SIMD4<Int32>]     // C0 (black), C1 (white), C2 — s16 GXColorS10
    public var tevKColors: [SIMD4<Int32>]
    public var texMaps: [TexMap]
    public var texSRTs: [TexSRT]
    public let texCoordGens: [TexCoordGen]
    public let chanCtrl: (color: UInt8, alpha: UInt8)?
    public var matColor: SIMD4<UInt8>?
    public let swapTable: [UInt8]?
    public let tevStages: [[UInt8]]          // raw 16-byte stage records
    public let alphaCompare: [UInt8]?
    public let blendMode: [UInt8]?
    /// RLTP texture-pattern animation: texMap slot → texture name (overrides the txl1 binding).
    public var texturePatternOverride: [Int: String] = [:]

    init(_ r: BEReader, _ o: Int) {
        name = r.cString(o)
        tevColors = (0..<3).map { i in SIMD4((0..<4).map { Int32(r.s16(o + 0x14 + i * 8 + $0 * 2)) }) }
        tevKColors = (0..<4).map { i in SIMD4((0..<4).map { Int32(r.u8(o + 0x2C + i * 4 + $0)) }) }
        let f = r.u32(o + 0x3C)
        var p = o + 0x40
        texMaps = (0..<Int(f & 0xF)).map { _ in
            defer { p += 4 }
            let ws = r.u8(p + 2), wt = r.u8(p + 3)
            return TexMap(texture: Int(r.u16(p)), wrapS: UInt32(ws & 3), wrapT: UInt32(wt & 3), minFilter: UInt32((ws >> 2) & 7), magFilter: UInt32((wt >> 2) & 1))
        }
        texSRTs = (0..<Int((f >> 4) & 0xF)).map { _ in
            defer { p += 20 }
            return TexSRT(translate: SIMD2(r.f32(p), r.f32(p + 4)), rotate: r.f32(p + 8), scale: SIMD2(r.f32(p + 12), r.f32(p + 16)))
        }
        texCoordGens = (0..<Int((f >> 8) & 0xF)).map { _ in
            defer { p += 4 }
            return TexCoordGen(type: UInt32(r.u8(p)), src: UInt32(r.u8(p + 1)), mtx: UInt32(r.u8(p + 2)))
        }
        if (f >> 25) & 1 == 1 { chanCtrl = (r.u8(p), r.u8(p + 1)); p += 4 } else { chanCtrl = nil }
        if (f >> 27) & 1 == 1 { matColor = SIMD4(r.u8(p), r.u8(p + 1), r.u8(p + 2), r.u8(p + 3)); p += 4 } else { matColor = nil }
        if (f >> 12) & 1 == 1 { swapTable = r.bytes(p, 4); p += 4 } else { swapTable = nil }
        p += Int((f >> 13) & 3) * 20  // ind SRTs (unused by this title)
        p += Int((f >> 15) & 7) * 4   // ind stages
        tevStages = (0..<Int((f >> 18) & 0x1F)).map { _ in defer { p += 16 }; return r.bytes(p, 16) }
        if (f >> 23) & 1 == 1 { alphaCompare = r.bytes(p, 4); p += 4 } else { alphaCompare = nil }
        if (f >> 24) & 1 == 1 { blendMode = r.bytes(p, 4); p += 4 } else { blendMode = nil }
    }

    static let defaultBlack = SIMD4<Int32>(0, 0, 0, 0)       // lbl_80333790
    static let kselTable: [UInt32] = [0x1F, 0x1B, 0x17, 0x13, 0x1E, 0x1A, 0x16, 0x12] // lbl_801B8E60 / lbl_801B8E80

    /// Texture SRT → GX texture matrix (fn_800DE144): rotate/scale about (0.5, 0.5), then translate.
    public static func texMtx(_ s: TexSRT) -> (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>) {
        let r = s.rotate * .pi / 180, c = cos(r), sn = sin(r)
        let m00 = c * s.scale.x, m01 = -sn * s.scale.y, m10 = sn * s.scale.x, m11 = c * s.scale.y
        return (SIMD4(m00, m01, 0, s.translate.x + 0.5 - 0.5 * m00 - 0.5 * m01),
                SIMD4(m10, m11, 0, s.translate.y + 0.5 - 0.5 * m10 - 0.5 * m11),
                SIMD4(0, 0, 1, 0))
    }

    /// Material::SetupGX(modulate, alpha) — fn_800E0568.
    public func setupGX(modulate: Bool, alpha: UInt8) -> GXState {
        var gx = GXState()
        // Channel control
        var usesVtx = true, usesReg = false
        gx.setNumChans(1)
        if let cc = chanCtrl {
            gx.setChanCtrl(GXState.color0, enable: false, ambSrc: 0, matSrc: UInt32(cc.color))
            gx.setChanCtrl(GXState.alpha0, enable: false, ambSrc: 0, matSrc: UInt32(cc.alpha))
            usesVtx = cc.color == 1 || cc.alpha == 1
            usesReg = cc.color == 0 || cc.alpha == 0
        } else {
            gx.setChanCtrl(GXState.color0a0, enable: false, ambSrc: 0, matSrc: 1)
        }
        var rasStage = usesVtx && modulate
        if usesReg {
            let mc = matColor ?? SIMD4(255, 255, 255, 255)
            let a = UInt32(UInt32(mc.w) * UInt32(alpha) / 255)
            let rgba = UInt32(mc.x) << 24 | UInt32(mc.y) << 16 | UInt32(mc.z) << 8 | a
            gx.setChanMatColor(GXState.color0a0, rgba)
            if !rasStage { rasStage = rgba != 0xFFFF_FFFF }
        }
        // Texgens
        gx.setNumTexGens(texCoordGens.count)
        for (i, g) in texCoordGens.enumerated() { gx.setTexCoordGen(i, type: g.type, src: g.src) }
        // TEV colors (GXSetTevColorS10 REG0..2, GXSetTevKColor)
        for i in 0..<3 { gx.setTevColor(i + 1, tevColors[i]) }
        for i in 0..<4 { gx.setTevKColor(i, tevKColors[i]) }
        // Swap tables
        if let st = swapTable {
            for (t, v) in st.enumerated() { gx.setTevSwapModeTable(t, UInt32(v & 3), UInt32((v >> 2) & 3), UInt32((v >> 4) & 3), UInt32((v >> 6) & 3)) }
        } else {
            gx.setTevSwapModeTable(0, 0, 1, 2, 3); gx.setTevSwapModeTable(1, 0, 0, 0, 3)
            gx.setTevSwapModeTable(2, 1, 1, 1, 3); gx.setTevSwapModeTable(3, 2, 2, 2, 3)
        }
        if !tevStages.isEmpty {
            gx.setNumTevStages(tevStages.count)
            for (s, b) in tevStages.enumerated() {
                gx.setTevOrder(s, coord: b[0], map: UInt32(b[2]) | (UInt32(b[3]) << 8 & 0x100), color: b[1])
                gx.setTevSwapMode(s, ras: UInt32((b[3] >> 1) & 3), tex: UInt32((b[3] >> 3) & 3))
                gx.setTevColorIn(s, GXTevColorArg(rawValue: UInt32(b[4] & 0xF))!, GXTevColorArg(rawValue: UInt32(b[4] >> 4))!,
                                 GXTevColorArg(rawValue: UInt32(b[5] & 0xF))!, GXTevColorArg(rawValue: UInt32(b[5] >> 4))!)
                gx.setTevColorOp(s, op: UInt32(b[6] & 0xF), bias: UInt32((b[6] >> 4) & 3), scale: UInt32((b[6] >> 6) & 3), clamp: b[7] & 1 == 1, out: UInt32((b[7] >> 1) & 3))
                gx.setTevKColorSel(s, UInt32((b[7] >> 3) & 0x1F))
                gx.setTevAlphaIn(s, GXTevAlphaArg(rawValue: UInt32(b[8] & 0x7))!, GXTevAlphaArg(rawValue: UInt32((b[8] >> 4) & 7))!,
                                 GXTevAlphaArg(rawValue: UInt32(b[9] & 0x7))!, GXTevAlphaArg(rawValue: UInt32((b[9] >> 4) & 7))!)
                gx.setTevAlphaOp(s, op: UInt32(b[10] & 0xF), bias: UInt32((b[10] >> 4) & 3), scale: UInt32((b[10] >> 6) & 3), clamp: b[11] & 1 == 1, out: UInt32((b[11] >> 1) & 3))
                gx.setTevKAlphaSel(s, UInt32((b[11] >> 3) & 0x1F))
                gx.setTevDirect(s)
            }
        } else {
            // Default TEV (no stages in the resource), by texture count.
            var n = 0
            switch texMaps.count {
            case 0:
                gx.setTevOrder(0, coord: 0xFF, map: 0xFF, color: 4)
                gx.setTevColorIn(0, .zero, .c1, .rasc, .zero)
                gx.setTevAlphaIn(0, .zero, .a1, .rasa, .zero)
                rasStage = false; n = 1
            case 1:
                gx.setTevOrder(0, coord: 0, map: 0, color: 0xFF)
                gx.setTevColorIn(0, .c0, .c1, .texc, .zero)
                gx.setTevAlphaIn(0, .a0, .a1, .texa, .zero)
                n = 1
            case 2:
                gx.setTevOrder(0, coord: 0, map: 0, color: 0xFF)
                gx.setTevColorIn(0, .zero, .zero, .zero, .texc)
                gx.setTevAlphaIn(0, .zero, .zero, .zero, .texa)
                gx.setTevOrder(1, coord: 1, map: 1, color: 0xFF)
                gx.setTevColorIn(1, .texc, .cprev, .konst, .zero)
                gx.setTevAlphaIn(1, .texa, .aprev, .konst, .zero)
                gx.setTevKColorSel(1, LytMaterial.kselTable[0]); gx.setTevKAlphaSel(1, LytMaterial.kselTable[0])
                n = 2
                n = appendColorMapStage(&gx, n)
            default:
                for i in 0..<texMaps.count {
                    gx.setTevOrder(n, coord: UInt8(i), map: UInt32(i), color: 0xFF)
                    gx.setTevColorIn(n, .zero, .texc, .konst, i == 0 ? .zero : .cprev)
                    gx.setTevAlphaIn(n, .zero, .texa, .konst, i == 0 ? .zero : .aprev)
                    gx.setTevKColorSel(n, LytMaterial.kselTable[i]); gx.setTevKAlphaSel(n, LytMaterial.kselTable[i])
                    n += 1
                }
                n = appendColorMapStage(&gx, n)
            }
            if rasStage {
                gx.setTevOrder(n, coord: 0xFF, map: 0xFF, color: 4)
                gx.setTevColorIn(n, .zero, .cprev, .rasc, .zero)
                gx.setTevAlphaIn(n, .zero, .aprev, .rasa, .zero)
                n += 1
            }
            for s in 0..<n {
                gx.setTevColorOp(s, op: 0, bias: 0, scale: 0, clamp: true, out: 0)
                gx.setTevAlphaOp(s, op: 0, bias: 0, scale: 0, clamp: true, out: 0)
                gx.setTevDirect(s)
                gx.setTevSwapMode(s, ras: 0, tex: 0)
            }
            gx.setNumTevStages(n)
        }
        if let a = alphaCompare {
            gx.setAlphaCompare(UInt32(a[0] & 0xF), UInt32(a[2]), UInt32(a[1]), UInt32(a[0] >> 4), UInt32(a[3]))
        } else {
            gx.setAlphaCompare(7, 0, 0, 7, 0)
        }
        if let b = blendMode { gx.setBlendMode(UInt32(b[0]), UInt32(b[1]), UInt32(b[2]), UInt32(b[3])) }
        else { gx.setBlendMode(1, 4, 5, 0xF) }
        gx.setZMode(false, 7, false)
        return gx
    }

    /// When the black/white colors are not the defaults, map the result through lerp(C0, C1, prev).
    private func appendColorMapStage(_ gx: inout GXState, _ n: Int) -> Int {
        let isDefault = tevColors[0] == LytMaterial.defaultBlack && tevColors[1] == SIMD4(255, 255, 255, 255)
        if isDefault { return n }
        gx.setTevOrder(n, coord: 0xFF, map: 0xFF, color: 0xFF)
        gx.setTevColorIn(n, .c0, .c1, .cprev, .zero)
        gx.setTevAlphaIn(n, .a0, .a1, .aprev, .zero)
        return n + 1
    }
}
