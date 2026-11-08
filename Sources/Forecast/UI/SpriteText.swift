import GX
import Metal
import NW4R
import RVL
import simd

/// TPLCommon / TPLWeather sprite drawing (d_scene.cpp):
/// - DrawSpriteString (fn_8003E414) / DrawSpriteNumberCentered (fn_8003E150) — small digits table lbl_8018F668 (records 0…)
/// - fn_8003F214 / fn_8003F088 — large digits table lbl_8018F6D0 (records 0x21…)
/// - FormatIntW (fn_800362D8) — digits lbl_8018F4D0
/// - weather icons fn_80020574 → layer lists (fn_80020AD4 / fn_80020938 / fn_80020CCC) drawn from TPLWeather.
/// All constant tables are read from the user's main.dol at runtime. Coordinates: SetOrtho2D screen pixels (y down).
public final class SpriteText {
    public struct Record { public let image: Int; public let w: Float; public let h: Float }

    public enum Table { case small, large }

    let ctx: SceneContext
    let common: TPLFile, weather: TPLFile
    var commonTex: [Int: MTLTexture] = [:], weatherTex: [Int: MTLTexture] = [:]
    /// lbl_801F6E80: {image, w, h} for the 0x59 codes listed in lbl_8018F4E8.
    public private(set) var records: [Record] = []
    let smallCodes: [UInt16]     // lbl_8018F668 (18)
    let largeCodes: [UInt16]     // lbl_8018F6D0 (0x2F)
    let digitCodes: [UInt16]     // lbl_8018F4D0
    /// Icon code (0..0x7E) → list of layers (fn_80020574 jump table → lbl_8017A038…).
    struct IconLayer { let image: Int; let offset: SIMD2<Float>; let scale: Float; let main: SIMD4<UInt8>; let shadow: SIMD4<UInt8> }
    var iconLayers: [Int: [IconLayer]] = [:]

    // Colour constants from the page static-init (fn_80010728): white / shadow / high / low …
    public static let white = SIMD4<UInt8>(255, 255, 255, 255)        // lbl_80330A0C
    public static let shadow = SIMD4<UInt8>(0x20, 0x20, 0x20, 255)    // lbl_80330A10
    public static let red = SIMD4<UInt8>(0xEE, 0, 0, 255)            // lbl_80330A14
    public static let cyan = SIMD4<UInt8>(0, 0xFF, 0xFF, 255)        // lbl_80330A18
    public static let lightGrey = SIMD4<UInt8>(0xEE, 0xEE, 0xEE, 255) // lbl_80330A1C
    public static let pink = SIMD4<UInt8>(0xFF, 0xC0, 0xC0, 255)     // lbl_80330A24
    public static let blue = SIMD4<UInt8>(0, 0, 0xFF, 255)           // lbl_80330A30
    public static let lightCyan = SIMD4<UInt8>(0x80, 0xFF, 0xFF, 255) // lbl_80330A3C
    public static let yellow = SIMD4<UInt8>(0xFF, 0xD0, 0, 255)      // lbl_80330A40

    public init(ctx: SceneContext) throws {
        self.ctx = ctx
        let arc = try ctx.assets.archive(.weather)
        guard let c = arc.find("TPLCommon.tpl.LZ"), let w = arc.find("TPLWeather.tpl.LZ") else { throw RVLError.missing("TPLCommon/TPLWeather") }
        common = try TPLFile(CX.uncompressIfNeeded(c))
        weather = try TPLFile(CX.uncompressIfNeeded(w))
        let dol = DOLImage(try ctx.assets.title.content(index: Assets.Content.mainDol.rawValue))
        smallCodes = (0..<18).map { dol.u16(0x8018_F668 + UInt32($0) * 2) }
        largeCodes = (0..<0x2F).map { dol.u16(0x8018_F6D0 + UInt32($0) * 2) }
        digitCodes = (0..<10).map { dol.u16(0x8018_F4D0 + UInt32($0) * 2) }
        // CScene ctor: for i in 0..<0x59: rec[i] = {lbl_8018F4E8[i], TPL width, TPL height}
        records = (0..<0x59).map { i in
            let img = Int(dol.u32(0x8018_F4E8 + UInt32(i) * 4))
            let im = common.images[safe: img]
            return Record(image: img, w: Float(im?.width ?? 0), h: Float(im?.height ?? 0))
        }
        decodeIconTables(dol)
    }

    // MARK: - Icon tables

