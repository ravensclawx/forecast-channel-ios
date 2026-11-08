import GX
import Metal
import NW4R
import simd

/// Immediate-mode 2D quads in the game's SetOrtho2D space (fn_800313F4: x 0..W, y 0..456 downwards),
/// used by the sprite-number / icon / telop drawing that the original does with raw GX after Setup2DRender.
extension LytRenderer {
    /// Ortho for screen pixels, y down (SetOrtho2D).
    public static func ortho2D(width: Float) -> simd_float4x4 {
        simd_float4x4(rows: [SIMD4(2 / width, 0, 0, -1), SIMD4(0, -2 / LogicalScreen.height, 0, 1), SIMD4(0, 0, -1.0 / 1000, 0.5), SIMD4(0, 0, 0, 1)])
    }

    /// TEV used by DrawSpriteString after GXSetTevColor(GX_TEVREG0, color): out = tex × C0.
    static func spriteGX(color: SIMD4<UInt8>, intensityFont: Bool = false) -> GXState {
        var gx = GXState()
        gx.setNumChans(1)
        gx.setChanCtrl(GXState.color0a0, enable: false, ambSrc: 0, matSrc: 1)
        gx.setNumTexGens(1)
        gx.setTexCoordGen(0, type: 1, src: 4)
        gx.setTevSwapModeTable(0, 0, 1, 2, 3)
        gx.setNumTevStages(1)
        gx.setTevOrder(0, coord: 0, map: 0, color: 0xFF)
        if intensityFont {
            // CharWriter::SetupGX for I4/I8 sheets: colour = rasterised colour, alpha = texture × alpha.
            gx.setTevColorIn(0, .zero, .zero, .zero, .c0)
        } else {
            gx.setTevColorIn(0, .zero, .texc, .c0, .zero)
        }
        gx.setTevAlphaIn(0, .zero, .texa, .a0, .zero)
        gx.setTevColorOp(0, op: 0, bias: 0, scale: 0, clamp: true, out: 0)
        gx.setTevAlphaOp(0, op: 0, bias: 0, scale: 0, clamp: true, out: 0)
        gx.setTevDirect(0)
        gx.setTevSwapMode(0, ras: 0, tex: 0)
        gx.setTevColor(1, SIMD4(Int32(color.x), Int32(color.y), Int32(color.z), Int32(color.w)))
        gx.setAlphaCompare(7, 0, 0, 7, 0)
        gx.setBlendMode(1, 4, 5, 0xF)
        gx.setZMode(false, 7, false)
        return gx
    }

    /// Draw `tex` stretched over rect (x, y, w, h) in screen pixels (y down), modulated by `color`.
    public func drawScreenQuad(_ tex: MTLTexture, x: Float, y: Float, w: Float, h: Float, color: SIMD4<UInt8>,
                               uv: SIMD4<Float> = SIMD4(0, 0, 1, 1), screenWidth: Float, _ enc: MTLRenderCommandEncoder) {
        drawScreenQuads(tex, [(SIMD4(x, y, x + w, y + h), uv)], color: color, screenWidth: screenWidth, enc)
    }

    /// Batched variant: rects as (x0, y0, x1, y1) with matching uv rects (u0, v0, u1, v1).
    public func drawScreenQuads(_ tex: MTLTexture, _ quads: [(SIMD4<Float>, SIMD4<Float>)], color: SIMD4<UInt8>,
                                screenWidth: Float, _ enc: MTLRenderCommandEncoder, sampler: MTLSamplerState? = nil, intensityFont: Bool = false) {
        guard !quads.isEmpty else { return }
        let state = LytRenderer.spriteGX(color: color, intensityFont: intensityFont)
        var verts: [Float] = []
        verts.reserveCapacity(quads.count * 6 * 26)
        func v(_ x: Float, _ y: Float, _ u: Float, _ t: Float) {
            var a = [Float](repeating: 0, count: 26)
            a[0] = x; a[1] = y; a[6] = 1; a[7] = 1; a[8] = 1; a[9] = 1; a[10] = u; a[11] = t
            verts += a
        }
        for (r, uv) in quads {
            v(r.x, r.y, uv.x, uv.y); v(r.z, r.y, uv.z, uv.y); v(r.x, r.w, uv.x, uv.w)
            v(r.z, r.y, uv.z, uv.y); v(r.z, r.w, uv.z, uv.w); v(r.x, r.w, uv.x, uv.w)
        }
        guard let (buf, off) = gx.push(verts), let pipe = try? gx.pipeline(state) else { return }
        let vu = GXMetal.vertexUniforms(proj: LytRenderer.ortho2D(width: screenWidth), posMtx: matrix_identity_float4x4, pre: [], post: [], gx: state)
        let fu = GXMetal.fragmentUniforms(state, dims: [SIMD2(Int32(tex.logicalWidth), Int32(tex.logicalHeight))])
        enc.setCullMode(.none)
        enc.setRenderPipelineState(pipe)
        enc.setDepthStencilState(gx.depthState(state.zMode))
        enc.setVertexBuffer(buf, offset: off, index: 0)
        enc.setVertexBytes(vu, length: vu.count * 16, index: 1)
        enc.setFragmentBytes(fu, length: fu.count * 16, index: 0)
        let samp = sampler ?? gx.sampler(wrapS: 0, wrapT: 0, minFilter: 1, magFilter: 1)
        for i in 0..<8 {
            enc.setFragmentTexture(i == 0 ? tex : gx.whiteTexture, index: i)
            enc.setFragmentSamplerState(i == 0 ? samp : gx.defaultSampler, index: i)
        }
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: verts.count / 26)
    }

    /// Untextured coloured quad (fn_8002E79C-style fills / fades).
    public func drawScreenRect(x0: Float, y0: Float, x1: Float, y1: Float, color: SIMD4<UInt8>, screenWidth: Float, _ enc: MTLRenderCommandEncoder) {
        drawScreenQuad(gx.whiteTexture, x: x0, y: y0, w: x1 - x0, h: y1 - y0, color: color, screenWidth: screenWidth, enc)
    }

    /// Font sheet textures (shared cache with TextBox drawing).
    public func fontSheets(_ f: ResFont) -> FontSheets { sheets(f) }

    /// Upload an RGBA8 image once (keyed by caller).
    public func makeTexture(_ img: TPLFile.Image, label: String) -> MTLTexture {
        gx.makeTexture2D(img.rgba8, width: img.width, height: img.height, label: label)
    }
}
