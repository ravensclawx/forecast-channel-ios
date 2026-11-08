import Metal
import RVL
import NW4R
import simd

/// The space behind the globe: CAround +0x30C, a 0x4FF24-byte object built by fn_8002EC68 and drawn first in
/// GlobeScreen_Draw by fn_8002EFB8.
///
/// fn_8002EC68 (ctor): 0x2388 = 9096 stars, each a triangle 100 units out on −Z, (−s,−s) (3s,−s) (−s,3s) with
/// s = 0.0045 · size[i] (lbl_80184328, u8), turned by RotY(b)·RotX(a) where (a, b) = lbl_8017B508[i] (u16 angles,
/// 0x10000 = one turn; MTXRotTrig with CosFIdx/SinFIdx of u16/256).
///
/// fn_8002EFB8 (draw): Setup2DRender, Z test off; the globe camera's view matrix with its translation zeroed
/// (stars rotate with the camera, never move), C_MTXPerspective(40°, W/456, 1, 1000); vertex = position
/// (index16, f32 xyz), colour (index8 → lbl_80188A38 RGB8, the index per star from lbl_801866B0), texcoord (index8
/// 0/1/2 → lbl_8017B4F0 = (0,0) (1,0) (0,1)); texture TPLCommon image 0x60; TEV colour = lerp(RASC, ONE, TEXC),
/// alpha = TEXA · A0 with A0 = +4FF20; alpha blend.
///
/// fn_8002EF14 (GlobeScreen_StateNormal, with SimpleGlobe velLat/velLon): target = clamp(255 − 200·(|vLat|+|vLon|));
/// above it the alpha drops by 0x20 per frame (to the target), below it rises by 2 per frame (spinning fast hides
/// the stars; they come back slowly).
public final class StarField {
    public private(set) var alpha: UInt8 = 0     // +4FF20 (heap memory; starts transparent, fades in)
    let vertexBuffer: MTLBuffer
    let vertexCount: Int
    let texture: MTLTexture?
    let pipeline: MTLRenderPipelineState
    let sampler: MTLSamplerState
    let depthState: MTLDepthStencilState

    struct Vertex { var pos: SIMD3<Float>; var color: SIMD4<Float>; var uv: SIMD2<Float> }

    public init(device: MTLDevice, assets: Assets, colorFormat: MTLPixelFormat, depthFormat: MTLPixelFormat) throws {
        let dol = DOLImage(try assets.title.content(index: Assets.Content.mainDol.rawValue))
        let n = 0x2388
        let uvs = (0..<3).map { SIMD2(dol.f32(0x8017_B4F0 + UInt32($0) * 8), dol.f32(0x8017_B4F4 + UInt32($0) * 8)) }
        let base = (0..<3).map { SIMD3(dol.f32(0x8017_B4C8 + UInt32($0) * 12), dol.f32(0x8017_B4CC + UInt32($0) * 12),
                                       dol.f32(0x8017_B4D0 + UInt32($0) * 12)) }
        guard let (r, sizeOff) = dol.reader(0x8018_4328), let (_, colIdxOff) = dol.reader(0x8018_66B0),
              let (_, palOff) = dol.reader(0x8018_8A38), let (_, angOff) = dol.reader(0x8017_B508) else {
            throw RVLError.missing("star tables")
        }
        func rotX(_ a: Float) -> simd_float3x3 {
            let c = cos(a), s = sin(a)
            return simd_float3x3(rows: [SIMD3(1, 0, 0), SIMD3(0, c, -s), SIMD3(0, s, c)])
        }
        func rotY(_ a: Float) -> simd_float3x3 {
            let c = cos(a), s = sin(a)
            return simd_float3x3(rows: [SIMD3(c, 0, s), SIMD3(0, 1, 0), SIMD3(-s, 0, c)])
        }
        var verts: [Vertex] = []
        verts.reserveCapacity(n * 3)
        let turn = 2 * Float.pi / 65536
        for i in 0..<n {
            let s = 0.0045 * Float(r.u8(sizeOff + i))
            let a = Float(r.u16(angOff + i * 4)) * turn, b = Float(r.u16(angOff + i * 4 + 2)) * turn
            let m = rotY(b) * rotX(a)
            let ci = Int(r.u8(colIdxOff + i))
            let col = SIMD4(Float(r.u8(palOff + ci * 3)) / 255, Float(r.u8(palOff + ci * 3 + 1)) / 255,
                            Float(r.u8(palOff + ci * 3 + 2)) / 255, 1)
            let local = [SIMD3(-s, -s, base[0].z), SIMD3(3 * s, -s, base[1].z), SIMD3(-s, 3 * s, base[2].z)]
            for k in 0..<3 { verts.append(Vertex(pos: m * local[k], color: col, uv: uvs[k])) }
        }
        vertexCount = verts.count
        vertexBuffer = device.makeBuffer(bytes: verts, length: MemoryLayout<Vertex>.stride * verts.count)!

        // TPLCommon image 0x60 (fn_80031B88(lbl_80330C00, 0x60)).
        var tex: MTLTexture?
        if let c = try assets.archive(.weather).find("TPLCommon.tpl.LZ"),
           let tpl = try? TPLFile(CX.uncompressIfNeeded(c)), tpl.images.count > 0x60 {
            let im = tpl.images[0x60]
            let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: im.width, height: im.height, mipmapped: false)
            let t = device.makeTexture(descriptor: td)!
            t.replace(region: MTLRegionMake2D(0, 0, im.width, im.height), mipmapLevel: 0, withBytes: im.rgba8, bytesPerRow: im.width * 4)
            tex = t
        }
        texture = tex