    /// fn_80020574: `jumptable_8019AF48[code]` → case block `lis r3,hi ; addi r3,r3,lo ; b` → layer list address.
    private func decodeIconTables(_ dol: DOLImage) {
        let jt: UInt32 = 0x8019_AF48
        for code in 0...0x7E {
            let target = dol.u32(jt + UInt32(code) * 4)
            let i0 = dol.u32(target), i1 = dol.u32(target + 4)
            guard i0 >> 26 == 15, i1 >> 26 == 14 else { continue }   // lis / addi
            let hi = Int32(Int16(bitPattern: UInt16(i0 & 0xFFFF))), lo = Int32(Int16(bitPattern: UInt16(i1 & 0xFFFF)))
            var addr = UInt32(bitPattern: (hi << 16) &+ lo)
            var layers: [IconLayer] = []
            while layers.count < 16 {
                let img = dol.u32(addr)
                if img == 0xFFFF_FFFF { break }
                func c(_ o: UInt32) -> SIMD4<UInt8> { let v = dol.u32(addr + o); return SIMD4(UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)) }
                layers.append(IconLayer(image: Int(img), offset: SIMD2(dol.f32(addr + 4), dol.f32(addr + 8)), scale: dol.f32(addr + 0xC),
                                        main: c(0x10), shadow: c(0x14)))
                addr += 0x18
            }
            if !layers.isEmpty { iconLayers[code] = layers }
        }
    }

    func texture(_ tpl: TPLFile, _ i: Int, cache: inout [Int: MTLTexture]) -> MTLTexture? {
        if let t = cache[i] { return t }
        guard let img = tpl.images[safe: i] else { return nil }
        let t = ctx.lyt.makeTexture(img, label: "tpl\(i)")
        cache[i] = t
        return t
    }

    /// Prewarm: upload every TPLCommon / TPLWeather image (weather icons, digits, credits) ahead of first use.
    public func prewarmJobs() -> [() -> Void] {
        (0..<common.images.count).map { i in { [self] in _ = ctx.lyt.makeTexture(common.images[i], label: "tpl\(i)") } }
            + (0..<weather.images.count).map { i in { [self] in _ = ctx.lyt.makeTexture(weather.images[i], label: "tpl\(i)") } }
    }

    /// TPL_GetImageWidth/Height for an image of TPLCommon (common) or TPLWeather.
    public func imageSize(common isCommon: Bool, _ index: Int) -> SIMD2<Float> {
        let img = (isCommon ? common : weather).images[safe: index]
        return SIMD2(Float(img?.width ?? 0), Float(img?.height ?? 0))
    }

    /// fn_80031BE8: TPL image `index` with its top-left at `p`, scaled.
    public func drawImage(common isCommon: Bool, _ index: Int, topLeft p: SIMD2<Float>, sx: Float, sy: Float, color: SIMD4<UInt8>, _ enc: MTLRenderCommandEncoder) {
        let tex: MTLTexture?
        if isCommon { tex = texture(common, index, cache: &commonTex) } else { tex = texture(weather, index, cache: &weatherTex) }
        guard let tex else { return }
        ctx.lyt.drawScreenQuad(tex, x: p.x, y: p.y, w: Float(tex.logicalWidth) * sx, h: Float(tex.logicalHeight) * sy, color: color, screenWidth: ctx.screenWidth, enc)
    }

    // MARK: - Strings

    func recordIndex(_ c: UInt16, _ t: Table) -> Int? {
        switch t {
        case .small: return smallCodes.firstIndex(of: c)
        case .large: return largeCodes.firstIndex(of: c).map { $0 + 0x21 }
        }
    }

    /// Total advance width (unscaled) the centering helpers use.
    func width(_ s: [UInt16], _ t: Table) -> Float { s.compactMap { recordIndex($0, t) }.reduce(0) { $0 + records[safe: $1].map(\.w)! } }

    /// DrawSpriteString / fn_8003F214: `p` = centre of the first glyph; each next glyph advances by
    /// scale·(−1 + ½·prevW + ½·curW). Shadow pass at +2,+2 first.
    public func drawString(_ s: [UInt16], firstCenter p: SIMD2<Float>, sx: Float, sy: Float, color: SIMD4<UInt8>,
                           shadow: SIMD4<UInt8>, table: Table, _ enc: MTLRenderCommandEncoder) {
        var x = p.x, prevW: Float? = nil
        for c in s {
            guard let ri = recordIndex(c, table), let r = records[safe: ri] else { continue }
            if let pw = prevW { x += sx * (-1 + 0.5 * pw + 0.5 * r.w) }
            prevW = r.w
            let tl = SIMD2(x - 0.5 * r.w * sx, p.y - 0.5 * r.h * sy)
            drawImage(common: true, r.image, topLeft: tl + SIMD2(2, 2), sx: sx, sy: sy, color: shadow, enc)
            drawImage(common: true, r.image, topLeft: tl, sx: sx, sy: sy, color: color, enc)
        }
    }

    /// DrawSpriteNumberCentered / fn_8003F088: centre the whole string on `center`.
    public func drawCentered(_ s: [UInt16], center: SIMD2<Float>, sx: Float, sy: Float, color: SIMD4<UInt8>,
                             shadow: SIMD4<UInt8> = SpriteText.shadow, table: Table = .large, _ enc: MTLRenderCommandEncoder) {
        guard let first = s.first, let fi = recordIndex(first, table) else { return }
        let total = width(s, table)
        let p = SIMD2(center.x - sx * (0.5 * total - 0.5 * records[fi].w), center.y)
        drawString(s, firstCenter: p, sx: sx, sy: sy, color: color, shadow: shadow, table: table, enc)
    }

    /// FormatIntW(value, out, maxDigits, zeroPad) — wide digits, leading '-' for negatives.
    public func formatInt(_ value: Int, maxDigits: Int = 3, zeroPad: Bool = false) -> [UInt16] {
        var v = abs(value), digits: [UInt16] = []
        repeat { digits.insert(digitCodes[v % 10], at: 0); v /= 10 } while v > 0 && digits.count < maxDigits
        if zeroPad { while digits.count < maxDigits { digits.insert(digitCodes[0], at: 0) } }
        return (value < 0 ? [0x2D] : []) + digits
    }

    /// Draw an integer (or "--" when nil) centred at `center` in the large sprite font.
    public func drawNumber(_ value: Int?, center: SIMD2<Float>, scale: Float = 1, color: SIMD4<UInt8> = SpriteText.white,
                           shadow: SIMD4<UInt8> = SpriteText.shadow, table: Table = .large, _ enc: MTLRenderCommandEncoder) {
        let s: [UInt16] = value.map { formatInt($0) } ?? [0x2D, 0x2D]
        drawCentered(s, center: center, sx: scale, sy: scale, color: color, shadow: shadow, table: table, enc)
    }

    // MARK: - Weather icons

    /// fn_80020574(iconCode, pos, alpha, scale): code & 0x7FFF selects the layer list, bit 15 = night
    /// (layer image 4 → 1, 15 → 0xB); codes < 0x64 draw with a shadow (fn_80020CCC), others without (fn_80020E48).
    /// Unknown codes draw "--".
    public func drawWeatherIcon(code: UInt16, center: SIMD2<Float>, alpha: UInt8 = 255, scale: Float = 1, _ enc: MTLRenderCommandEncoder) {
        let c = Int(code & 0x7FFF), night = code & 0x8000 != 0
        guard c <= 0x7E, let layers = iconLayers[c] else {
            var w = SpriteText.white, s = SpriteText.shadow; w.w = alpha; s.w = alpha
            drawCentered([0x2D, 0x2D], center: center, sx: scale, sy: scale, color: w, shadow: s, enc)
            return
        }
        let a = Float(alpha) / 255
        for l in layers {
            var img = l.image
            if night { if img == 4 { img = 1 } else if img == 15 { img = 0xB } }
            let p = center + l.offset * scale
            let s = l.scale * scale
            guard let tex = texture(weather, img, cache: &weatherTex) else { continue }
            let tl = SIMD2(p.x - s * 0.5 * Float(tex.logicalWidth), p.y - s * 0.5 * Float(tex.logicalHeight))
            var main = l.main; main.w = UInt8(Float(main.w) * a)
            if c < 0x64 {
                var sh = l.shadow; sh.w = UInt8(Float(sh.w) * a)
                drawImage(common: false, img, topLeft: tl + SIMD2(2, 2), sx: s, sy: s, color: sh, enc)
            }
            drawImage(common: false, img, topLeft: tl, sx: s, sy: s, color: main, enc)
        }
    }

    // MARK: - Anchors

    /// Pane_GetScreenCenter + the screen mapping the pages use: layout point (design 608 space, y up) →
    /// SetOrtho2D pixels: x = W/2 + x·wideScale, y = 228 − y.
    public func screenPoint(_ layoutPoint: SIMD2<Float>) -> SIMD2<Float> {
        let k: Float = ctx.isWide ? 1.368_421_1 : 1
        return SIMD2(ctx.screenWidth / 2 + layoutPoint.x * k, LogicalScreen.halfHeight - layoutPoint.y)
    }

    /// Centre of a pane's rectangle in layout space (uses the pane's last calculated global matrix).
    public static func layoutCenter(_ p: Pane) -> SIMD2<Float> {
        let o = p.vertexOrigin, s = p.size
        let c = p.globalMtx * SIMD4(o.x + s.x / 2, o.y - s.y / 2, 0, 1)
        return SIMD2(c.x, c.y)
    }
}

