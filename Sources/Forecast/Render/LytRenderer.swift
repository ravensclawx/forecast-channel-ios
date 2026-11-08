import GX
import Metal
import NW4R
import simd

/// Draws nw4r::lyt layouts with Metal (the role of Layout::Draw → Pane::Draw → *::DrawSelf + GX).
public final class LytRenderer {
    public let gx: GXMetal
    private var textures: [String: MTLTexture] = [:]
    private var samplerForTex: [String: (UInt32, UInt32)] = [:]
    private var fontSheets: [ObjectIdentifier: FontSheets] = [:]

    /// A font's sheet textures, uploaded one at a time on first use (a system font has >100 sheets; only the few
    /// holding the glyphs actually drawn are ever uploaded — matters with the ×2/×4 upscaled overrides).
    public final class FontSheets {
        let font: ResFont, gx: GXMetal
        private var cache: [Int: MTLTexture] = [:]
        init(_ f: ResFont, _ gx: GXMetal) { font = f; self.gx = gx }
        public var count: Int { font.sheets.count }
        public subscript(i: Int) -> MTLTexture {
            if let t = cache[i] { return t }
            // Glyph UVs come from the font's own sheetWidth/Height (TelopText, drawText), never the texture size.
            let t = gx.makeTexture2D(font.sheets[i], width: font.sheetWidth, height: font.sheetHeight, label: "font sheet \(i)")
            cache[i] = t
            return t
        }
    }

    /// Resolves a txl1 texture name ("btn1.tpl") to a TPL image; provided by the scene (archive accessor).
    public var textureProvider: (String) -> TPLFile.Image? = { _ in nil }
    /// Resolves an fnl1 font name to a ResFont.
    public var fontProvider: (String) -> ResFont? = { _ in nil }

    public init(gx: GXMetal) { self.gx = gx }

    /// Prewarm a layout texture by its txl1 name.
    public func prewarmTexture(_ name: String) { _ = texture(name) }
    /// Prewarm every sheet of a font.
    /// (only the sheets holding Latin text — the system font's CJK sheets are left to load if ever used)
    public func prewarmFont(_ f: ResFont) {
        let s = sheets(f)
        var used = Set<Int>()
        for c in UInt16(0x20)...UInt16(0xFF) { used.insert(f.glyph(c).sheet) }
        for c in [UInt16(0x2019), 0x2013, 0x2014, 0x201C, 0x201D, 0x2026, 0x00B0] { used.insert(f.glyph(c).sheet) }
        for i in used.sorted() where i >= 0 && i < s.count { _ = s[i] }
    }

    func texture(_ name: String) -> MTLTexture? {
        if let t = textures[name] { return t }
        guard let img = textureProvider(name) else { return nil }
        let t = gx.makeTexture2D(img.rgba8, width: img.width, height: img.height, label: name)
        textures[name] = t
        return t
    }

    func sheets(_ f: ResFont) -> FontSheets {
        if let s = fontSheets[ObjectIdentifier(f)] { return s }
        let s = FontSheets(f, gx)
        fontSheets[ObjectIdentifier(f)] = s
        return s
    }

    /// Orthographic projection for a 608x456 (or 832x456 wide) logical screen, origin at center, y up.
    public static func ortho(width: Float, height: Float) -> simd_float4x4 {
        simd_float4x4(rows: [SIMD4(2 / width, 0, 0, 0), SIMD4(0, 2 / height, 0, 0), SIMD4(0, 0, -1.0 / 1000, 0.5), SIMD4(0, 0, 0, 1)])
    }

    /// Layout::Draw. `viewMtx` lets the game offset/scale the whole layout (DrawInfo view matrix).
    public func draw(_ layout: Layout, _ enc: MTLRenderCommandEncoder, screenWidth: Float = 608, viewMtx: simd_float4x4 = matrix_identity_float4x4,
                     locationAdjust: SIMD2<Float>? = nil) {
        layout.root.calculate(parentMtx: viewMtx, parentAlpha: 255, locationAdjust: locationAdjust)
        let proj = LytRenderer.ortho(width: screenWidth, height: LogicalScreen.height)
        enc.setCullMode(.none)
        drawPane(layout, layout.root, enc, proj)
    }

