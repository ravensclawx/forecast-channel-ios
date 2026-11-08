import Foundation
import Metal
import NW4R
import RVL
import simd

/// The manual's own pointer — not the nw4r::ef cursor of the channel: the manual library loads textures from the
/// HOME Menu language archive (fn_8007E37C, the CContentArc arc) and draws them with GX (fn_8007E67C).
///
///   - `arc/timg/defcursor_final64_a.tpl` (IA4, lbl_80330DA0): shape alpha + shading, TEXMAP1.
///   - `arc/timg/defcursor_final_p1..p4.tpl` (I4, lbl_801B5498[n].+10): the hand, TEXMAP0.
///   - lbl_801B5498[n] = { w 50, h 50, hotspot 0.38 / 0.92 (from the bottom, y up), colour }:
///     P1 (0,8C,FF) · P2 (FF,38,38) · P3 (10,BD,0D) · P4 (FF,9C,00).
///   - TEV: stage 0 colour = lerp(C0 = player colour, C1 = white, TEXC(hand)); stage 1 colour = PREV·TEXC(64_a),
///     alpha = A2·TEXA(64_a); A2 = visibility alpha.
///   - Quad (fn_800808DC) in the manual's ortho (fn_8002DC5C: x −W/2..W/2, y −228..228, y up), rotated by the
///     Wii Remote's horizon (c, s): up vector (s, c), origin = p − 0.38·W·(c, −s) − 0.92·H·(s, c).
///   - Visibility (fn_80082544 → +0): +0x32 per frame with input or pointer motion, −1 per frame, capped at
///     0x5DC (active remote); alpha = +0 ≥ 0x240 ? 0xC0 : +0/3.
public final class ManualCursor {
    public static let colors: [SIMD4<UInt8>] = [SIMD4(0, 0x8C, 0xFF, 0xFF), SIMD4(0xFF, 0x38, 0x38, 0xFF),
                                                SIMD4(0x10, 0xBD, 0x0D, 0xFF), SIMD4(0xFF, 0x9C, 0, 0xFF)]
    let shade: MTLTexture
    let hands: [MTLTexture]
    let pipeline: MTLRenderPipelineState
    let noDepth: MTLDepthStencilState?
    public var channel = 0
    /// lbl_80289410[ch].+0 visibility timer.
    public private(set) var visibility = 0
    private var lastPointer = SIMD2<Float>(-1, -1)

