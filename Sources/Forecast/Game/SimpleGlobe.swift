import GX
import NW4R
import simd

/// CSimpleGlobe (0xD0 bytes, "m_pSimpleGlobe", global lbl_80330BEC). Port of fn_8003F628..fn_800411B4.
/// Owns the globe camera and drives zoom, tilt, grab/inertia and the per-frame emboss material tweaks.
public final class SimpleGlobe {
    // Tables from .rodata
    static let kZoomDist: [Float] = [1, 2, 5, 8, 12, 17, 25, 40, 65, 100]                      // lbl_8018F730
    static let kFriction: [Float] = [0.85, 0.90, 0.95, 0.97, 0.98, 0.98, 0.98, 0.98, 0.98, 0.98] // lbl_8018F770
    static let kTilt: [Float] = [0, 45, 55, 65, 73, 80]                                          // lbl_8018F758
    static let kResetOrient = SIMD3<Float>(0, 0, 0)                                              // lbl_801D7264
    public static let kZoomSE: [Int] = [2, 3, 4, 5, 6, 7, 8, 9, 10, 11]                         // lbl_801793A0
    public static let kTiltSE: [Int] = [12, 13, 14, 15, 16, 17]                                  // lbl_801793C8

    public let camera: GlobeCamera                       // 0x04
    public var homeLatLon = SIMD3<Float>(0, 0, 0)        // 0x08
    let northPole = SIMD3<Float>(0, 3, 0)                // 0x14
    let southPole = SIMD3<Float>(0, -3, 0)               // 0x20
    var grabStartAngles = SIMD2<Float>(0, 0)             // 0x2C (single channel on Mac)
    var grabStartPointer = SIMD2<Float>(0, 0)            // 0x4C
    public var velLat: Float = 0, velLon: Float = 0       // 0x6C, 0x70
    public private(set) var northPoleScreen = SIMD2<Float>(0, 0), southPoleScreen = SIMD2<Float>(0, 0) // 0x7C, 0x84
    public private(set) var grabbing = false             // 0x8C
    public var inertiaActive = false                     // 0x90
    public var reqZoomOut = false, reqZoomIn = false, reqTiltUp = false, reqTiltDown = false // 0x91..0x94
    var levelLatitude = false                            // 0x95
    var nPoleBehindView = false, nPoleFacing = false, sPoleBehindView = false, sPoleFacing = false // 0x96..0x99
    var nPoleBehindCam = false, sPoleBehindCam = false   // 0x9A, 0x9B
    public private(set) var zoomIdx = 0                  // 0x9C
    public private(set) var tiltIdx = 0                  // 0xA0
    var grabStartTwist: Float = 0                        // 0xA4
    var distCur: Float = 0, distTarget: Float = 0        // 0xB4, 0xB8
    var pitchCur: Float = 0, pitchTarget: Float = 0      // 0xBC, 0xC0
    var grabStartHeading: Float = 0                      // 0xC4
    public private(set) var dist: Float = 0              // 0xC8
    var lonDragSign: Float = 1                           // 0xCC

    /// Camera 1 ("light" camera used as the emboss env-map source) — computed in UpdateMaterials.
    public private(set) var camera1View = matrix_identity_float4x4
    /// LightObj 0 (headlight) — UpdateLight.
    public private(set) var lightPos = SIMD3<Float>(0, 0, 0), lightDir = SIMD3<Float>(0, 0, -1)

    /// Hook for SE playback (sound_manager.cpp port comes later).
    public var playSE: (Int) -> Void = { _ in }

    /// fn_8003F628
    public init(isWide: Bool) { camera = GlobeCamera(isWide: isWide) }

    /// fn_8003F888 Reset(latLon, zoomIdx)
    public func reset(latLon: SIMD3<Float>, zoomIdx: Int) {
        reqZoomOut = false; reqZoomIn = false; reqTiltUp = false; reqTiltDown = false
        grabbing = false; inertiaActive = false; velLat = 0; velLon = 0
        homeLatLon = latLon
        self.zoomIdx = zoomIdx
        distCur = SimpleGlobe.kZoomDist[zoomIdx]; distTarget = distCur; camera.dist = distCur
        camera.initialize(latLonRoll: homeLatLon)
    }

    /// fn_8003FA7C Init(latLon) — entering the globe screen.
    public func initialize(latLon: SIMD3<Float>) { reset(latLon: latLon, zoomIdx: zoomIdx) }