    private func drawPane(_ layout: Layout, _ p: Pane, _ enc: MTLRenderCommandEncoder, _ proj: simd_float4x4) {
        guard p.visible, !p.suppressed else { return }
        if let pic = p as? Picture {
            if let strip = pic.edgeStrip, strip.height > 0 {
                // iPhone edge extension: the art's outer `overlap` is replaced by its row at the cut, stretched out to
                // `height` past the art — the art is trimmed (no double-drawn translucent layers), then the strip.
                let o = pic.vertexOrigin, s = pic.size
                let f = min(max(strip.overlap / max(s.y, 1), 0), 1)          // fraction of the art replaced
                let cutT = strip.localTop ? f : 1 - f                         // texture row at the cut (0 top … 1 bottom)
                let cutY = o.y - s.y * cutT
                let c = pic.vtxColors
                func mixC(_ a: SIMD4<UInt8>, _ b: SIMD4<UInt8>) -> SIMD4<UInt8> {
                    let fa = SIMD4<Float>(a), fb = SIMD4<Float>(b)
                    let m: SIMD4<Float> = fa + (fb - fa) * cutT
                    return SIMD4<UInt8>(m.rounded(.toNearestOrAwayFromZero))
                }
                func rowTC(_ t: [SIMD2<Float>]) -> (SIMD2<Float>, SIMD2<Float>) {
                    (t[0] + (t[2] - t[0]) * cutT, t[1] + (t[3] - t[1]) * cutT)
                }
                let cl = mixC(c[0], c[2]), cr = mixC(c[1], c[3])
                // 1. the kept part of the art
                let keptCorners: [SIMD2<Float>]
                var keptTC = pic.texCoords, keptC = c
                if strip.localTop {
                    keptCorners = [SIMD2(o.x, cutY), SIMD2(o.x + s.x, cutY), SIMD2(o.x, o.y - s.y), SIMD2(o.x + s.x, o.y - s.y)]
                    for k in keptTC.indices where keptTC[k].count == 4 { let (l, r) = rowTC(keptTC[k]); keptTC[k][0] = l; keptTC[k][1] = r }
                    keptC[0] = cl; keptC[1] = cr
                } else {
                    keptCorners = [SIMD2(o.x, o.y), SIMD2(o.x + s.x, o.y), SIMD2(o.x, cutY), SIMD2(o.x + s.x, cutY)]
                    for k in keptTC.indices where keptTC[k].count == 4 { let (l, r) = rowTC(keptTC[k]); keptTC[k][2] = l; keptTC[k][3] = r }
                    keptC[2] = cl; keptC[3] = cr
                }
                drawQuad(layout, pic, pic.material, keptC, keptTC, enc, proj, corners: keptCorners)
                // 2. the cut row stretched from the cut to past the edge
                let outer = strip.localTop ? o.y + strip.height : o.y - s.y - strip.height
                let corners = [SIMD2(o.x, cutY), SIMD2(o.x + s.x, cutY), SIMD2(o.x, outer), SIMD2(o.x + s.x, outer)]
                let tc = pic.texCoords.map { t -> [SIMD2<Float>] in
                    guard t.count == 4 else { return t }
                    let (l, r) = rowTC(t); return [l, r, l, r]
                }
                drawQuad(layout, pic, pic.material, [cl, cr, cl, cr], tc, enc, proj, corners: corners)
            } else {
                drawQuad(layout, pic, pic.material, pic.vtxColors, pic.texCoords, enc, proj)
            }
        }
        else if let w = p as? Window { drawQuad(layout, w, w.material, w.vtxColors, w.texCoords, enc, proj) }
        else if let t = p as? TextBox { drawText(t, enc, proj) }
        for c in p.children { drawPane(layout, c, enc, proj) }
    }

    /// detail::IsModulateVertexColor
    static func isModulate(_ colors: [SIMD4<UInt8>], _ alpha: UInt8) -> Bool {
        alpha != 255 || colors.contains { $0 != SIMD4(255, 255, 255, 255) }
    }

    private func vertex(_ pos: SIMD2<Float>, _ c: SIMD4<UInt8>, _ alpha: UInt8, _ uvs: [SIMD2<Float>]) -> [Float] {
        var v = [Float](repeating: 0, count: 26)
        v[0] = pos.x; v[1] = pos.y
        v[6] = Float(c.x) / 255; v[7] = Float(c.y) / 255; v[8] = Float(c.z) / 255
        v[9] = Float(Int(c.w) * Int(alpha) / 255) / 255   // detail::MultipleAlpha
        for (i, uv) in uvs.prefix(8).enumerated() { v[10 + i * 2] = uv.x; v[11 + i * 2] = uv.y }
        return v
    }

