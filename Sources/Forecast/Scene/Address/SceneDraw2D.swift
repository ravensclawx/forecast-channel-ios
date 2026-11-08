import GX
import Metal
import NW4R
import simd

/// Immediate-mode 2D drawing used by the scene code outside of layouts:
///   Setup2DRender (fn_80031170): TEV out = TEXC·C0 + C1, alpha = TEXA·A0 + A1, alpha test > 0, blend SRCALPHA/INVSRCALPHA
///   SetOrtho2D (fn_800313F4): 0..W × 0..456, y down
///   DrawTPLImage (fn_80031BE8): one TPL image at (x, y) scaled
///   TextWriter (nw4r::ut::TextWriter) Print with draw flags (0x111 = centred on the cursor)
public final class SceneDraw2D {
    let gx: GXMetal
    let lyt: LytRenderer
    let width: Float
    private var tplTextures: [String: MTLTexture] = [:]

    public init(gx: GXMetal, lyt: LytRenderer, width: Float) { self.gx = gx; self.lyt = lyt; self.width = width }

    /// SetOrtho2D: x 0..W, y 0..456 (top = 0).
    var proj: simd_float4x4 {
        simd_float4x4(rows: [SIMD4(2 / width, 0, 0, -1), SIMD4(0, -2 / LogicalScreen.height, 0, 1), SIMD4(0, 0, -1.0 / 200, 0.5), SIMD4(0, 0, 0, 1)])
    }

    func vtx(_ x: Float, _ y: Float, _ c: SIMD4<Float>, _ u: Float, _ v: Float) -> [Float] {
        var a = [Float](repeating: 0, count: 26)
        a[0] = x; a[1] = y; a[6] = c.x; a[7] = c.y; a[8] = c.z; a[9] = c.w; a[10] = u; a[11] = v
        return a
    }

    /// Setup2DRender TEV with C0 = colour, C1 = 0.
    func setup2D(color: SIMD4<UInt8>) -> GXState {
        var s = GXState()
        s.setNumChans(0); s.setNumTexGens(1); s.setTexCoordGen(0, type: 1, src: 4)
        s.setTevOrder(0, coord: 0, map: 0, color: 0xFF)
        s.setTevColorIn(0, .zero, .texc, .c0, .c1)
        s.setTevAlphaIn(0, .zero, .texa, .a0, .a1)
        s.setTevColorOp(0, op: 0, bias: 0, scale: 0, clamp: true, out: 0)
        s.setTevAlphaOp(0, op: 0, bias: 0, scale: 0, clamp: true, out: 0)
        s.setTevSwapModeTable(0, 0, 1, 2, 3)
        s.setNumTevStages(1)
        s.setTevColor(1, SIMD4(Int32(color.x), Int32(color.y), Int32(color.z), Int32(color.w)))
        s.setTevColor(2, .zero)
        s.setBlendMode(1, 4, 5, 0xF)
        s.setAlphaCompare(4, 0, 0, 7, 0)
        s.setZMode(false, 7, false)
        return s
    }

