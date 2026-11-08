import GX
import Metal
import NW4R
import simd

/// Metal backend for nw4r::g3d model drawing (the role ScnMdl + GX play on the console).
/// Each ResMat's GXState is compiled once into a Metal pipeline via GXShaderGen.
public final class G3DRenderer {
    public let device: MTLDevice
    let colorFormat: MTLPixelFormat, depthFormat: MTLPixelFormat

    struct GPUShape { let vb: MTLBuffer; let ib: MTLBuffer; let count: Int }
    struct GPUMat {
        let pipeline: MTLRenderPipelineState
        let depth: MTLDepthStencilState
        let textures: [MTLTexture?]   // by texMap slot
        let samplers: [MTLSamplerState?]
        let cull: MTLCullMode
    }

    public let model: ResMdl
    /// Runtime material copies (ScnMdl bufferOption=1): game code mutates these per frame.
    public var materials: [ResMat]
    private var shapes: [GPUShape] = []
    private var mats: [GPUMat] = []
    private let dummyTex: MTLTexture, dummySampler: MTLSamplerState

    /// Scene inputs supplied by the game code (camera from d_scene / SimpleGlobe, light from its LightSet).
    public struct Scene {
        public var view = matrix_identity_float4x4
        public var projection = matrix_identity_float4x4
        public var lightDirWorld = SIMD3<Float>(0, 0, -1)
        public var lightPosWorld = SIMD3<Float>(0, 0, 0)
        /// g3d ScnRoot cameras by index (TexMtxEffect camRef); -1/absent → the current camera (`view`).
        public var cameras: [Int: simd_float4x4] = [:]
        public init() {}
    }

    public init(device: MTLDevice, file: ResFile, model name: String, colorFormat: MTLPixelFormat, depthFormat: MTLPixelFormat) throws {
        self.device = device; self.colorFormat = colorFormat; self.depthFormat = depthFormat
        guard let mdl = file.models[name] else { throw NSError(domain: "G3D", code: 1, userInfo: [NSLocalizedDescriptionKey: "no model \(name)"]) }
        model = mdl
        materials = mdl.materials

        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
        dummyTex = device.makeTexture(descriptor: td)!
        dummyTex.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: [UInt8](repeating: 255, count: 4), bytesPerRow: 4)
        dummySampler = device.makeSamplerState(descriptor: MTLSamplerDescriptor())!

        for s in mdl.shapes {
            let vb = device.makeBuffer(bytes: s.vertices, length: s.vertices.count * 4)!
            let ib = device.makeBuffer(bytes: s.indices, length: s.indices.count * 4)!
            shapes.append(GPUShape(vb: vb, ib: ib, count: s.indices.count))
        }