        let src = """
        #include <metal_stdlib>
        using namespace metal;
        struct V { float3 pos; float4 color; float2 uv; };
        struct O { float4 pos [[position]]; float4 color; float2 uv; };
        vertex O star_vs(const device V* v [[buffer(0)]], constant float4x4& mvp [[buffer(1)]], uint id [[vertex_id]]) {
            O o; o.pos = mvp * float4(v[id].pos, 1); o.color = v[id].color; o.uv = v[id].uv; return o;
        }
        fragment float4 star_fs(O in [[stage_in]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]],
                                constant float& a0 [[buffer(0)]]) {
            float4 tx = t.sample(s, in.uv);
            float3 c = mix(in.color.rgb, float3(1.0), tx.rgb);   // lerp(RASC, ONE, TEXC)
            return float4(c, tx.a * a0);                        // TEXA · A0
        }
        """
        let lib = try device.makeLibrary(source: src, options: nil)
        let pd = MTLRenderPipelineDescriptor()
        pd.vertexFunction = lib.makeFunction(name: "star_vs")
        pd.fragmentFunction = lib.makeFunction(name: "star_fs")
        pd.colorAttachments[0].pixelFormat = colorFormat
        pd.colorAttachments[0].isBlendingEnabled = true
        pd.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        pd.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        pd.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
        pd.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        pd.depthAttachmentPixelFormat = depthFormat
        pipeline = try device.makeRenderPipelineState(descriptor: pd)
        let sd = MTLSamplerDescriptor()
        sd.minFilter = .linear; sd.magFilter = .linear
        sd.sAddressMode = .clampToEdge; sd.tAddressMode = .clampToEdge
        sampler = device.makeSamplerState(descriptor: sd)!
        let dd = MTLDepthStencilDescriptor()
        dd.isDepthWriteEnabled = false; dd.depthCompareFunction = .always
        depthState = device.makeDepthStencilState(descriptor: dd)!
    }

    /// fn_8002EF14
    public func update(velLat: Float, velLon: Float) {
        let target = UInt8(max(0, min(255, 255 - 200 * (abs(velLat) + abs(velLon)))))
        if alpha > target {
            alpha = alpha - target < 0x20 ? target : alpha - 0x20
        } else if alpha >= 0xFE {
            alpha = 0xFF
        } else {
            alpha += 2
        }
    }

    /// fn_8002EFB8. `aspect` = logical width / height (W/456 on the Wii); `fovy` 40° — the iPhone keeps the Wii's
    /// horizontal field of view and widens vertically.
    public func draw(_ enc: MTLRenderCommandEncoder, view: simd_float4x4, aspect: Float, fovy: Float) {
        guard alpha > 0, let texture else { return }
        var v = view
        v.columns.3 = SIMD4(0, 0, 0, 1)   // translation zeroed (sp7C/sp8C/sp9C = 0)
        var mvp = GlobeCamera.perspective(fovy: fovy, aspect: aspect, near: 1, far: 1000) * v
        var a0 = Float(alpha) / 255
        enc.setRenderPipelineState(pipeline)
        enc.setDepthStencilState(depthState)
        enc.setCullMode(.none)
        enc.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        enc.setVertexBytes(&mvp, length: MemoryLayout<simd_float4x4>.stride, index: 1)
        enc.setFragmentTexture(texture, index: 0)
        enc.setFragmentSamplerState(sampler, index: 0)
        enc.setFragmentBytes(&a0, length: 4, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertexCount)
    }
}
