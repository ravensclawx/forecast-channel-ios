import GX
import Metal
import NW4R
import RVL
import simd

/// The pointer cursor — CErrorSystem (ctor fn_8002C164) and its nw4r::ef cursor effects.
///
/// - CErrorSystem_ctor loads `nw4r_defcursor_all01.breff/.breft` (content 9) into the effect system.
/// - fn_800101C0 maps the game's cursor variable (lbl_801D6F98: 0 pointer, 1 open hand, 2 grab, 3 over a
///   button, 4 B-scroll) to a CErrorSystem state: 0/3 → 1, 1 → 3, 2 → 2, 4 → 5, via fn_80032324 → fn_8002C8E8.
/// - fn_8002C304 (from Input_Update, every frame) kills last frame's effects and creates fresh ones per remote:
///   the shadow `def_cursor_<kind>_sd` at (x+3, 456−y−3) and the hand `def_cursor_<kind>_<n>p` at (x, 456−y),
///   kind = lbl_8017B4A0[state] → normal/hold/open; runs EffectSystem::Calc once and sets each live
///   particle's rotate.z to the remote's roll and scales its colours (fn_8002CB1C).
/// - CErrorSystem_Update (System_Frame, after the scene) draws group 0 with an ortho of 0..W × 0..456 (y up) and
///   an identity view.
/// - State 5 is drawn directly by fn_8002C8E8 from TPLCommon images 2 (black, +3,+3) and 1 (white).
public final class Cursor {
    /// The game's cursor variable lbl_801D6F98[chan].
    public enum State: Int { case normal = 0, open = 1, hold = 2, hover = 3, scroll = 4 }
    public var state: State = .normal
    public var visible = true
    /// Player number shown on the hand (def_cursor_*_<n>p); the channel is single-remote here.
    public var channel = 0

    let system: EfEffectSystem
    let common: TPLFile?
    var textures: [String: MTLTexture] = [:]
    var commonTextures: [Int: MTLTexture] = [:]
    /// Effects alive since the last fn_8002C304 (CErrorSystem +0x30/+0x40/+0x50 per channel).
    var effects: [EfEffect] = []

    /// lbl_8017B4A0: CErrorSystem state → effect kind (−1 = drawn by fn_8002C8E8).
    static let kindForState = [0, 0, 1, 2, 2, -1]
    static let sdNames = ["def_cursor_normal_sd", "def_cursor_hold_sd", "def_cursor_open_sd"]       // lbl_8019B810
    static let handNames = ["normal", "hold", "open"].map { k in (1...4).map { "def_cursor_\(k)_\($0)p" } }   // lbl_8019B920

    public init(assets: Assets, renderer: LytRenderer) throws {
        let arc = try assets.archive(.weather)
        guard let ff = arc.find("nw4r_defcursor_all01.breff.LZ"), let tf = arc.find("nw4r_defcursor_all01.breft.LZ") else {
            throw RVLError.missing("nw4r_defcursor_all01")
        }
        system = EfEffectSystem(effects: try EfEffectFile(CX.uncompressIfNeeded(ff)), textures: try EfTextureFile(CX.uncompressIfNeeded(tf)))
        common = arc.find("TPLCommon.tpl.LZ").flatMap { try? TPLFile(CX.uncompressIfNeeded($0)) }
    }

    /// fn_800101C0: game cursor variable → CErrorSystem state.
    static func errorSystemState(_ s: State) -> Int {
        switch s {
        case .scroll: return 5
        case .open: return 3
        case .hold: return 2
        default: return 1
        }
    }

    /// fn_8002C304 for one remote: recreate the cursor effects, Calc once, apply the roll (fn_8002CB1C).
    /// `pointer` is in the SetOrtho2D space (x 0..W, y 0..456 down); `roll` in radians (KPAD horizon angle,
    /// clockwise positive on screen).
    func updateEffects(state: Int, pointer: SIMD2<Float>, roll: Float) {
        effects = []   // fn_80085150: kill last frame's
        let kind = Cursor.kindForState[state]
        guard kind >= 0 else { return }
        let x = pointer.x, y = 456 - pointer.y
        // State 4 (unused by this channel's fn_800101C0) adds a jittered second hand; not reachable.
        if let sd = system.createEffect(Cursor.sdNames[kind]) {
            sd.translate = SIMD3(3 + x, y - 3, 0)
            effects.append(sd)
        }
        if let hand = system.createEffect(Cursor.handNames[kind][min(channel, 3)]) {
            hand.translate = SIMD3(x, y, 0)
            effects.append(hand)
        }
        // fn_80085B54 / fn_80085A4C: EffectSystem::Calc(group 0).
        for fx in effects { fx.calc() }
        // fn_8002CB1C(effect, roll, scale 1.0): rotate.z and colour × scale on every live particle.
        for fx in effects {
            for pm in fx.particleManagers {
                for p in pm.particles where p.alive {
                    p.parameter.rotate.z = roll
                    // ×1.0 for these effects (0.85 only for the unused state-4 second hand).
                }
            }
        }
    }

