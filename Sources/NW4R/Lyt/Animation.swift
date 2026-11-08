import RVL
import simd

/// nw4r::lyt::AnimTransformBasic — RLAN (BRLAN v8) layout animations.
/// Supports RLPA (pane SRT), RLVC (vertex colors + pane alpha), RLMC (material colors), RLVI (visibility),
/// RLTS (texture SRT) and RLTP (texture pattern).
public final class LytAnimation {
    public struct Key { public let frame: Float; public let value: Float; public let slope: Float }
    public struct Target { public let index: UInt8; public let target: UInt8; public let step: Bool; public let keys: [Key] }
    public struct AnimInfo { public let kind: String; public let targets: [Target] }
    public struct Content { public let name: String; public let isMaterial: Bool; public let infos: [AnimInfo] }

    public let frameSize: Int
    public let loop: Bool
    public let textureNames: [String]
    public let contents: [Content]

    public init(_ bytes: [UInt8]) throws {
        let r = BEReader(bytes)
        guard r.magic(0) == "RLAN" else { throw RVLError.badMagic(r.magic(0), expected: "RLAN") }
        var o = Int(r.u16(0xC))
        var fs = 0, lp = false, tex: [String] = [], cs: [Content] = []
        for _ in 0..<Int(r.u16(0xE)) {
            let magic = r.magic(o), size = Int(r.u32(o + 4))
            if magic == "pai1" {
                fs = Int(r.u16(o + 8)); lp = r.u8(o + 0xA) != 0
                let ntex = Int(r.u16(o + 0xC)), ncont = Int(r.u16(o + 0xE)), contOff = Int(r.u32(o + 0x10))
                let texBase = o + 0x14
                tex = (0..<ntex).map { r.cString(texBase + Int(r.u32(texBase + $0 * 4))) }
                for i in 0..<ncont {
                    let c = o + Int(r.u32(o + contOff + i * 4))
                    let name = r.cString(c), n = Int(r.u8(c + 20)), isMat = r.u8(c + 21) == 1
                    let infos = (0..<n).map { j -> AnimInfo in
                        let a = c + Int(r.u32(c + 24 + j * 4))
                        let nt = Int(r.u8(a + 4))
                        let targets = (0..<nt).map { k -> Target in
                            let t = a + Int(r.u32(a + 8 + k * 4))
                            let curve = r.u8(t + 2), nk = Int(r.u16(t + 4)), ko = t + Int(r.u32(t + 8))
                            let keys: [Key] = (0..<nk).map { q in
                                curve == 2 ? Key(frame: r.f32(ko + q * 12), value: r.f32(ko + q * 12 + 4), slope: r.f32(ko + q * 12 + 8))
                                           : Key(frame: r.f32(ko + q * 8), value: Float(r.u16(ko + q * 8 + 4)), slope: 0)
                            }
                            return Target(index: r.u8(t), target: r.u8(t + 1), step: curve != 2, keys: keys)
                        }
                        return AnimInfo(kind: r.magic(a), targets: targets)
                    }
                    cs.append(Content(name: name, isMaterial: isMat, infos: infos))
                }
            }
            o += size
        }
        frameSize = fs; loop = lp; textureNames = tex; contents = cs
    }

    /// nw4r::lyt::detail::GetHermiteCurveValue / GetStepCurveValue
    public static func evaluate(_ t: Target, frame: Float) -> Float {
        let k = t.keys
        guard let first = k.first, let last = k.last else { return 0 }
        if frame <= first.frame { return first.value }
        if frame >= last.frame { return last.value }
        var i = 0
        while i + 1 < k.count && k[i + 1].frame <= frame { i += 1 }
        let k0 = k[i], k1 = k[i + 1]
        if t.step { return k0.value }
        if k0.frame == k1.frame { return k1.value }
        let t1 = frame - k0.frame, t2 = 1 / (k1.frame - k0.frame)
        let t1t1t2 = t1 * t1 * t2, t1t1t2t2 = t1t1t2 * t2
        let t1t1t1t2t2 = t1 * t1t1t2t2, t1t1t1t2t2t2 = t1t1t1t2t2 * t2
        return k0.value * (2 * t1t1t1t2t2t2 - 3 * t1t1t2t2 + 1)
            + k1.value * (-2 * t1t1t1t2t2t2 + 3 * t1t1t2t2)
            + k0.slope * (t1t1t1t2t2 - 2 * t1t1t2 + t1)
            + k1.slope * (t1t1t1t2t2 - t1t1t2)
    }