    /// fn_80041074
    public func setZoomIndex(_ i: Int) { zoomIdx = i; distTarget = SimpleGlobe.kZoomDist[i] }
    /// fn_800402A4
    public func syncDist() { dist = camera.dist }
    /// fn_80040B08
    public func setTiltIndexImmediate(_ i: Int) {
        tiltIdx = i; pitchTarget = SimpleGlobe.kTilt[i]; pitchCur = pitchTarget; camera.pitch = pitchTarget; camera.orienting = false
    }
    /// fn_80040A48
    public func setTiltIndex(_ i: Int, level: Bool) {
        if zoomIdx >= 8 { levelLatitude = level }
        tiltIdx = i; pitchTarget = SimpleGlobe.kTilt[i]
        camera.startOrient(SimpleGlobe.kResetOrient)
    }
    /// fn_80040A78
    public func canReset() -> Bool {
        zoomIdx >= 8 ? !(abs(camera.lat) < 0.0008 && camera.isAtOrient(SimpleGlobe.kResetOrient)) : !camera.isAtOrient(SimpleGlobe.kResetOrient)
    }

    /// fn_8003FD7C CalcCamera
    public func calcCamera(materials: inout [ResMat]) {
        updateMaterials(&materials)
        camera.calc()
    }

    /// fn_8003FDBC CalcPoles
    public func calcPoles() {
        let lookN = simd_normalize(camera.look)
        func flags(_ pole: SIMD3<Float>) -> (behindView: Bool, facing: Bool, behindCam: Bool) {
            let toPole = simd_normalize(pole - camera.eye)
            return (simd_dot(simd_normalize(pole), lookN) < 0, simd_dot(simd_normalize(pole), toPole) < 0, simd_dot(lookN, toPole) < 0)
        }
        (nPoleBehindView, nPoleFacing, nPoleBehindCam) = flags(northPole)
        (sPoleBehindView, sPoleFacing, sPoleBehindCam) = flags(southPole)
        northPoleScreen = camera.project(northPole)
        southPoleScreen = camera.project(southPole)
    }

    /// fn_8004006C UpdateLight — white headlight at the eye.
    public func updateLight() { lightPos = camera.eye; lightDir = camera.look }

    /// fn_80040190 UpdateZoom
    public func updateZoom() {
        let old = zoomIdx
        if reqZoomOut { zoomIdx = min(zoomIdx + 1, 9) } else if reqZoomIn { zoomIdx = max(zoomIdx - 1, 0) }
        if reqZoomOut || reqZoomIn {
            distTarget = SimpleGlobe.kZoomDist[zoomIdx]
            if zoomIdx != old { playSE(SimpleGlobe.kZoomSE[zoomIdx]) }
        }
        distCur = camera.dist
        GlobeMath.chaseValue(&distCur, distTarget, 0.1, 100.0, 0.001)
        camera.dist = distCur
        dist = camera.dist
    }

    /// fn_80040B3C UpdateTilt
    public func updateTilt() {
        var moving = camera.updateOrient(SimpleGlobe.kResetOrient)
        let old = tiltIdx
        if reqTiltUp || reqTiltDown {
            tiltIdx = reqTiltUp ? min(tiltIdx + 1, 5) : max(tiltIdx - 1, 0)
            moving = true; pitchTarget = SimpleGlobe.kTilt[tiltIdx]; camera.orienting = false
            if tiltIdx != old { playSE(SimpleGlobe.kTiltSE[tiltIdx]) }
        }
        if !moving { pitchCur = camera.pitch; GlobeMath.chaseValue(&pitchCur, pitchTarget, 0.1, 100, 0.001); camera.pitch = pitchCur }
        if levelLatitude {
            if abs(camera.lat) < 0.0008 { levelLatitude = false; camera.lat = 0 }
            else if GlobeMath.chaseValue(&camera.lat, 0, 0.1, 100, 0.001) == 0 { levelLatitude = false }
        }
    }

    /// fn_800402BC TryBeginGrab
    public func tryBeginGrab(_ pad: KPad) -> Bool {
        guard pad.trig.contains(.a) else { return false }
        grabbing = true; camera.orienting = false; levelLatitude = false; inertiaActive = false
        grabStartAngles = SIMD2(camera.lat, camera.lon)
        grabStartPointer = pad.pointer
        grabStartHeading = camera.twist
        grabStartTwist = pad.twist
        lonDragSign = 1
        if nPoleFacing && !nPoleBehindCam { if grabStartPointer.y < northPoleScreen.y { lonDragSign = -1 } }
        else if sPoleFacing && !sPoleBehindCam { if grabStartPointer.y > southPoleScreen.y { lonDragSign = -1 } }
        return true
    }

    public enum GrabResult { case idle, dragging, released }