// MARK: - Globe marker helpers (added by the globe-markers track)

extension SpriteText {
    /// fn_8003EF80 / fn_8003F024: unscaled advance width (sum of record widths) and max record height of a string.
    public func stringSize(_ s: [UInt16], table: Table = .large) -> SIMD2<Float> {
        var h: Float = 0
        for c in s { if let i = recordIndex(c, table), let r = records[safe: i] { h = max(h, r.h) } }
        return SIMD2(width(s, table), h)
    }

    /// fn_8003F088 → fn_8003F214: string centred on `center`; per glyph `back` at (+2,+2) then `front`.
    public func drawCenteredTwoPass(_ s: [UInt16], center: SIMD2<Float>, scale: Float, back: SIMD4<UInt8>, front: SIMD4<UInt8>,
                                    table: Table = .large, _ enc: MTLRenderCommandEncoder) {
        guard let first = s.first, let fi = recordIndex(first, table), let r0 = records[safe: fi] else { return }
        let total = width(s, table)
        let start = SIMD2(center.x - scale * (0.5 * total - 0.5 * r0.w), center.y)
        // fn_8003F214, per glyph: `back` at (+2,+2), then `front`. The advance is scale·(½·prevW + ½·curW) — f2 is
        // reloaded with the previous glyph's width at 0x8003F428 (no −1 here, unlike DrawSpriteString).
        var x = start.x, prevW: Float? = nil
        for c in s {
            guard let ri = recordIndex(c, table), let r = records[safe: ri] else { continue }
            if let pw = prevW { x += scale * (0.5 * pw + 0.5 * r.w) }
            prevW = r.w
            let tl = SIMD2(x - 0.5 * r.w * scale, start.y - 0.5 * r.h * scale)
            drawImage(common: true, r.image, topLeft: tl + SIMD2(2, 2), sx: scale, sy: scale, color: back, enc)
            drawImage(common: true, r.image, topLeft: tl, sx: scale, sy: scale, color: front, enc)
        }
    }