    static func u8(_ v: Float) -> UInt8 { UInt8(max(0, min(255, v + 0.5))) }

    /// Apply the animation at `frame` to a layout (AnimTransformBasic::Animate on every bound pane/material).
    public func apply(to layout: Layout, frame: Float) {
        for c in contents {
            if c.isMaterial {
                guard let m = layout.materials.first(where: { $0.name == c.name }) else { continue }
                for info in c.infos { for t in info.targets { applyMaterial(info.kind, t, m, LytAnimation.evaluate(t, frame: frame)) } }
            } else {
                guard let p = layout.find(c.name) else { continue }
                for info in c.infos { for t in info.targets { applyPane(info.kind, t, p, LytAnimation.evaluate(t, frame: frame), layout) } }
            }
        }
    }

    private func applyPane(_ kind: String, _ t: Target, _ p: Pane, _ v: Float, _ layout: Layout) {
        switch kind {
        case "RLPA":
            switch t.target {
            case 0: p.translate.x = v; case 1: p.translate.y = v; case 2: p.translate.z = v
            case 3: p.rotate.x = v; case 4: p.rotate.y = v; case 5: p.rotate.z = v
            case 6: p.scale.x = v; case 7: p.scale.y = v
            case 8: p.size.x = v; case 9: p.size.y = v
            default: break
            }
        case "RLVC":
            if t.target == 16 { p.alpha = LytAnimation.u8(v); return }
            let corner = Int(t.target / 4), ch = Int(t.target % 4)
            if let pic = p as? Picture, corner < 4 { pic.vtxColors[corner][ch] = LytAnimation.u8(v) }
            else if let w = p as? Window, corner < 4 { w.vtxColors[corner][ch] = LytAnimation.u8(v) }
        case "RLVI":
            p.visible = v != 0
        case "RLMC", "RLTS", "RLTP":
            // Material animations addressed through a pane resolve to its material.
            let m = (p as? Picture)?.material ?? (p as? TextBox)?.material ?? (p as? Window)?.material
            if let m { applyMaterial(kind, t, m, v) }
        default: break
        }
    }

    private func applyMaterial(_ kind: String, _ t: Target, _ m: LytMaterial, _ v: Float) {
        switch kind {
        case "RLMC":
            let ch = Int(t.target % 4)
            switch t.target {
            case 0..<4:
                var c = m.matColor ?? SIMD4(255, 255, 255, 255); c[ch] = LytAnimation.u8(v); m.matColor = c
            case 4..<16:
                m.tevColors[Int(t.target - 4) / 4][ch] = Int32(max(-1024, min(1023, v.rounded())))
            case 16..<32:
                m.tevKColors[Int(t.target - 16) / 4][ch] = Int32(LytAnimation.u8(v))
            default: break
            }
        case "RLTS":
            let i = Int(t.index)
            guard i < m.texSRTs.count else { return }
            switch t.target {
            case 0: m.texSRTs[i].translate.x = v; case 1: m.texSRTs[i].translate.y = v
            case 2: m.texSRTs[i].rotate = v
            case 3: m.texSRTs[i].scale.x = v; case 4: m.texSRTs[i].scale.y = v
            default: break
            }
        case "RLTP":
            m.texturePatternOverride[Int(t.index)] = textureNames[safe: Int(v)]
        default: break
        }
    }
}