    public init(assets: Assets, device: MTLDevice, language suffix: String = "_ENG") throws {
        let arc = try assets.hbmArchive(suffix)
        func tex(_ name: String) throws -> MTLTexture {
            guard let d = arc.file("/arc/timg/\(name)"), let img = try TPLFile(d).images.first else { throw RVLError.missing(name) }
            let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: img.width, height: img.height, mipmapped: false)
            td.usage = .shaderRead
            guard let t = device.makeTexture(descriptor: td) else { throw RVLError.missing(name) }
            t.replace(region: MTLRegionMake2D(0, 0, img.width, img.height), mipmapLevel: 0, withBytes: img.rgba8, bytesPerRow: img.width * 4)
            return t
        }
        shade = try tex("defcursor_final64_a.tpl")
        hands = try (1...4).map { try tex("defcursor_final_p\($0).tpl") }
        pipeline = try ManualCursor.makePipeline(device)
        let dd = MTLDepthStencilDescriptor(); dd.depthCompareFunction = .always; dd.isDepthWriteEnabled = false
        noDepth = device.makeDepthStencilState(descriptor: dd)
    }

    public func reset() { visibility = 0; lastPointer = SIMD2(-1, -1) }

    /// fn_80082544 timer for the active remote: called once per manual frame.
    public func update(pad: KPad) {
        let moved = pad.pointerValid && simd_distance(pad.pointer, lastPointer) > 0.5
        lastPointer = pad.pointer
        if !pad.hold.isEmpty || moved { visibility += 0x32 }
        if visibility > 0 { visibility -= 1; visibility = min(visibility, 0x5DC) }
    }

    /// fn_8007E67C. `pointer` in logical px (0..screenWidth, y down); `twist` degrees, clockwise positive.
    public func draw(_ enc: MTLRenderCommandEncoder, pointer: SIMD2<Float>, twist: Float, screenWidth: Float) {
        let alpha = visibility >= 0x240 ? 0xC0 : visibility / 3
        guard alpha > 0 else { return }
        let w: Float = 50, h: Float = 50
        let r = twist * .pi / 180
        let c = cos(r), s = sin(r)
        // fn_8007E67C, y-up ortho centred on the screen.
        let px = pointer.x - screenWidth / 2, py = 228 - pointer.y
        let x0 = px - 0.38 * c * w - 0.92 * s * h
        let y0 = py + 0.38 * s * w - 0.92 * c * h
        // corners: bottom-left, +up (s,c)·H, +right (c,−s)·W
        let bl = SIMD2(x0, y0), tl = bl + SIMD2(s, c) * h, br = bl + SIMD2(c, -s) * w, tr = tl + SIMD2(c, -s) * w
        func ndc(_ p: SIMD2<Float>) -> SIMD2<Float> { SIMD2(p.x / (screenWidth / 2), p.y / 228) }
        // strip order TL, TR, BL, BR with uv (0,0) (1,0) (0,1) (1,1)
        var v: [SIMD4<Float>] = [SIMD4(ndc(tl).x, ndc(tl).y, 0, 0), SIMD4(ndc(tr).x, ndc(tr).y, 1, 0),
                                 SIMD4(ndc(bl).x, ndc(bl).y, 0, 1), SIMD4(ndc(br).x, ndc(br).y, 1, 1)]
        let col = ManualCursor.colors[min(channel, 3)]
        var u = [SIMD4<Float>(Float(col.x), Float(col.y), Float(col.z), 255) / 255, SIMD4<Float>(1, 1, 1, Float(alpha) / 255)]
        enc.setRenderPipelineState(pipeline)
        if let noDepth { enc.setDepthStencilState(noDepth) }
        enc.setVertexBytes(&v, length: MemoryLayout<SIMD4<Float>>.stride * 4, index: 0)
        enc.setFragmentBytes(&u, length: MemoryLayout<SIMD4<Float>>.stride * 2, index: 0)
        enc.setFragmentTexture(hands[min(channel, 3)], index: 0)
        enc.setFragmentTexture(shade, index: 1)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }

    static func makePipeline(_ device: MTLDevice) throws -> MTLRenderPipelineState {
        let src = """
        #include <metal_stdlib>
        using namespace metal;
        struct V { float4 p [[position]]; float2 uv; };
        vertex V mc_vs(uint id [[vertex_id]], constant float4* v [[buffer(0)]]) {
            V o; o.p = float4(v[id].xy, 0, 1); o.uv = v[id].zw; return o;
        }
        // C0 = player colour, C1 = white, A2 = visibility (u[1].w)
        fragment float4 mc_fs(V in [[stage_in]], constant float4* u [[buffer(0)]],
                              texture2d<float> hand [[texture(0)]], texture2d<float> shade [[texture(1)]]) {
            constexpr sampler s(filter::linear, address::clamp_to_edge);
            float hi = hand.sample(s, in.uv).r;
            float4 sh = shade.sample(s, in.uv);
            float3 c = mix(u[0].rgb, float3(1), hi) * sh.r;
            return float4(c, u[1].w * sh.a);
        }
        """
        let lib = try device.makeLibrary(source: src, options: nil)
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = lib.makeFunction(name: "mc_vs"); d.fragmentFunction = lib.makeFunction(name: "mc_fs")
        d.colorAttachments[0].pixelFormat = .bgra8Unorm
        d.depthAttachmentPixelFormat = .depth32Float
        let ca = d.colorAttachments[0]!
        ca.isBlendingEnabled = true
        ca.sourceRGBBlendFactor = .sourceAlpha; ca.destinationRGBBlendFactor = .oneMinusSourceAlpha
        ca.sourceAlphaBlendFactor = .one; ca.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        return try device.makeRenderPipelineState(descriptor: d)
    }
}