    func submit(_ s: GXState, _ verts: [Float], _ tex: MTLTexture?, _ samp: MTLSamplerState?, _ enc: MTLRenderCommandEncoder) {
        guard !verts.isEmpty, let (buf, off) = gx.push(verts), let pipe = try? gx.pipeline(s) else { return }
        let vu = GXMetal.vertexUniforms(proj: proj, posMtx: matrix_identity_float4x4, pre: [], post: [], gx: s)
        let dims = [SIMD2(Int32(tex?.width ?? 1), Int32(tex?.height ?? 1))]
        let fu = GXMetal.fragmentUniforms(s, dims: dims)
        enc.setRenderPipelineState(pipe)
        enc.setDepthStencilState(gx.depthState(s.zMode))
        enc.setCullMode(.none)
        enc.setVertexBuffer(buf, offset: off, index: 0)
        enc.setVertexBytes(vu, length: vu.count * 16, index: 1)
        enc.setFragmentBytes(fu, length: fu.count * 16, index: 0)
        for i in 0..<8 {
            enc.setFragmentTexture(i == 0 ? (tex ?? gx.whiteTexture) : gx.whiteTexture, index: i)
            enc.setFragmentSamplerState(i == 0 ? (samp ?? gx.defaultSampler) : gx.defaultSampler, index: i)
        }
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: verts.count / 26)
    }

    func quadVerts(_ x0: Float, _ y0: Float, _ x1: Float, _ y1: Float, _ uv: SIMD4<Float> = SIMD4(0, 0, 1, 1),
                   _ c: SIMD4<Float> = SIMD4(1, 1, 1, 1)) -> [Float] {
        let a = vtx(x0, y0, c, uv.x, uv.y), b = vtx(x1, y0, c, uv.z, uv.y)
        let d = vtx(x0, y1, c, uv.x, uv.w), e = vtx(x1, y1, c, uv.z, uv.w)
        return a + b + d + b + e + d
    }

    /// fn_8002E5C0: solid-colour quad (white texture × colour).
    public func fillRect(_ x0: Float, _ y0: Float, _ x1: Float, _ y1: Float, color: SIMD4<UInt8>, _ enc: MTLRenderCommandEncoder) {
        submit(setup2D(color: color), quadVerts(x0, y0, x1, y1), nil, nil, enc)
    }

    /// fn_80031BE8 DrawTPLImage(tpl, index, pos, sx, sy) with Setup2DRender's C0 tint.
    public func image(_ tpl: TPLFile, _ index: Int, x: Float, y: Float, sx: Float = 1, sy: Float = 1,
                      color: SIMD4<UInt8> = SIMD4(255, 255, 255, 255), key: String, _ enc: MTLRenderCommandEncoder) {
        guard index >= 0, index < tpl.images.count else { return }
        let img = tpl.images[index]
        let k = "\(key)#\(index)"
        let tex: MTLTexture
        if let t = tplTextures[k] { tex = t } else {
            let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: img.width, height: img.height, mipmapped: false)
            tex = gx.device.makeTexture(descriptor: td)!
            tex.replace(region: MTLRegionMake2D(0, 0, img.width, img.height), mipmapLevel: 0, withBytes: img.rgba8, bytesPerRow: img.width * 4)
            tplTextures[k] = tex
        }
        let samp = gx.sampler(wrapS: 0, wrapT: 0, minFilter: 1, magFilter: 1)
        submit(setup2D(color: color), quadVerts(x, y, x + Float(img.width) * sx, y + Float(img.height) * sy), tex, samp, enc)
    }

    /// Draw a Metal texture (frame capture / offscreen scene) as a quad with alpha (Setup2DRender, C0 = (255,255,255,a)).
    public func texture(_ tex: MTLTexture, x0: Float, y0: Float, x1: Float, y1: Float, uv: SIMD4<Float> = SIMD4(0, 0, 1, 1),
                        alpha: UInt8, _ enc: MTLRenderCommandEncoder) {
        var s = setup2D(color: SIMD4(255, 255, 255, alpha))
        s.setAlphaCompare(7, 0, 0, 7, 0)
        if alpha == 255 { s.setBlendMode(0, 1, 0, 0xF) }
        let samp = gx.sampler(wrapS: 0, wrapT: 0, minFilter: 1, magFilter: 1)
        submit(s, quadVerts(x0, y0, x1, y1, uv), tex, samp, enc)
    }

    /// TextWriter::CalcStringWidth (scale 1, no char space) — used to fit text to boxes.
    public static func stringWidth(_ text: [UInt16], font: ResFont, scale: Float = 1) -> Float {
        let sx = scale
        return text.reduce(Float(0)) { $0 + Float(font.glyph($1).widths.charWidth) * sx }
    }

    /// TextWriter::Print at (x, y) with draw flags 0x111 (centre on the cursor) and colour mapping min/max.
    public func text(_ s: [UInt16], font: ResFont, x: Float, y: Float, scale: SIMD2<Float> = SIMD2(1, 1),
                     color: SIMD4<UInt8>, minColor: SIMD4<Int32> = SIMD4(0, 0, 0, 0), maxColor: SIMD4<Int32> = SIMD4(255, 255, 255, 255),
                     centered: Bool = true, _ enc: MTLRenderCommandEncoder) {
        guard !s.isEmpty else { return }
        let state = CharWriter.setupGX(sheetFormat: font.sheetFormat, minColor: minColor, maxColor: maxColor)
        let size = SIMD2(Float(font.width) * scale.x, Float(font.height) * scale.y)
        let quads = CharWriter.layout(text: s, font: font, fontSize: size, charSpace: 0, lineSpace: 0,
                                      boxSize: SIMD2(0, 0), textPosition: 0, textAlignment: 1, top: color, bottom: color)
        // Block extents for centring
        let w = quads.map { $0.rect.z }.max() ?? 0
        let lines = Float(s.split(separator: 0x0A, omittingEmptySubsequences: false).count)
        let h = lines * Float(font.lineFeed) * scale.y
        let ox = centered ? x - w / 2 : x, oy = centered ? y - h / 2 : y
        let sheetTex = lyt.sheets(font)
        let samp = gx.sampler(wrapS: 0, wrapT: 0, minFilter: 1, magFilter: 1)
        let c = SIMD4<Float>(Float(color.x), Float(color.y), Float(color.z), Float(color.w)) / 255
        var bySheet: [Int: [Float]] = [:]
        for q in quads {
            // layout rects are y-up (negative downward) relative to the block top-left
            bySheet[q.sheet, default: []] += quadVerts(ox + q.rect.x, oy - q.rect.y, ox + q.rect.z, oy - q.rect.w, q.uv, c)
        }
        for (sheet, v) in bySheet where sheet < sheetTex.count { submitText(state, v, sheetTex[sheet], samp, font, enc) }
    }

    private func submitText(_ s: GXState, _ verts: [Float], _ tex: MTLTexture, _ samp: MTLSamplerState, _ font: ResFont, _ enc: MTLRenderCommandEncoder) {
        var st = s
        st.setChanCtrl(GXState.color0a0, enable: false, ambSrc: 0, matSrc: 1)
        submit(st, verts, tex, samp, enc)
    }
}