    /// pointer: logical px (0..W, 0..456, y down); twist degrees (Wii Remote roll, clockwise positive).
    public func draw(_ r: LytRenderer, _ enc: MTLRenderCommandEncoder, pointer: SIMD2<Float>, twist: Float, screenWidth: Float) {
        guard visible else { return }
        // nw4r_math_Atan2FIdx(h.y, h.x) · 2π/256 of the horizon vector (cos, sin) = the roll angle.
        let roll = twist * .pi / 180
        let st = Cursor.errorSystemState(state)
        updateEffects(state: st, pointer: pointer, roll: roll)
        if st == 5 { drawScrollCursor(r, enc, pointer: pointer, roll: roll, screenWidth: screenWidth); return }
        // CErrorSystem_Update: C_MTXOrtho(456, 0, 0, W, −100, 100), identity view, EffectSystem::Draw(group 0).
        let proj = simd_float4x4(rows: [SIMD4(2 / screenWidth, 0, 0, -1), SIMD4(0, 2 / LogicalScreen.height, 0, -1),
                                        SIMD4(0, 0, -1 / 1000, 0.5), SIMD4(0, 0, 0, 1)])
        for fx in effects {
            for pm in fx.particleManagers {
                for pkt in EfDraw.draw(pm, textures: system.textures) { submit(r, enc, pkt, proj: proj) }
            }
        }
    }

    func texture(_ r: LytRenderer, _ t: EfTexture) -> MTLTexture {
        if let m = textures[t.name] { return m }
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: t.width, height: t.height, mipmapped: false)
        let m = r.gx.device.makeTexture(descriptor: td)!
        m.replace(region: MTLRegionMake2D(0, 0, t.width, t.height), mipmapLevel: 0, withBytes: t.rgba8, bytesPerRow: t.width * 4)
        m.label = t.name
        textures[t.name] = m
        return m
    }

    /// GXBegin(GX_QUADS) of one ef draw packet.
    func submit(_ r: LytRenderer, _ enc: MTLRenderCommandEncoder, _ pkt: EfDrawPacket, proj: simd_float4x4) {
        let gxm = r.gx
        var verts: [Float] = []
        func v(_ i: Int) {
            var a = [Float](repeating: 0, count: 26)
            let q = pkt.quad[i]
            a[0] = q.position.x; a[1] = q.position.y; a[2] = q.position.z
            a[6] = 1; a[7] = 1; a[8] = 1; a[9] = 1
            a[10] = q.texCoord.x; a[11] = q.texCoord.y
            verts += a
        }
        for i in [0, 1, 2, 0, 2, 3] { v(i) }
        guard let (buf, off) = gxm.push(verts), let pipe = try? gxm.pipeline(pkt.gx) else { return }
        let vu = GXMetal.vertexUniforms(proj: proj, posMtx: matrix_identity_float4x4, pre: pkt.texMtx, post: [], gx: pkt.gx)
        let fu = GXMetal.fragmentUniforms(pkt.gx, dims: pkt.textures.map { SIMD2(Int32($0.texture.width), Int32($0.texture.height)) })
        enc.setCullMode(.none)
        enc.setRenderPipelineState(pipe)
        enc.setDepthStencilState(gxm.depthState(pkt.gx.zMode))
        enc.setVertexBuffer(buf, offset: off, index: 0)
        enc.setVertexBytes(vu, length: vu.count * 16, index: 1)
        enc.setFragmentBytes(fu, length: fu.count * 16, index: 0)
        for i in 0..<8 {
            if i < pkt.textures.count {
                let t = pkt.textures[i]
                enc.setFragmentTexture(texture(r, t.texture), index: i)
                // GXInitTexObjLOD: GX_LINEAR / GX_LINEAR (mipmap ≤ 1).
                enc.setFragmentSamplerState(gxm.sampler(wrapS: t.wrapS, wrapT: t.wrapT, minFilter: 1, magFilter: 1), index: i)
            } else {
                enc.setFragmentTexture(gxm.whiteTexture, index: i)
                enc.setFragmentSamplerState(gxm.defaultSampler, index: i)
            }
        }
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
    }

    /// fn_8002C8E8 state 5: Setup2DRender + SetOrtho2D; position matrix fn_80031484(scale 1, horizon (cos, sin),
    /// translate) loaded to PNMTX1; TEVREG0 black → TPLCommon image 2 at (+3,+3), then white → image 1, both
    /// drawn by fn_80031BE8 at (−32, −32) with the image's own size.
    func drawScrollCursor(_ r: LytRenderer, _ enc: MTLRenderCommandEncoder, pointer: SIMD2<Float>, roll: Float, screenWidth: Float) {
        guard let common else { return }
        let c = cos(roll), s = sin(roll)
        for (img, off, color) in [(2, Float(3), SIMD4<UInt8>(0, 0, 0, 255)), (1, Float(0), SIMD4<UInt8>(255, 255, 255, 255))] {
            guard img < common.images.count else { continue }
            let im = common.images[img]
            let tex = commonTextures[img] ?? r.makeTexture(im, label: "TPLCommon.\(img)")
            commonTextures[img] = tex
            let t = pointer + SIMD2(off, off)
            func xf(_ p: SIMD2<Float>) -> SIMD2<Float> { SIMD2(c * p.x - s * p.y + t.x, s * p.x + c * p.y + t.y) }
            let w = Float(im.width), h = Float(im.height)
            let corners = [SIMD2<Float>(-32, -32), SIMD2(-32 + w, -32), SIMD2(-32, -32 + h), SIMD2(-32 + w, -32 + h)].map(xf)
            r.drawScreenTriangles(tex, corners: corners, color: color, screenWidth: screenWidth, enc)
        }
    }
}

