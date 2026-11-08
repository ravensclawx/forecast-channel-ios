import simd

/// CGlobeCamera (0xEC bytes, vtable lbl_8019B750) — wraps g3d camera 0. Port of fn_8002B734..fn_8002BEF4.
public final class GlobeCamera {
    // Logical screen (the channel renders to a 608x456 EFB; 832x456 logical in widescreen).
    public static var screenHeight: Float { LogicalScreen.height }
    public let isWide: Bool
    public var screenWidth: Float { isWide ? 832 : 608 }

    public var up = SIMD3<Float>(0, 1, 0)        // 0x78
    public var target = SIMD3<Float>(0, 0, 0)    // 0x84
    public var lat: Float = 0                    // 0x90
    public var lon: Float = 0                    // 0x94
    public var surfaceRoll: Float = 0            // 0x98
    public var pitch: Float = 0                  // 0x9C
    public var yaw: Float = 0                    // 0xA0
    public var twist: Float = 0                  // 0xA4
    public var eye = SIMD3<Float>(0, 0, 0)       // 0xA8
    public var look = SIMD3<Float>(0, 0, 0)      // 0xB4
    public var orienting = false                 // 0xC0
    public var fovy: Float = 5.0                 // 0xC4
    public var aspect: Float                     // 0xC8
    public let near: Float = 0.1, far: Float = 200.0
    public var dist: Float = 100.0               // 0xD4

    public private(set) var viewMtx = matrix_identity_float4x4
    public private(set) var projMtx = matrix_identity_float4x4

    /// fn_8002B734
    public init(isWide: Bool) {
        self.isWide = isWide
        aspect = (isWide ? 832 : 608) / 456
        if LogicalScreen.isPortrait {
            // Portrait: keep the original 4:3 horizontal field of view (608 logical px wide, same pixel scale as the
            // Wii) and extend vertically — fovy grows with the taller screen.
            let h = LogicalScreen.height
            aspect = 608 / h
            let tanHalfX = tan(Float(2.5) * .pi / 180) * (608.0 / 456.0)
            fovy = 2 * atan(tanHalfX / aspect) * 180 / .pi
        }
    }

    /// fn_8002B8D4 Init(latLonRoll)
    public func initialize(latLonRoll: SIMD3<Float>?) {
        projMtx = GlobeCamera.perspective(fovy: fovy, aspect: aspect, near: near, far: far)
        if let v = latLonRoll { lat = v.x; lon = v.y; surfaceRoll = v.z }
    }

    /// fn_8002B9B0 Calc
    public func calc() {
        var m = GlobeMath.trans(0, 0, 3)
        GlobeMath.preRot(&m, "x", -lat); GlobeMath.preRot(&m, "z", surfaceRoll); GlobeMath.preRot(&m, "y", lon)
        target = GlobeMath.translation(m)
        let saved = m
        m = GlobeMath.trans(0, 0, dist)
        GlobeMath.preRot(&m, "x", pitch); GlobeMath.preRot(&m, "z", twist); GlobeMath.preRot(&m, "y", yaw)
        m = saved * m
        eye = GlobeMath.translation(m)
        up = GlobeMath.multVec(m, SIMD3(0, 1, 0))   // QUIRK preserved: translation included
        look = target - eye
        viewMtx = GlobeCamera.lookAt(eye: eye, up: up, target: target)
    }

    /// fn_8002BC28 StartOrient / fn_8002BD70 UpdateOrient (targets = {pitch, yaw, twist})
    public func startOrient(_ t: SIMD3<Float>) { orienting = true; stepOrient(t) }
    @discardableResult public func updateOrient(_ t: SIMD3<Float>) -> Bool { if orienting { stepOrient(t) }; return orienting }
    private func stepOrient(_ t: SIMD3<Float>) {
        GlobeMath.approachAngle(&pitch, t.x); GlobeMath.approachAngle(&yaw, t.y); GlobeMath.approachAngle(&twist, t.z)
        if pitch == t.x && yaw == t.y && twist == t.z { orienting = false }
    }
    /// fn_8002BCC4
    public func isAtOrient(_ t: SIMD3<Float>) -> Bool { abs(pitch - t.x) < 0.0008 && abs(yaw - t.y) < 0.0008 && abs(twist - t.z) < 0.0008 }

    /// fn_8002BEF4 Project world → logical screen pixels (0..screenWidth, 0..456, y down).
    public func project(_ world: SIMD3<Float>) -> SIMD2<Float> {
        let clip = projMtx * viewMtx * SIMD4(world, 1)
        let ndc = SIMD2(clip.x, clip.y) / clip.w
        let halfW = screenWidth / 2, halfH = GlobeCamera.screenHeight / 2
        return SIMD2(halfW + halfW * ndc.x, halfH - halfH * ndc.y)
    }

    /// C_MTXLookAt (Revolution SDK): right-handed, camera looks down -Z.
    public static func lookAt(eye: SIMD3<Float>, up: SIMD3<Float>, target: SIMD3<Float>) -> simd_float4x4 {
        let z = simd_normalize(eye - target)
        let x = simd_normalize(simd_cross(up, z))
        let y = simd_cross(z, x)
        return simd_float4x4(rows: [SIMD4(x, -simd_dot(x, eye)), SIMD4(y, -simd_dot(y, eye)), SIMD4(z, -simd_dot(z, eye)), SIMD4(0, 0, 0, 1)])
    }

    /// C_MTXPerspective, re-targeted from GX's clip-z range to Metal's [0, 1].
    public static func perspective(fovy: Float, aspect: Float, near: Float, far: Float) -> simd_float4x4 {
        let f = 1 / tan(fovy * GlobeMath.deg / 2)
        return simd_float4x4(rows: [SIMD4(f / aspect, 0, 0, 0), SIMD4(0, f, 0, 0),
                                    SIMD4(0, 0, far / (near - far), near * far / (near - far)), SIMD4(0, 0, -1, 0)])
    }
}