        var texCache: [String: MTLTexture] = [:]
        var pipeCache: [GXState: MTLRenderPipelineState] = [:]
        for m in mdl.materials {
            var textures = [MTLTexture?](repeating: nil, count: 8), samplers = [MTLSamplerState?](repeating: nil, count: 8)
            for l in m.layers where l.texMap < 8 {
                if texCache[l.texture] == nil, let t = file.textures[l.texture] { texCache[l.texture] = G3DRenderer.upload(device, t) }
                textures[l.texMap] = texCache[l.texture]
                samplers[l.texMap] = G3DRenderer.sampler(device, l)
            }
            let pipe: MTLRenderPipelineState
            if let p = pipeCache[m.gx] { pipe = p } else {
                pipe = try G3DRenderer.makePipeline(device, m.gx, colorFormat, depthFormat, label: m.name)
                pipeCache[m.gx] = pipe
            }
            let z = m.gx.zMode
            let dd = MTLDepthStencilDescriptor()
            dd.depthCompareFunction = z.test ? [.never, .less, .equal, .lessEqual, .greater, .notEqual, .greaterEqual, .always][z.function] : .always
            dd.isDepthWriteEnabled = z.update
            // GXCullMode: 0 none, 1 front, 2 back, 3 all
            let cull: MTLCullMode = [MTLCullMode.none, .front, .back, .none][Int(m.cullMode & 3)]
            mats.append(GPUMat(pipeline: pipe, depth: device.makeDepthStencilState(descriptor: dd)!, textures: textures, samplers: samplers, cull: cull))
        }
    }

    static func upload(_ device: MTLDevice, _ t: ResTex) -> MTLTexture {
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: t.width, height: t.height, mipmapped: false)
        td.usage = .shaderRead
        let tex = device.makeTexture(descriptor: td)!
        let px = t.rgba8()
        tex.replace(region: MTLRegionMake2D(0, 0, t.width, t.height), mipmapLevel: 0, withBytes: px, bytesPerRow: t.width * 4)
        tex.label = t.name
        return tex
    }

    static func sampler(_ device: MTLDevice, _ l: ResMat.Layer) -> MTLSamplerState {
        let d = MTLSamplerDescriptor()
        let wrap: [MTLSamplerAddressMode] = [.clampToEdge, .repeat, .mirrorRepeat]
        d.sAddressMode = wrap[min(l.wrapS, 2)]; d.tAddressMode = wrap[min(l.wrapT, 2)]
        // GXTexFilter: 0 near, 1 linear, 2 near_mip_near, 3 lin_mip_near, 4 near_mip_lin, 5 lin_mip_lin
        d.minFilter = [0, 2, 4].contains(l.minFilter) ? .nearest : .linear
        d.magFilter = l.magFilter == 0 ? .nearest : .linear
        return device.makeSamplerState(descriptor: d)!
    }

    static func makePipeline(_ device: MTLDevice, _ gx: GXState, _ cf: MTLPixelFormat, _ df: MTLPixelFormat, label: String) throws -> MTLRenderPipelineState {
        let lib = try device.makeLibrary(source: GXShaderGen.generate(gx), options: nil)
        let pd = MTLRenderPipelineDescriptor()
        pd.label = label
        pd.vertexFunction = lib.makeFunction(name: "gx_vs"); pd.fragmentFunction = lib.makeFunction(name: "gx_fs")
        let vd = MTLVertexDescriptor()
        let attrs: [(MTLVertexFormat, Int)] = [(.float3, 0), (.float3, 12), (.float4, 24)] + (0..<8).map { (.float2, 40 + $0 * 8) }
        for (i, a) in attrs.enumerated() { vd.attributes[i].format = a.0; vd.attributes[i].offset = a.1; vd.attributes[i].bufferIndex = 0 }
        vd.layouts[0].stride = GXShaderGen.vertexStride
        pd.vertexDescriptor = vd
        pd.colorAttachments[0].pixelFormat = cf
        pd.depthAttachmentPixelFormat = df
        let b = gx.blendMode
        if b.enable {
            // GXBlendFactor: 0 zero, 1 one, 2 srcclr/dstclr, 3 invsrcclr/invdstclr, 4 srcalpha, 5 invsrcalpha, 6 dstalpha, 7 invdstalpha
            let src: [MTLBlendFactor] = [.zero, .one, .destinationColor, .oneMinusDestinationColor, .sourceAlpha, .oneMinusSourceAlpha, .destinationAlpha, .oneMinusDestinationAlpha]
            let dst: [MTLBlendFactor] = [.zero, .one, .sourceColor, .oneMinusSourceColor, .sourceAlpha, .oneMinusSourceAlpha, .destinationAlpha, .oneMinusDestinationAlpha]
            let ca = pd.colorAttachments[0]!
            ca.isBlendingEnabled = true
            ca.sourceRGBBlendFactor = src[b.srcFactor]; ca.destinationRGBBlendFactor = dst[b.dstFactor]
            ca.sourceAlphaBlendFactor = src[b.srcFactor]; ca.destinationAlphaBlendFactor = dst[b.dstFactor]
            ca.rgbBlendOperation = b.subtract ? .reverseSubtract : .add
        }
        return try device.makeRenderPipelineState(descriptor: pd)
    }

    // MARK: - Drawing

    /// Per-bone world matrices (game code may override, e.g. SimpleGlobe rotation on the "earth" bone).
    public var boneWorld: [simd_float4x4] = []

    public func draw(_ enc: MTLRenderCommandEncoder, scene: Scene) {
        if boneWorld.count != model.bones.count { boneWorld = model.bones.map { _ in matrix_identity_float4x4 } }
        enc.setFrontFacing(.clockwise) // GX treats clockwise screen-space winding as front-facing
        for call in model.drawOpa { drawCall(enc, call, scene) }
        for call in model.drawXlu { drawCall(enc, call, scene) }
    }

    private func drawCall(_ enc: MTLRenderCommandEncoder, _ call: ResMdl.DrawCall, _ scene: Scene) {
        let mat = materials[call.material], gm = mats[call.material], gs = shapes[call.shape]
        let bone = model.bones[call.bone]
        var mv = scene.view * boneWorld[call.bone]
        if bone.billboard != 0 {
            // nw4r BILLBOARD_STD: keep translation/scale, replace rotation with the screen plane.
            let sx = simd_length(SIMD3(mv.columns.0.x, mv.columns.0.y, mv.columns.0.z))
            let sy = simd_length(SIMD3(mv.columns.1.x, mv.columns.1.y, mv.columns.1.z))
            let sz = simd_length(SIMD3(mv.columns.2.x, mv.columns.2.y, mv.columns.2.z))
            mv.columns.0 = SIMD4(sx, 0, 0, 0); mv.columns.1 = SIMD4(0, sy, 0, 0); mv.columns.2 = SIMD4(0, 0, sz, 0)
        }
        let nrm = simd_float3x3(SIMD3(mv.columns.0.x, mv.columns.0.y, mv.columns.0.z),
                                SIMD3(mv.columns.1.x, mv.columns.1.y, mv.columns.1.z),
                                SIMD3(mv.columns.2.x, mv.columns.2.y, mv.columns.2.z)).inverse.transpose

        var vu = [SIMD4<Float>](repeating: .zero, count: 4 + 3 + 3 + 24 + 24 + 4)
        let p = scene.projection
        vu[0] = p.columns.0; vu[1] = p.columns.1; vu[2] = p.columns.2; vu[3] = p.columns.3
        for r in 0..<3 {
            vu[4 + r] = SIMD4(mv.columns.0[r], mv.columns.1[r], mv.columns.2[r], mv.columns.3[r])
            vu[7 + r] = SIMD4(nrm.columns.0[r], nrm.columns.1[r], nrm.columns.2[r], 0)
        }
        // fn_800A77D8 (pre-matrices) + fn_800A7388 LoadResTexSrt (post-matrices), see G3DTexMtx.
        let envLight = G3DTexMtx.EnvLight(enabled: true, useDirection: true, viewPos: (scene.view * SIMD4(scene.lightPosWorld, 1)).xyz,
                                          viewDir: simd_normalize((scene.view * SIMD4(scene.lightDirWorld, 0)).xyz))
        for i in 0..<mat.gx.numTexGens {
            let fx = mat.effects[i]
            let nib = (mat.srtFlags >> (UInt32(i) * 4)) & 0xF
            let srt = G3DTexMtx.srt(mat.srt[i], mode: mat.texMtxMode, flags: nib)
            let effect: G3DTexMtx.Mtx34 = fx.identity ? G3DTexMtx.identity
                : (SIMD4(fx.matrix[0], fx.matrix[1], fx.matrix[2], fx.matrix[3]), SIMD4(fx.matrix[4], fx.matrix[5], fx.matrix[6], fx.matrix[7]),
                   SIMD4(fx.matrix[8], fx.matrix[9], fx.matrix[10], fx.matrix[11]))
            var pre = G3DTexMtx.identity, post: G3DTexMtx.Mtx34
            switch fx.mapMode {
            case 1, 3, 4: // env camera / env light / env spec: pre = model-view normal matrix
                pre = (SIMD4(vu[7].xyz, 0), SIMD4(vu[8].xyz, 0), SIMD4(vu[9].xyz, 0))
                let env = G3DTexMtx.calcEnv(camRef: fx.camera, lightRef: fx.mapMode == 1 ? -1 : fx.light, curView: scene.view,
                                            refViews: scene.cameras, light: envLight)
                post = G3DTexMtx.mul(G3DTexMtx.mul(G3DTexMtx.srtForEnv(srt), effect), env)
            default:
                post = G3DTexMtx.mul(srt, effect)
            }
            vu[10 + i * 3] = pre.0; vu[11 + i * 3] = pre.1; vu[12 + i * 3] = pre.2
            vu[34 + i * 3] = post.0; vu[35 + i * 3] = post.1; vu[36 + i * 3] = post.2
        }
        func rgba(_ v: UInt32) -> SIMD4<Float> { SIMD4(Float(v >> 24), Float((v >> 16) & 0xFF), Float((v >> 8) & 0xFF), Float(v & 0xFF)) / 255 }
        vu[58] = rgba(mat.gx.chanMatColor[0]); vu[59] = rgba(mat.gx.chanMatColor[1])
        vu[60] = rgba(mat.gx.chanAmbColor[0]); vu[61] = rgba(mat.gx.chanAmbColor[1])

        var fu = [SIMD4<Int32>](repeating: .zero, count: 4 + 4 + 8 + 8 + 6 + 2 + 1)
        for i in 0..<4 { fu[i] = mat.gx.konst[i]; fu[4 + i] = mat.gx.tevRegs[i] }
        for i in 0..<8 { if let t = gm.textures[i] { fu[8 + i] = SIMD4(Int32(t.width), Int32(t.height), 0, 0) } else { fu[8 + i] = SIMD4(1, 1, 0, 0) } }
        // Texcoord scale: GX derives each coordinate's scale from the first texmap that uses it.
        var coordMap = [Int](repeating: -1, count: 8)
        for s in 0..<mat.gx.numTevStages { let st = mat.gx.tevStage(s); if st.texEnable, coordMap[st.texCoord] < 0 { coordMap[st.texCoord] = st.texMap } }
        for i in 0..<mat.gx.numIndStages { let (m, c) = mat.gx.indRef(i); if coordMap[c] < 0 { coordMap[c] = m } }
        for c in 0..<8 { fu[16 + c] = coordMap[c] >= 0 ? fu[8 + coordMap[c]] : SIMD4(1, 1, 0, 0) }
        for m in 0..<3 {
            let im = mat.gx.indMatrix(m)
            fu[24 + m * 2] = SIMD4(im.row0, im.shift); fu[25 + m * 2] = SIMD4(im.row1, im.shift)
        }
        for i in 0..<4 { let (s, t) = mat.gx.indScale(i); fu[30 + i / 2][(i & 1) * 2] = Int32(s); fu[30 + i / 2][(i & 1) * 2 + 1] = Int32(t) }
        let ac = mat.gx.alphaCompare
        fu[32] = SIMD4(Int32(ac.ref0), Int32(ac.ref1), 0, 0)

        enc.setRenderPipelineState(gm.pipeline)
        enc.setDepthStencilState(gm.depth)
        enc.setCullMode(gm.cull)
        enc.setVertexBuffer(gs.vb, offset: 0, index: 0)
        enc.setVertexBytes(vu, length: vu.count * 16, index: 1)
        enc.setFragmentBytes(fu, length: fu.count * 16, index: 0)
        for i in 0..<8 {
            enc.setFragmentTexture(gm.textures[i] ?? dummyTex, index: i)
            enc.setFragmentSamplerState(gm.samplers[i] ?? dummySampler, index: i)
        }
        enc.drawIndexedPrimitives(type: .triangle, indexCount: gs.count, indexType: .uint32, indexBuffer: gs.ib, indexBufferOffset: 0)
    }
}

extension SIMD4 where Scalar == Float { var xyz: SIMD3<Float> { SIMD3(x, y, z) } }