extension LytRenderer {
    /// A textured quad with arbitrary corners (TL, TR, BL, BR) in SetOrtho2D pixels: Setup2DRender TEV
    /// (TEXC·C0 + C1, TEXA·A0 + A1 with C1 = 0).
    func drawScreenTriangles(_ tex: MTLTexture, corners c: [SIMD2<Float>], color: SIMD4<UInt8>, screenWidth: Float, _ enc: MTLRenderCommandEncoder) {
        let state = LytRenderer.spriteGX(color: color)
        var verts: [Float] = []
        let uv: [SIMD2<Float>] = [SIMD2(0, 0), SIMD2(1, 0), SIMD2(0, 1), SIMD2(1, 1)]
        for i in [0, 1, 2, 1, 3, 2] {
            var a = [Float](repeating: 0, count: 26)
            a[0] = c[i].x; a[1] = c[i].y; a[6] = 1; a[7] = 1; a[8] = 1; a[9] = 1; a[10] = uv[i].x; a[11] = uv[i].y
            verts += a
        }
        guard let (buf, off) = gx.push(verts), let pipe = try? gx.pipeline(state) else { return }
        let vu = GXMetal.vertexUniforms(proj: LytRenderer.ortho2D(width: screenWidth), posMtx: matrix_identity_float4x4, pre: [], post: [], gx: state)
        let fu = GXMetal.fragmentUniforms(state, dims: [SIMD2(Int32(tex.width), Int32(tex.height))])
        enc.setCullMode(.none)
        enc.setRenderPipelineState(pipe)
        enc.setDepthStencilState(gx.depthState(state.zMode))
        enc.setVertexBuffer(buf, offset: off, index: 0)
        enc.setVertexBytes(vu, length: vu.count * 16, index: 1)
        enc.setFragmentBytes(fu, length: fu.count * 16, index: 0)
        for i in 0..<8 {
            enc.setFragmentTexture(i == 0 ? tex : gx.whiteTexture, index: i)
            enc.setFragmentSamplerState(i == 0 ? gx.sampler(wrapS: 0, wrapT: 0, minFilter: 1, magFilter: 1) : gx.defaultSampler, index: i)
        }
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
    }
}
