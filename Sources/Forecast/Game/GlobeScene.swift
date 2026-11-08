import Metal
import NW4R
import simd

/// The globe ("around") screen's per-frame flow: fn_800186F0 (interactive state) → fn_8001A758 (zoom/grab/tilt)
/// → fn_80018BE0 (CalcCamera, CalcPoles, city markers, UpdateLight, CalcScene) → Draw.
///
/// INTERIM: the layout buttons (zoom_in/zoom_out/rot_a/rot_b/reset/back/next) arrive with the nw4r::lyt port;
/// until then only the hardware-button paths of the original code are wired (Plus/Minus/Up/Down) plus a
/// stand-in for the "reset" button.
public final class GlobeScene {
    public let globe: SimpleGlobe
    public let pad: KPad
    public let earth: G3DRenderer
    /// CAround +0x30C: the star field drawn behind the earth (fn_8002EFB8).
    public let stars: StarField?
    public var resetRequested = false
    public let sound: SoundManager?
    /// Cursor state per fn_800186F0: grabbing → hold, pointer outside 63<y<393 → arrow (normal), else open hand.
    public private(set) var cursorState: Cursor.State = .normal

    /// Default home location in CCityMarker (0x29C/0x2A0): 34.8, 135.4. The real start point is the
    /// user's configured city (d_weather_setting); wired when settings are ported.
    public static let defaultHome = SIMD3<Float>(34.8, 135.4, 0)

    public init(device: MTLDevice, assets: Assets, colorFormat: MTLPixelFormat, depthFormat: MTLPixelFormat, isWide: Bool = true,
                sound: SoundManager? = nil, pad: KPad = KPad()) throws {
        self.sound = sound; self.pad = pad
        let file = try assets.earthBRRES()
        earth = try G3DRenderer(device: device, file: file, model: "earth", colorFormat: colorFormat, depthFormat: depthFormat)
        stars = try? StarField(device: device, assets: assets, colorFormat: colorFormat, depthFormat: depthFormat)
        globe = SimpleGlobe(isWide: isWide)
        globe.playSE = { [weak sound] in sound?.playSE($0) }
        globe.setZoomIndex(0)
        globe.initialize(latLon: GlobeScene.defaultHome)
    }

    /// One 60 Hz frame of game logic.
    public func step(_ sample: PointerSample) {
        pad.update(sample)

        // fn_800186F0: request flags from (layout buttons |) hardware buttons
        globe.reqZoomOut = pad.trig.contains(.minus)
        globe.reqZoomIn = pad.trig.contains(.plus)
        globe.reqTiltUp = pad.trig.contains(.up)
        globe.reqTiltDown = pad.trig.contains(.down)
        if resetRequested { resetRequested = false; if !globe.camera.orienting { globe.playSE(0x13); globe.setTiltIndex(0, level: true) } }
        globe.updateInertia(stop: false)

        // fn_8001A758 zoom state: UpdateZoom, SyncDist, grab loop (fn_8001AA70), UpdateTilt
        globe.updateZoom()
        globe.syncDist()
        let y = pad.pointer.y
        if pad.pointerValid && !pad.isTap && y > 63 && y < 393 && globe.tryBeginGrab(pad) { globe.playSE(0x15) }
        if globe.updateGrab(pad) == .released {
            sound?.updateRotateSound(speed: (globe.velLat * globe.velLat + globe.velLon * globe.velLon).squareRoot())  // fn_800410A4(0x14)
        }
        globe.updateTilt()
        cursorState = globe.grabbing ? .hold : (pad.pointerValid && y > 63 && y < 393 ? .open : .normal)

        // fn_80018BE0
        globe.calcCamera(materials: &earth.materials)
        globe.calcPoles()
        globe.updateLight()
    }

    /// fn_8003FC10 Draw (scnRoot DrawOpa + DrawXlu).
    public func draw(_ enc: MTLRenderCommandEncoder) {
        // GlobeScreen_Draw: fn_8002EFB8 (stars) first, then SimpleGlobe_DrawEarth.
        if let stars {
            let cam = globe.camera
            if LogicalScreen.isPortrait {
                // keep the Wii's horizontal field of view (608 wide), extend vertically
                let aspect = 608 / LogicalScreen.height
                let tanHalfX = tan(Float(20) * .pi / 180) * (608.0 / 456.0)
                stars.draw(enc, view: cam.viewMtx, aspect: aspect, fovy: 2 * atan(tanHalfX / aspect) * 180 / .pi)
            } else {
                stars.draw(enc, view: cam.viewMtx, aspect: cam.screenWidth / 456, fovy: 40)
            }
        }
        var scene = G3DRenderer.Scene()
        scene.view = globe.camera.viewMtx
        scene.projection = globe.camera.projMtx
        scene.lightDirWorld = globe.lightDir
        scene.lightPosWorld = globe.lightPos
        scene.cameras[0] = globe.camera.viewMtx
        scene.cameras[1] = globe.camera1View
        earth.draw(enc, scene: scene)
    }
}
