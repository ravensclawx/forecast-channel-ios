import simd

/// nw4r::g3d texture-matrix calculation, ported from main.dol's g3d library
/// (decomp/notes/nw4r_g3d_texmtx.md):
///   fn_800A7388 LoadResTexSrt → fn_800AAD34 CalcTexMtx → fn_800AEE14 Maya / fn_800AF9B0 XSI / fn_800B0610 3dsMax
///   fn_800A5040 CalcEnvMtx (mapMode 1 env-camera, 3 env-light)
/// Final post-texture matrix (GX_PTTEXMTX0 + 3i):
///   mapMode 0:        P = SRT · Effect
///   env/projection:   P = SRT' · Effect · Env      (SRT' = SRT with its translation moved to column 2)
/// Pre-texture matrix for env layers: GX_TEXMTX(30+3i) = inverse-transpose of model-view (rotation only).
public enum G3DTexMtx {
    public typealias Mtx34 = (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)
    public static let identity: Mtx34 = (SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 1, 0))
    /// Camera::GetEnvironmentTexMtx default (Camera::Init sets 0.5/0.5/0.5/0.5): C
    public static let envC: Mtx34 = (SIMD4(0.5, 0, 0, 0.5), SIMD4(0, -0.5, 0, 0.5), SIMD4(0, 0, 0, 1))

    /// SRT matrix for a layer. `flags` is that layer's 4-bit nibble: bit1 scale==1, bit2 rot==0, bit3 trans==0.
    public static func srt(_ s: ResMat.TexSRT, mode: UInt32, flags: UInt32) -> Mtx34 {
        if (flags >> 1) & 7 == 7 { return identity }
        let r = s.rotation * .pi / 180, c = cos(r), sn = sin(r)   // SinCosFIdx(R·256/360)
        let Sx = s.scale.x, Sy = s.scale.y, Tx = s.translation.x, Ty = s.translation.y
        switch mode {
        case 0: // Maya (fn_800AE644; transcribed from m2c)
            return (SIMD4(Sx * c, Sx * sn, 0, Sx * (-0.5 * c - (0.5 * sn - 0.5) - Tx)),
                    SIMD4(-Sy * sn, Sy * c, 0, 1 + Sy * (Ty + (-0.5 * c + 0.5 * sn - 0.5))),
                    SIMD4(0, 0, 1, 0))
        case 1: // XSI (fn_800AF2F0; transcribed from m2c)
            return (SIMD4(Sx * c, -Sx * sn, 0, Sx * sn - Sx * c * Tx - Sx * sn * Ty),
                    SIMD4(Sy * sn, Sy * c, 0, 1 - Sy * c - Sy * sn * Tx + Sy * c * Ty),
                    SIMD4(0, 0, 1, 0))
        default: // 3dsMax (fn_800AFF00, verified against asm)
            return (SIMD4(Sx * c, Sx * sn, 0, 0.5 + (-Sx * c * (0.5 + Tx) + Sx * sn * (Ty - 0.5))),
                    SIMD4(-Sy * sn, Sy * c, 0, 0.5 + (Sy * sn * (0.5 + Tx) + Sy * c * (Ty - 0.5))),
                    SIMD4(0, 0, 1, 0))
        }
    }

    /// SRT' — translation moved from column 3 into column 2 (rows 0, 1).
    public static func srtForEnv(_ m: Mtx34) -> Mtx34 {
        (SIMD4(m.0.x, m.0.y, m.0.w, 0), SIMD4(m.1.x, m.1.y, m.1.w, 0), SIMD4(0, 0, 1, 0))
    }

    public static func mul(_ a: Mtx34, _ b: Mtx34) -> Mtx34 {
        func row(_ r: SIMD4<Float>) -> SIMD4<Float> {
            SIMD4(r.x * b.0.x + r.y * b.1.x + r.z * b.2.x,
                  r.x * b.0.y + r.y * b.1.y + r.z * b.2.y,
                  r.x * b.0.z + r.y * b.1.z + r.z * b.2.z,
                  r.x * b.0.w + r.y * b.1.w + r.z * b.2.w + r.w)
        }
        return (row(a.0), row(a.1), row(a.2))
    }

    public static func fromSimd(_ m: simd_float4x4) -> Mtx34 {
        (SIMD4(m.columns.0.x, m.columns.1.x, m.columns.2.x, m.columns.3.x),
         SIMD4(m.columns.0.y, m.columns.1.y, m.columns.2.y, m.columns.3.y),
         SIMD4(m.columns.0.z, m.columns.1.z, m.columns.2.z, m.columns.3.z))
    }
    static func zeroTranslation(_ m: Mtx34) -> Mtx34 { (SIMD4(m.0.x, m.0.y, m.0.z, 0), SIMD4(m.1.x, m.1.y, m.1.z, 0), SIMD4(m.2.x, m.2.y, m.2.z, 0)) }

    /// A g3d light as seen by CalcEnvMtx (lights live in view space; `useDirection` = LightObj flag bit 0 or 1).
    public struct EnvLight {
        public var enabled: Bool, useDirection: Bool, viewPos: SIMD3<Float>, viewDir: SIMD3<Float>
        public init(enabled: Bool, useDirection: Bool, viewPos: SIMD3<Float>, viewDir: SIMD3<Float>) {
            self.enabled = enabled; self.useDirection = useDirection; self.viewPos = viewPos; self.viewDir = viewDir
        }
    }

    /// fn_800A5040 CalcEnvMtx — the "Env" term.
    /// - curView/refViews: camera view matrices; camRef ≥ 0 selects an explicit camera.
    public static func calcEnv(camRef: Int8, lightRef: Int8, curView: simd_float4x4, refViews: [Int: simd_float4x4], light: EnvLight?) -> Mtx34 {
        if camRef >= 0, let ref = refViews[Int(camRef)] {
            let m = zeroTranslation(fromSimd(ref * curView.inverse))
            return mul(envC, m)
        }
        if lightRef >= 0, let l = light, l.enabled {
            // v: light vector in view space, then expressed relative to world via View⁻¹ (R = rotation part).
            let invView = curView.inverse
            let R = simd_float3x3(invView.columns.0.xyz3, invView.columns.1.xyz3, invView.columns.2.xyz3)
            var v = l.useDirection ? R * l.viewDir : -(R * l.viewPos)
            v = simd_normalize(v)
            var up = SIMD3<Float>(0, 1, 0)
            if abs(v.x) < 1e-6 && abs(v.z) < 1e-6 { up = SIMD3(0, 0, v.y > 0 ? 1 : -1) }
            let r = simd_normalize(simd_cross(v, up)), u = simd_cross(r, v)
            let basis: Mtx34 = (SIMD4(r, 0), SIMD4(u, 0), SIMD4(-v, 0))
            return mul(envC, zeroTranslation(mul(basis, fromSimd(invView))))
        }
        return envC // camRef −1 (current camera) or light disabled → camera sphere map
    }
}

extension SIMD4 where Scalar == Float { var xyz3: SIMD3<Float> { SIMD3(x, y, z) } }