    /// fn_800405E4 UpdateGrab
    public func updateGrab(_ pad: KPad) -> GrabResult {
        let s = 0.5 * (0.01 * dist)
        guard grabbing else { return .idle }
        if !pad.hold.contains(.a) { grabbing = false; inertiaActive = true; return .released }
        let dTwist = pad.twist - grabStartTwist
        let heading: Float
        if abs(dTwist) > 30 {
            heading = GlobeMath.wrap360(dTwist + grabStartHeading)
            camera.orienting = false; velLat = 0; velLon = 0
        } else {
            heading = grabStartHeading
            let prevLat = camera.lat, prevLon = camera.lon
            var v = SIMD3<Float>(s * (pad.pointer.y - grabStartPointer.y), s * (pad.pointer.x - grabStartPointer.x), 0)
            if abs(camera.twist) < 0.0008 { v.y *= lonDragSign }
            let r = GlobeMath.rot("z", camera.twist) * SIMD4(v, 0)
            v = SIMD3(r.x, r.y, r.z)
            camera.lat = min(max(grabStartAngles.x + v.x, -89), 89)
            camera.lon = GlobeMath.wrap180(grabStartAngles.y - v.y)
            velLat = camera.lat - prevLat
            velLon = GlobeMath.wrap180(camera.lon - prevLon)
        }
        GlobeMath.chaseAngle(&camera.twist, heading, 0.1, 180, 1.0)
        return .dragging
    }

    /// fn_80040D48 UpdateInertia
    public func updateInertia(stop: Bool) {
        if stop { inertiaActive = false }
        guard inertiaActive else { return }
        camera.lat += velLat
        if camera.lat > 89 || camera.lat < -89 { camera.lat = min(max(camera.lat, -89), 89); velLat = 0 }
        camera.lon = GlobeMath.wrap180(camera.lon + velLon)
        let f = SimpleGlobe.kFriction[zoomIdx]
        let dLon = velLon * (1 - f)
        velLon -= dLon
        if abs(velLon) < 0.0008 { velLon = 0 }
        if abs(dLon) < 0.05 {
            velLat *= f
            if abs(velLat) < 0.0008 { velLat = 0 }
        } else if abs(velLat) >= 0.0008 {
            let step = min(abs(dLon), abs(velLat))
            velLat -= velLat < 0 ? -step : step
        }
        if (velLat * velLat + velLon * velLon).squareRoot() < 0.001 { inertiaActive = false; velLat = 0; velLon = 0 }
    }

    /// fn_800411B4 UpdateMaterials — distance-driven emboss + camera-1 env-map source.
    func updateMaterials(_ mats: inout [ResMat]) {
        let d = distCur
        let embossK = min(GlobeMath.clamp01((100 - d) / 35), GlobeMath.clamp01((d - 2) / 15))
        let edgeK = GlobeMath.clamp01((d - 40) / 20)
        let edgeScale = 0.85 + 0.15 * edgeK
        let shadeK = GlobeMath.clamp01((d - 2) / 15)
        // GXSetIndTexMatrix-style mantissa/exponent split
        var e: Int32 = 0, m = embossK
        if embossK > 1e-18 { e = Int32(Float(1 + embossK).exponent); m = embossK * pow(2, Float(-e)) }

        // Camera 1: the main camera shifted by (-¼, +¼)·dist.
        var M = GlobeMath.trans(-0.75, 0.75, 3)
        GlobeMath.preRot(&M, "x", -camera.lat); GlobeMath.preRot(&M, "z", camera.surfaceRoll); GlobeMath.preRot(&M, "y", camera.lon)
        let saved = M, t1 = GlobeMath.translation(M)
        M = GlobeMath.trans(-0.25 * camera.dist, 0.25 * camera.dist, camera.dist)
        GlobeMath.preRot(&M, "x", camera.pitch); GlobeMath.preRot(&M, "z", camera.twist); GlobeMath.preRot(&M, "y", camera.yaw)
        M = saved * M
        let eye1 = GlobeMath.translation(M)
        M.columns.3 = SIMD4(0, 0, 0, 1)
        let up1 = GlobeMath.multVec(M, SIMD3(0, 1, 0))
        camera1View = GlobeCamera.lookAt(eye: eye1, up: up1, target: t1)

        for i in mats.indices where mats[i].name != "luminous_mat" {
            mats[i].gx.konst[0].w = Int32(UInt8(77 * shadeK))
            mats[i].effects[1].mapMode = 1; mats[i].effects[1].camera = 1; mats[i].effects[1].light = -1
            mats[i].srt[3].scale = SIMD2(edgeScale, edgeScale)
            mats[i].gx.setIndMatrix(0, row0: SIMD3(m, 0, 0), row1: SIMD3(0, m, 0), scaleExp: e)
        }
    }
}