    /// Picture::DrawSelf (and Window content).
    private func drawQuad(_ layout: Layout, _ p: Pane, _ mat: LytMaterial?, _ colors: [SIMD4<UInt8>], _ texCoords: [[SIMD2<Float>]],
                          _ enc: MTLRenderCommandEncoder, _ proj: simd_float4x4, corners cornersOverride: [SIMD2<Float>]? = nil) {
        guard let mat else { return }
        let alpha = p.globalAlpha
        let state = mat.setupGX(modulate: LytRenderer.isModulate(colors, alpha), alpha: alpha)
        let o = p.vertexOrigin, s = p.size
        let corners = cornersOverride ?? [SIMD2(o.x, o.y), SIMD2(o.x + s.x, o.y), SIMD2(o.x, o.y - s.y), SIMD2(o.x + s.x, o.y - s.y)]
        var verts: [Float] = []
        for i in [0, 1, 2, 1, 3, 2] { verts += vertex(corners[i], colors[i], alpha, texCoords.map { $0[i] }) }
        var texs: [MTLTexture?] = [], samps: [MTLSamplerState?] = [], dims: [SIMD2<Int32>] = []
        for (slot, tm) in mat.texMaps.enumerated() {
            let name = mat.texturePatternOverride[slot] ?? layout.textureNames[safe: tm.texture] ?? ""
            let t = texture(name)
            texs.append(t); samps.append(gx.sampler(wrapS: tm.wrapS, wrapT: tm.wrapT, minFilter: tm.minFilter, magFilter: tm.magFilter))
            dims.append(SIMD2(Int32(t?.logicalWidth ?? 1), Int32(t?.logicalHeight ?? 1)))
        }
        // Texgen matrices: TexCoordGen.mtx 30 + 3k → TexSRT k; 60 → identity.
        var pre: [GXMetal.Mtx34] = []
        for g in mat.texCoordGens {
            var m = GXMetal.identity34
            if g.mtx >= 30 && g.mtx < 60, let srt = mat.texSRTs[safe: Int(g.mtx - 30) / 3] { m = LytMaterial.texMtx(srt) }
            pre.append(m)
        }
        submit(state, verts, p.globalMtx, pre, texs, samps, dims, enc, proj)
    }

    /// TextBox::DrawSelf via TextWriter/CharWriter.
    private func drawText(_ t: TextBox, _ enc: MTLRenderCommandEncoder, _ proj: simd_float4x4) {
        guard let mat = t.material, let font = t.font ?? t.fontName.flatMap(fontProvider), !t.text.isEmpty else { return }
        t.font = font
        func clampColor(_ c: SIMD4<Int32>) -> SIMD4<Int32> { simd_clamp(c, SIMD4(repeating: 0), SIMD4(repeating: 255)) }
        let state = CharWriter.setupGX(sheetFormat: font.sheetFormat, minColor: clampColor(mat.tevColors[0]), maxColor: clampColor(mat.tevColors[1]))
        let quads = CharWriter.layout(text: t.text, font: font, fontSize: t.fontSize, charSpace: t.charSpace, lineSpace: t.lineSpace,
                                      boxSize: t.size, textPosition: t.textPosition, textAlignment: t.textAlignment,
                                      top: t.topColor, bottom: t.bottomColor)
        let o = t.vertexOrigin
        let sheetTex = sheets(font)
        let samp = gx.sampler(wrapS: 0, wrapT: 0, minFilter: 1, magFilter: 1)
        // Batch by sheet
        var bySheet: [Int: [Float]] = [:]
        for q in quads {
            let x0 = o.x + q.rect.x, x1 = o.x + q.rect.z, y0 = o.y + q.rect.y, y1 = o.y + q.rect.w
            let c = [vertex(SIMD2(x0, y0), q.top, t.globalAlpha, [SIMD2(q.uv.x, q.uv.y)]),
                     vertex(SIMD2(x1, y0), q.top, t.globalAlpha, [SIMD2(q.uv.z, q.uv.y)]),
                     vertex(SIMD2(x0, y1), q.bottom, t.globalAlpha, [SIMD2(q.uv.x, q.uv.w)]),
                     vertex(SIMD2(x1, y1), q.bottom, t.globalAlpha, [SIMD2(q.uv.z, q.uv.w)])]
            bySheet[q.sheet, default: []] += c[0] + c[1] + c[2] + c[1] + c[3] + c[2]
        }
        for (sheet, verts) in bySheet where sheet < sheetTex.count {
            submit(state, verts, t.globalMtx, [], [sheetTex[sheet]], [samp], [SIMD2(Int32(font.sheetWidth), Int32(font.sheetHeight))], enc, proj)
        }
    }

    private func submit(_ state: GXState, _ verts: [Float], _ mtx: simd_float4x4, _ pre: [GXMetal.Mtx34],
                        _ texs: [MTLTexture?], _ samps: [MTLSamplerState?], _ dims: [SIMD2<Int32>],
                        _ enc: MTLRenderCommandEncoder, _ proj: simd_float4x4) {
        guard !verts.isEmpty, let (buf, off) = gx.push(verts), let pipe = try? gx.pipeline(state) else { return }
        let vu = GXMetal.vertexUniforms(proj: proj, posMtx: mtx, pre: pre, post: [], gx: state)
        let fu = GXMetal.fragmentUniforms(state, dims: dims)
        enc.setRenderPipelineState(pipe)
        enc.setDepthStencilState(gx.depthState(state.zMode))
        enc.setVertexBuffer(buf, offset: off, index: 0)
        enc.setVertexBytes(vu, length: vu.count * 16, index: 1)
        enc.setFragmentBytes(fu, length: fu.count * 16, index: 0)
        for i in 0..<8 {
            enc.setFragmentTexture((i < texs.count ? texs[i] : nil) ?? gx.whiteTexture, index: i)
            enc.setFragmentSamplerState((i < samps.count ? samps[i] : nil) ?? gx.defaultSampler, index: i)
        }
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: verts.count / 26)
    }
}
