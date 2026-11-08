import GX
import Metal
import simd

/// Shared GX→Metal plumbing: pipeline cache keyed by GXState, uniform packing, transient vertex ring.
public final class GXMetal {
    public let device: MTLDevice
    let colorFormat: MTLPixelFormat, depthFormat: MTLPixelFormat
    private var pipelines: [GXState: MTLRenderPipelineState] = [:]
    private var depthStates: [GXState.ZMode: MTLDepthStencilState] = [:]
    let whiteTexture: MTLTexture
    let defaultSampler: MTLSamplerState
    private var samplers: [UInt32: MTLSamplerState] = [:]

    // Transient vertices (3 frames in flight)
    private var rings: [MTLBuffer] = []
    private var ringIndex = 0, ringOffset = 0
    static let ringSize = 8 << 20

    public init(device: MTLDevice, colorFormat: MTLPixelFormat, depthFormat: MTLPixelFormat) {
        self.device = device; self.colorFormat = colorFormat; self.depthFormat = depthFormat
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
        whiteTexture = device.makeTexture(descriptor: td)!
        whiteTexture.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: [UInt8](repeating: 255, count: 4), bytesPerRow: 4)
        defaultSampler = device.makeSamplerState(descriptor: MTLSamplerDescriptor())!
        rings = (0..<3).map { _ in device.makeBuffer(length: GXMetal.ringSize, options: .storageModeShared)! }
    }

    private lazy var mipQueue: MTLCommandQueue? = device.makeCommandQueue()

    /// Every 2D texture upload: RGBA8 `px` at its original size. If `TextureOverrides` has an AI-upscaled version of
    /// these pixels, that is uploaded instead (mipmapped, so it minifies cleanly), and the texture is registered with
    /// its original logical size for geometry/UV math (`logicalWidth/Height`).
    /// One GPU texture per distinct image: every screen/helper that uploads the same pixels shares it (so a
    /// prewarmed image is ready everywhere, and nothing re-uploads mid-transition).
    private var uploaded: [Int: MTLTexture] = [:]

    public func makeTexture2D(_ px: [UInt8], width w: Int, height h: Int, label: String? = nil) -> MTLTexture {
        var hs = Hasher(); hs.combine(w); hs.combine(h); hs.combine(px)
        let key = hs.finalize()
        if let t = uploaded[key] { return t }
        let t = makeTexture2DUncached(px, width: w, height: h, label: label)
        uploaded[key] = t
        return t
    }

    private func makeTexture2DUncached(_ px: [UInt8], width w: Int, height h: Int, label: String?) -> MTLTexture {
        TextureOverrides.record(px, w, h)
        if let o = TextureOverrides.lookup(px, w, h) {
            let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: o.w, height: o.h, mipmapped: true)
            td.usage = [.shaderRead]
            let t = device.makeTexture(descriptor: td)!
            t.replace(region: MTLRegionMake2D(0, 0, o.w, o.h), mipmapLevel: 0, withBytes: o.px, bytesPerRow: o.w * 4)
            if let q = mipQueue, let cb = q.makeCommandBuffer(), let blit = cb.makeBlitCommandEncoder() {
                // finished before first use: unbuilt mip levels would draw blank (art popping in a frame later)
                blit.generateMipmaps(for: t); blit.endEncoding(); cb.commit(); cb.waitUntilCompleted()
            }
            t.label = (label ?? "") + " (×\(o.w / max(w, 1)))"
            TextureOverrides.setLogicalSize(t, w, h)
            return t
        }
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: false)
        let t = device.makeTexture(descriptor: td)!
        t.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: px, bytesPerRow: w * 4)
        t.label = label
        return t
    }

    public func beginFrame() { ringIndex = (ringIndex + 1) % rings.count; ringOffset = 0 }

    /// Copies vertices into the ring; returns (buffer, offset).
    func push(_ v: [Float]) -> (MTLBuffer, Int)? {
        let bytes = v.count * 4
        guard ringOffset + bytes <= GXMetal.ringSize else { return nil }
        let b = rings[ringIndex], o = ringOffset
        v.withUnsafeBytes { (b.contents() + o).copyMemory(from: $0.baseAddress!, byteCount: bytes) }
        ringOffset += (bytes + 255) & ~255
        return (b, o)
    }

    public func pipeline(_ gx: GXState) throws -> MTLRenderPipelineState {
        // Constants that only feed uniforms don't need distinct pipelines.
        var key = gx
        key.konst = []; key.tevRegs = []; key.chanMatColor = []; key.chanAmbColor = []
        for m in 0..<9 { key.bp[0x06 + m] &= 0x00C0_0000 }
        key.bp[0xF3] &= ~0xFFFF
        if let p = pipelines[key] { return p }
        let p = try G3DRenderer.makePipeline(device, gx, colorFormat, depthFormat, label: "gx")
        pipelines[key] = p
        return p
    }

    func depthState(_ z: GXState.ZMode) -> MTLDepthStencilState {
        if let d = depthStates[z] { return d }
        let dd = MTLDepthStencilDescriptor()
        dd.depthCompareFunction = z.test ? [.never, .less, .equal, .lessEqual, .greater, .notEqual, .greaterEqual, .always][z.function] : .always
        dd.isDepthWriteEnabled = z.update
        let d = device.makeDepthStencilState(descriptor: dd)!
        depthStates[z] = d
        return d
    }

    /// GX wrap (0 clamp, 1 repeat, 2 mirror) + filters → sampler.
    func sampler(wrapS: UInt32, wrapT: UInt32, minFilter: UInt32, magFilter: UInt32) -> MTLSamplerState {
        let key = wrapS | wrapT << 4 | minFilter << 8 | magFilter << 12
        if let s = samplers[key] { return s }
        let d = MTLSamplerDescriptor()
        let w: [MTLSamplerAddressMode] = [.clampToEdge, .repeat, .mirrorRepeat]
        d.sAddressMode = w[Int(min(wrapS, 2))]; d.tAddressMode = w[Int(min(wrapT, 2))]
        d.minFilter = [0, 2, 4].contains(minFilter) ? .nearest : .linear
        d.magFilter = magFilter == 0 ? .nearest : .linear
        // Trilinear for linear minification: only upscaled overrides carry mip levels (originals have one level,
        // so this changes nothing for them).
        if d.minFilter == .linear { d.mipFilter = .linear }
        let s = device.makeSamplerState(descriptor: d)!
        samplers[key] = s
        return s
    }

    public typealias Mtx34 = (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)
    static let identity34: Mtx34 = (SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 1, 0))

    /// Vertex uniforms (layout from GXShaderGen).
    static func vertexUniforms(proj: simd_float4x4, posMtx: simd_float4x4, pre: [Mtx34], post: [Mtx34], gx: GXState) -> [SIMD4<Float>] {
        var vu = [SIMD4<Float>](repeating: .zero, count: 62)
        vu[0] = proj.columns.0; vu[1] = proj.columns.1; vu[2] = proj.columns.2; vu[3] = proj.columns.3
        for r in 0..<3 {
            vu[4 + r] = SIMD4(posMtx.columns.0[r], posMtx.columns.1[r], posMtx.columns.2[r], posMtx.columns.3[r])
            vu[7 + r] = SIMD4(r == 0 ? 1 : 0, r == 1 ? 1 : 0, r == 2 ? 1 : 0, 0)
        }
        for i in 0..<8 {
            let a = i < pre.count ? pre[i] : identity34, b = i < post.count ? post[i] : identity34
            vu[10 + i * 3] = a.0; vu[11 + i * 3] = a.1; vu[12 + i * 3] = a.2
            vu[34 + i * 3] = b.0; vu[35 + i * 3] = b.1; vu[36 + i * 3] = b.2
        }
        func rgba(_ v: UInt32) -> SIMD4<Float> { SIMD4(Float(v >> 24), Float((v >> 16) & 0xFF), Float((v >> 8) & 0xFF), Float(v & 0xFF)) / 255 }
        vu[58] = rgba(gx.chanMatColor[0]); vu[59] = rgba(gx.chanMatColor[1])
        vu[60] = rgba(gx.chanAmbColor[0]); vu[61] = rgba(gx.chanAmbColor[1])
        return vu
    }

    /// Fragment uniforms (layout from GXShaderGen). `dims` = per texmap (w, h).
    static func fragmentUniforms(_ gx: GXState, dims: [SIMD2<Int32>]) -> [SIMD4<Int32>] {
        var fu = [SIMD4<Int32>](repeating: .zero, count: 33)
        for i in 0..<4 { fu[i] = gx.konst[i]; fu[4 + i] = gx.tevRegs[i] }
        for i in 0..<8 { let d = i < dims.count ? dims[i] : SIMD2(1, 1); fu[8 + i] = SIMD4(d.x, d.y, 0, 0) }
        var coordMap = [Int](repeating: -1, count: 8)
        for s in 0..<gx.numTevStages { let st = gx.tevStage(s); if st.texEnable, coordMap[st.texCoord] < 0 { coordMap[st.texCoord] = st.texMap } }
        for i in 0..<gx.numIndStages { let (m, c) = gx.indRef(i); if coordMap[c] < 0 { coordMap[c] = m } }
        for c in 0..<8 { fu[16 + c] = coordMap[c] >= 0 ? fu[8 + coordMap[c]] : SIMD4(1, 1, 0, 0) }
        for m in 0..<3 { let im = gx.indMatrix(m); fu[24 + m * 2] = SIMD4(im.row0, im.shift); fu[25 + m * 2] = SIMD4(im.row1, im.shift) }
        for i in 0..<4 { let (s, t) = gx.indScale(i); fu[30 + i / 2][(i & 1) * 2] = Int32(s); fu[30 + i / 2][(i & 1) * 2 + 1] = Int32(t) }
        let ac = gx.alphaCompare
        fu[32] = SIMD4(Int32(ac.ref0), Int32(ac.ref1), 0, 0)
        return fu
    }
}