    /// fn_8002E9EC → fn_8002E804: untextured quad (x0, y0, x1, y1) with per-corner colours in TL, BL, BR, TR order.
    public func drawGradientRect(_ r: SIMD4<Float>, _ c: [SIMD4<UInt8>], _ enc: MTLRenderCommandEncoder) {
        let lyt = ctx.lyt, gxm = lyt.gx
        var gx = GXState()
        gx.setNumChans(1)
        gx.setChanCtrl(GXState.color0a0, enable: false, ambSrc: 0, matSrc: 1)
        gx.setNumTexGens(0)
        gx.setTevSwapModeTable(0, 0, 1, 2, 3)
        gx.setTevSwapMode(0, ras: 0, tex: 0)
        gx.setNumTevStages(1)
        gx.setTevOrder(0, coord: 0xFF, map: 0xFF, color: 4)
        gx.setTevColorIn(0, .zero, .zero, .zero, .rasc)
        gx.setTevAlphaIn(0, .zero, .zero, .zero, .rasa)
        gx.setTevColorOp(0, op: 0, bias: 0, scale: 0, clamp: true, out: 0)
        gx.setTevAlphaOp(0, op: 0, bias: 0, scale: 0, clamp: true, out: 0)
        gx.setTevDirect(0)
        gx.setAlphaCompare(7, 0, 0, 7, 0)
        gx.setBlendMode(1, 4, 5, 0xF)
        gx.setZMode(false, 7, false)
        var verts: [Float] = []
        func v(_ x: Float, _ y: Float, _ col: SIMD4<UInt8>) {
            var a = [Float](repeating: 0, count: 26)
            a[0] = x; a[1] = y
            a[6] = Float(col.x) / 255; a[7] = Float(col.y) / 255; a[8] = Float(col.z) / 255; a[9] = Float(col.w) / 255
            verts += a
        }
        // TL, BL, BR, TR
        v(r.x, r.y, c[0]); v(r.x, r.w, c[1]); v(r.z, r.w, c[2])
        v(r.x, r.y, c[0]); v(r.z, r.w, c[2]); v(r.z, r.y, c[3])
        guard let (buf, off) = gxm.push(verts), let pipe = try? gxm.pipeline(gx) else { return }
        let vu = GXMetal.vertexUniforms(proj: LytRenderer.ortho2D(width: ctx.screenWidth), posMtx: matrix_identity_float4x4, pre: [], post: [], gx: gx)
        let fu = GXMetal.fragmentUniforms(gx, dims: [])
        enc.setCullMode(.none)
        enc.setRenderPipelineState(pipe)
        enc.setDepthStencilState(gxm.depthState(gx.zMode))
        enc.setVertexBuffer(buf, offset: off, index: 0)
        enc.setVertexBytes(vu, length: vu.count * 16, index: 1)
        enc.setFragmentBytes(fu, length: fu.count * 16, index: 0)
        for i in 0..<8 { enc.setFragmentTexture(gxm.whiteTexture, index: i); enc.setFragmentSamplerState(gxm.defaultSampler, index: i) }
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
    }
}
