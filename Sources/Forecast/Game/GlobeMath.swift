import simd

// Shared math helpers from main.dol game code (see decomp/notes/globe.md §2).
// Matrices follow the Revolution SDK "Mtx" convention (3x4, column vectors, M·v), stored here as simd_float4x4.

enum GlobeMath {
    static let deg = Float.pi / 180

    /// PSMTXRotRad about an axis.
    static func rot(_ axis: Character, _ degrees: Float) -> simd_float4x4 {
        let r = degrees * deg, c = cos(r), s = sin(r)
        switch axis {
        case "x": return simd_float4x4(rows: [SIMD4(1, 0, 0, 0), SIMD4(0, c, -s, 0), SIMD4(0, s, c, 0), SIMD4(0, 0, 0, 1)])
        case "y": return simd_float4x4(rows: [SIMD4(c, 0, s, 0), SIMD4(0, 1, 0, 0), SIMD4(-s, 0, c, 0), SIMD4(0, 0, 0, 1)])
        default:  return simd_float4x4(rows: [SIMD4(c, -s, 0, 0), SIMD4(s, c, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(0, 0, 0, 1)])
        }
    }
    static func trans(_ x: Float, _ y: Float, _ z: Float) -> simd_float4x4 {
        var m = matrix_identity_float4x4; m.columns.3 = SIMD4(x, y, z, 1); return m
    }

    /// fn_80036834 / fn_80036880 / fn_800368CC  MtxPreRot{X,Y,Z}Deg: m = R(deg) · m
    static func preRot(_ m: inout simd_float4x4, _ axis: Character, _ degrees: Float) { m = rot(axis, degrees) * m }

    /// PSMTXMultVec (includes translation — matters for the camera "up" quirk).
    static func multVec(_ m: simd_float4x4, _ v: SIMD3<Float>) -> SIMD3<Float> { let r = m * SIMD4(v, 1); return SIMD3(r.x, r.y, r.z) }
    static func translation(_ m: simd_float4x4) -> SIMD3<Float> { SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z) }

    static func wrap180(_ a: Float) -> Float { var a = a; while a < -180 { a += 360 }; while a > 180 { a -= 360 }; return a }
    static func wrap360(_ a: Float) -> Float { var a = a.truncatingRemainder(dividingBy: 360); if a < 0 { a += 360 }; return a }
    static func clamp01(_ v: Float) -> Float { min(max(v, 0), 1) }

    /// fn_80035E1C ChaseValue → remaining |v - target|
    @discardableResult
    static func chaseValue(_ v: inout Float, _ target: Float, _ rate: Float, _ maxStep: Float, _ minStep: Float) -> Float {
        let d = v - target
        if v != target {
            if abs(d) < minStep { v = target }
            else {
                var step = d * rate
                if abs(step) < 0.0008 { v = target }
                else {
                    if abs(d) * rate > maxStep { step = step < 0 ? -maxStep : maxStep }
                    else if abs(d) * rate < minStep { step = step < 0 ? -minStep : minStep }
                    v -= step
                }
            }
        }
        return abs(v - target)
    }

    /// fn_80035ED0 ChaseAngle: as ChaseValue on [0,360) with the shortest-path delta; snaps when |delta·rate| <= snapEps.
    static func chaseAngle(_ a: inout Float, _ target: Float, _ rate: Float, _ maxStep: Float, _ snapEps: Float) {
        let cur = wrap360(a), tgt = wrap360(target)
        let d = wrap180(cur - tgt)
        var step = d * rate
        if abs(step) <= snapEps { a = tgt; return }
        if abs(step) > maxStep { step = step < 0 ? -maxStep : maxStep }
        a = wrap360(cur - step)
    }

    /// fn_8002BE14 ApproachAngle: 5%/frame toward target, snap under 0.008.
    static func approachAngle(_ a: inout Float, _ target: Float) {
        let d = wrap180(target - a)
        if abs(d) < 0.008 || abs(d * 0.05) < 0.008 { a = target; return }
        a = wrap360(a + d * 0.05)
    }
}
