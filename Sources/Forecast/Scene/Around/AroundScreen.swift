import Metal
import NW4R
import simd

/// CAround (d_weather_around.cpp, 0x80017548–0x8001C2A4) — the globe screen.
/// Interactive frame = fn_80018C9C (+ fn_8001A758 zoom/grab, fn_80018BE0 camera/markers/light).
public final class AroundScreen: Screen {
    let ctx: SceneContext
    let around: UILayout          // +6C: zoom_out, zoom_in, next, back, rot_a, rot_b, reset
    let belt: UILayout            // +70: mode title (+ JP-only legend panes kion/rain/high)
    public private(set) var markers: [CityMarker] = []
    var globe: SimpleGlobe { ctx.globeScene.globe }
    let sprites: SpriteText?
    let telop: TelopText
    var cityFont: ResFont? { ctx.assets.font("font_weather_city.brfnt") }

    /// Display-mode table for non-JP languages, lbl_80179B98[mode] = {draw PTMF, box-size PTMF, day}:
    ///   0 {fn_80019268 icons, fn_8001C074 90×90,  day 2}  CURRENT WEATHER
    ///   1 {fn_800198A4 temp,  fn_8001C0B0 digits, day 2}  CURRENT TEMPERATURE
    ///   2 {fn_80019268 icons, fn_8001C074,        day 0}  TODAY'S WEATHER
    ///   3 {fn_80019734 high,  fn_8001C0B0,        day 0}  TODAY'S HIGH
    ///   4 {fn_80019268 icons, fn_8001C074,        day 1}  TOMORROW'S WEATHER
    ///   5 {fn_80019734 high,  fn_8001C0B0,        day 1}  TOMORROW'S HIGH
    /// Day 2 = current conditions (short.bin), 0 = today, 1 = tomorrow (fn_8000A764).
    public enum Mode: Int { case currentWeather, currentTemp, todayWeather, todayHigh, tomorrowWeather, tomorrowHigh
        public var day: Int { [2, 2, 0, 0, 1, 1][rawValue] }
        public var showsNumber: Bool { rawValue % 2 == 1 }
    }
    public var mode: Mode { Mode(rawValue: ctx.globeMode) ?? .currentWeather }

    /// Marker scale (CAround +0x298): non-JP 0.26 + 0.2/√dist; JP min(0.24 + 0.6/√dist, 0.6).
    var markerScale: Float {
        let d = max(globe.dist, 0.0001)
        return ctx.lang == .jp ? min(0.24 + 0.6 / d.squareRoot(), 0.6) : 0.26 + 0.2 / d.squareRoot()
    }

    public init(ctx: SceneContext) throws {
        self.ctx = ctx
        around = try ctx.layout("around.brlyt")
        belt = try ctx.layout("around_belt.brlyt")
        sprites = try? SpriteText(ctx: ctx)
        telop = TelopText(ctx: ctx)
        // CAround ctor 0x80017980: fn_800393E8(belt wrapper, "beltB") — every child of beltB except beltB<lang>
        // loses its visible flag.
        if let g = belt.pane("beltB") {
            let keep = "beltB" + ctx.lang.suffix
            for c in g.children where c.name != keep { c.visible = false }
        }
        if LogicalScreen.isPortrait { placePortrait() }
    }

    // MARK: - iPhone portrait

    /// Portrait arrangement: the top row (Zoom − / Next / Zoom +) right under the safe area with the mode belt under
    /// it; the bottom row (End / tilt / tilt / Restore) and the JP legend in the thumb zone. The globe fills the screen.
    func placePortrait() {
        // No Wii-Remote glyphs on the iPhone: the ⊖ / ⊕ go, so the captions say which way and centre.
        around.pane("zoom_outI")?.suppressed = true
        around.pane("zoom_inI")?.suppressed = true
        do {
            for (n, s) in [("zoom_outT", "Zoom Out"), ("zoom_inT", "Zoom In")] {
                if let t = around.pane(n + ctx.lang.suffix) as? TextBox {
                    if ctx.lang == .us { t.text = Array(s.utf16) }
                    t.translate.x = 0
                }
            }
        }
        // Same rows as the hub (NormalScreen.Portrait): identical top / bottom bar heights across screens.
        let hub = NormalScreen.Portrait.current
        let top = SIMD2<Float>(0, hub.topShift), bottom = SIMD2<Float>(0, hub.bottomShift)
        around.place(["zoom_out": top, "next": top, "zoom_in": top,
                      "back": bottom, "rot_a": bottom, "rot_b": bottom, "reset": bottom])
        var b: [String: SIMD2<Float>] = [:]
        for p in belt.panes { b[p.name] = p.authored.y > 0 ? top : bottom }
        belt.place(b)
        // Edge to edge: the top row's bodies run up through the safe area, the bottom row's down to the screen edge.
        PortraitArrange.extendBodies(around, ["zoom_out", "next", "zoom_in"], toTop: true)
        PortraitArrange.extendBodies(around, ["back", "rot_a", "rot_b", "reset"], toTop: false)
    }

    /// The marker play band (originally 63..393 px on the 456 screen: between the top and bottom button rows).
    static var bandTop: Float { LogicalScreen.isPortrait ? PortraitSlots.pixelTop(63) : 63 }
    static var bandBottom: Float { LogicalScreen.isPortrait ? PortraitSlots.pixelBottom(393) : 393 }

    // Touch gesture accumulators (portrait only).
    var pinchAccum: Float = 1
    var pinchDone = false            // one zoom or tilt step per two-finger gesture
    var tiltAccum: Float = 0
    var twistGesture: (startHeading: Float, accum: Float)?

    /// Pinch = the Zoom buttons' request (one index step per ×1.25 / ×0.8), two-finger vertical pan = the tilt
    /// buttons' request (one step per 50 units, fingers up = tilt toward the horizon), two-finger rotation = the
    /// Wii Remote twist while grabbing (fn_800405E4: past ±30° the heading follows the twist).
    func applyTouchGestures() {
        let g = ctx.gestures
        guard g.fingers >= 2 else {
            pinchAccum = 1; pinchDone = false; tiltAccum = 0; twistGesture = nil
            return
        }
        if twistGesture == nil {
            twistGesture = (globe.camera.twist, 0)
            globe.velLat = 0; globe.velLon = 0; globe.inertiaActive = false
        }
        // One pinch = one zoom step (like one press of a Zoom button); lift the fingers to zoom again.
        pinchAccum *= g.pinch
        if !pinchDone && pinchAccum >= 1.25 {
            pinchDone = true
            if globe.zoomIdx > 0 { globe.reqZoomIn = true; around.find("zoom_in")?.flash() }
        } else if !pinchDone && pinchAccum <= 0.8 {
            pinchDone = true
            if globe.zoomIdx < 9 { globe.reqZoomOut = true; around.find("zoom_out")?.flash(); zoomHint = false }
        }
        // One two-finger gesture = one step: whichever of zoom / tilt crosses its threshold first fires once; lift the
        // fingers to go again.
        tiltAccum += g.panY
        if !pinchDone && tiltAccum <= -50 {
            pinchDone = true
            if globe.tiltIdx < 5 { globe.reqTiltUp = true; around.find("rot_a")?.flash() }
        } else if !pinchDone && tiltAccum >= 50 {
            pinchDone = true
            if globe.tiltIdx > 0 { globe.reqTiltDown = true; around.find("rot_b")?.flash() }
        }
        if var t = twistGesture {
            t.accum += g.rotation
            twistGesture = t
            if abs(t.accum) > 30 {
                globe.camera.orienting = false
                GlobeMath.chaseAngle(&globe.camera.twist, GlobeMath.wrap360(t.accum + t.startHeading), 0.1, 180, 1.0)
            }
        }
    }

    // MARK: - Markers

    /// CAround_ctor: one CCityMarker per place in the forecast data (strings built as in fn_800079A4).
    func buildMarkers() {
        guard let data = ctx.data, let sprites else { markers = []; return }
        markers = data.forecast.places.map { CityMarker(place: $0, data: data, sprites: sprites) }
        if let f = cityFont { for m in markers { m.measureLabel(telop, f) } }
    }

    /// Rebuild markers after new forecast data arrives.
    public func reloadMarkers() { buildMarkers(); updateMarkers(input: false) }

    /// Per-frame UI state that calc() also applies (WeatherScene may draw before the first calc()).
    /// fn_8001B030 (non-JP branch): belt title = mode; the JP legend panes kion/rain/high are never shown.
    func applyModeUI() {
        belt.find("belt")?.textIndex = ctx.globeMode
        if ctx.lang != .jp {
            for n in ["kion", "rain", "high"] { belt.find(n)?.resetPos() }
        }
        applyResetButton()
    }

    /// fn_80017FC8 — called once, from fn_8000E384 (WeatherScene applySettings): globe at the user's city with
    /// zoom index 0, marker strings (fn_80007E88) / selection PTMF (fn_800085B8) / popup size (fn_80008990),
    /// CLayout_Reset of both layouts, then one fn_8001BDCC hint step. +24F stays 0 (ctor) and +A4 is the passive
    /// state until WeatherScene enters the globe.
    public func initOnce() {
        if markers.isEmpty { buildMarkers() }
        let p = ctx.data?.forecast.place(ctx.locationID)
        let latLon = SIMD3<Float>(p?.latitudeDegrees ?? GlobeScene.defaultHome.x, p?.longitudeDegrees ?? GlobeScene.defaultHome.y, 0)
        globe.setZoomIndex(0)
        globe.initialize(latLon: latLon)
        around.reset(); belt.reset()
        updateZoomHint()
        // Port-only: the scene may draw before the first CAround frame runs; give the camera/markers valid state.
        primeForDraw()
    }

    /// fn_8001BECC (+ WeatherScene_StF660 step 0, +250 = 0) — every globe entry: +24F = 1, CLayout_Reset(+6C)
    /// only (the belt keeps its state), CAround state = GlobeScreen_StateNormal. The camera is not touched.
    public func enterGlobe() {
        freezeMarkers = false
        layoutsVisible = true
        around.reset()
        interactive = true
    }

    /// WeatherScene_StF660 leaving the globe: CAround state = fn_80018C9C (passive); a marker click also sets
    /// +250 (CAround_UpdateMarkers returns early — the marker draw lists stay as they were).
    public func leaveGlobe(markerChosen: Bool) {
        interactive = false
        if markerChosen { freezeMarkers = true }
    }

    /// +A4: true = GlobeScreen_StateNormal (interactive), false = fn_80018C9C (passive, runs under the hub).
    public private(set) var interactive = false
    /// +250: freeze the markers (set when a marker opened its city, cleared by StF660 step 0).
    var freezeMarkers = false

    /// fn_8001864C — CAround's calc, run every frame by fn_8000DD84 before WeatherScene's own state.
    public func frame() {
        if interactive { calc() } else { passiveCalc() }
        updateZoomHint()
    }

    /// fn_80018C9C: no hover (+248 = 0), every wrapper pressed (fn_80039DB4), both layouts updated, reset/limit
    /// buttons recomputed, then GlobeScreen_CalcGlobe (camera, poles, markers, light) without input or inertia.
    func passiveCalc() {
        hoveredMarker = nil; pressCandidate = nil; pressPos = nil
        around.panes.forEach { $0.press() }
        around.update(); belt.update()
        applyResetButton()
        applyLimits()
        globe.syncDist()
        globe.calcCamera(materials: &ctx.globeScene.earth.materials)
        globe.calcPoles()
        updateMarkers(input: false)
        globe.updateLight()
    }

    // MARK: - Bars in/out + dim (fn_800181B8, GlobeScreen_StateNormal)

    var barsOffScreen = 0            // +274: frames the pointer has been off screen (or grabbing), ≤ 10
    var barsIdle = 0                 // +278: frames without pointer motion / bar region / button hover, ≤ 90
    var barsDim = 0                  // +27C: 0 hovering a button … 15 not (blink ramp + brightness)
    var pointerHistory: [SIMD2<Float>] = []   // lbl_801F6C74: the last 10 pointer samples (fn_8003A780)

    /// +2B0 (CAround ctor): how far the belt rides up as the top row slides out — to 34 px below the screen top
    /// (19 in widescreen); portrait: just under the safe area.
    var beltSlideDistance: Float {
        guard let b = belt.find("belt") else { return 0 }
        let top = (b.hitRect.y + b.hitRect.w) / 2 + abs(b.hitRect.w - b.hitRect.y) / 2   // belt top, layout y
        if LogicalScreen.isPortrait { return max(0, PortraitSlots.safeTopY - top) }
        return max(0, (LogicalScreen.halfHeight - top) - (ctx.isWide ? 19 : 34))
    }

    /// GlobeScreen_StateNormal: +2AC = +2B0 · slideCount / slideMax, then fn_8003A434(belt, +2AC): every belt
    /// wrapper moves away from the centre (+9C = ±value by the sign of its y).
    func slideBelt() {
        let v = beltSlideDistance * Float(around.slideCount) / Float(max(around.slideMax, 1))
        for p in belt.panes { p.slideOffset = v * (p.pane.translate.y > 0 ? 1 : -1) }
    }

    /// fn_800181B8: the bars slide out (fn_8003A2D0(around, 30)) once the pointer has been off screen / grabbing for
    /// 10 frames or idle for 90 (not moving > 30 px over its last 10 samples, outside the 63..393 band, no button
    /// hovered), and back in (fn_8003A2A4(around, 15)) otherwise. Off a button the wrappers dim: brightness
    /// 0x20 + 223·sin(π/2·(15−27C)/15) and blink ramp 27C/15 toward the pressed colours (white text, inverted
    /// icons) — fn_8003A328. iPhone: with no finger down the pointer rests where it last was (on screen), so the
    /// bars hide after the idle time rather than at once.
    func updateBars(_ pad: KPad) {
        // iPhone (user choice): the globe's bars always stay in, at full brightness — no slide-away, no dimming.
        if LogicalScreen.isPortrait {
            around.slideIn(15); barsDim = 0
            for w in around.panes { w.brightness = 255; w.blinkRamp = 0; w.blinkMax = 0xF }
            return
        }
        let W = ctx.screenWidth
        var offScreenNow = true, active = false
        // Exactly the original: the bars are bright only while a button is pointed at (iPhone: a finger on it);
        // the rest of the time — the pointer is on the globe — they are dimmed see-through with inverted (white)
        // labels and icons.
        let hovering = ctx.ui.hovered != nil
        let valid = LogicalScreen.isPortrait ? true : pad.pointerValid
        if globe.grabbing { offScreenNow = true }   // fn_800181B8: a grabbing remote counts as off (+274 → 10)
        if !globe.grabbing && valid {
            let p = pad.pointer
            // the pointer's samples, one per frame (iPhone: a resting finger keeps its last position)
            pointerHistory.append(p); if pointerHistory.count > 10 { pointerHistory.removeFirst() }
            if let old = pointerHistory.first {
                let inX = { (x: Float) in x >= -16 && x < W + 16 }
                let d = p - old
                if inX(p.x) && inX(old.x) && simd_dot(d, d) > 900 { active = true }
                else if p.y <= AroundScreen.bandTop || p.y > AroundScreen.bandBottom { active = true }
            }
            if p.x >= -16 && p.x < W + 16 { offScreenNow = false }
        }
        if hovering { active = true }
        // iPhone: no finger down counts as no pointer — the bars only slide away while the globe is being moved
        if LogicalScreen.isPortrait && !globe.grabbing { offScreenNow = false; if !pad.pointerValid { active = true } }
        barsOffScreen = offScreenNow ? min(barsOffScreen + 1, 10) : 0
        barsIdle = active ? 0 : min(barsIdle + 1, 0x5A)
        if barsOffScreen < 10 && barsIdle < 0x5A { around.slideIn(15) } else { around.slideOut(30) }
        barsDim = hovering ? max(barsDim - 1, 0) : min(barsDim + 1, 0xF)
        let s = sin(Float.pi / 2 * Float(0xF - barsDim) / 15)
        let brightness = 0x20 + Int(Float(255 - 0x20) * s)
        for w in around.panes { w.brightness = brightness; w.blinkRamp = barsDim; w.blinkMax = 0xF }
    }

    /// GlobeScreen_StateNormal / fn_80018C9C: the reset wrapper (+74) is disabled and pressed while the globe is
    /// already at its reset orientation.
    func applyResetButton() {
        guard let r = around.find("reset") else { return }
        if globe.canReset() { r.disabled = false } else { r.disabled = true; r.press() }
    }

    /// fn_80018568: zoom_out (+90) disabled at zoom index ≥ 9, zoom_in (+8C) at ≤ 0, rot_b (+98) at tilt ≤ 0,
    /// rot_a (+94) at tilt ≥ 5; disabled wrappers are pressed.
    func applyLimits() {
        func set(_ name: String, _ off: Bool) {
            guard let w = around.find(name) else { return }
            if off { w.disabled = true; w.press() } else { w.disabled = false }
        }
        set("zoom_out", globe.zoomIdx >= 9)
        set("zoom_in", globe.zoomIdx <= 0)
        set("rot_b", globe.tiltIdx <= 0)
        set("rot_a", globe.tiltIdx >= 5)
    }

    /// fn_8001812C — used by CAddress to fly to a candidate city.
    public func enterForAddress(_ location: LocationID) {
        if markers.isEmpty { buildMarkers() }
        let p = ctx.data?.forecast.place(location)
        globe.setZoomIndex(0)
        globe.initialize(latLon: SIMD3(p?.latitudeDegrees ?? 0, p?.longitudeDegrees ?? 0, 0))
        resetMarkerState()
        primeForDraw()
    }

    /// The markers' fades persist across globe visits: fn_80017FC8 only rebuilds their strings (fn_80007E88), the
    /// selection PTMF (fn_800085B8) and the popup size (fn_80008990); fn_8001812C only re-inits the globe.
    func resetMarkerState() {
        pressCandidate = nil; pressPos = nil
    }

    /// Make draw() valid before the first calc(): camera, mode UI and marker positions.
    func primeForDraw() {
        globe.syncDist()
        globe.calcCamera(materials: &ctx.globeScene.earth.materials)
        applyModeUI()
        updateMarkers(input: false)
    }

    // MARK: - Frame

    public func calc() {
        let pad = ctx.pad, ui = ctx.ui
        globe.reqZoomOut = false; globe.reqZoomIn = false; globe.reqTiltUp = false; globe.reqTiltDown = false
        applyModeUI()
        around.update(); belt.update()
        slideBelt()
        ui.updateHover(around, pad)
        updateBars(pad)  // fn_800181B8
        ctx.globeScene.stars?.update(velLat: globe.velLat, velLon: globe.velLon)   // GlobeScreen_StateNormal → fn_8002EF14
        applyLimits()    // fn_800181B8 → fn_80018568

        if ui.buttonTrig("back", pad) {
            ctx.playSE(0x26); globe.velLat = 0; globe.velLon = 0; globe.inertiaActive = false
            ctx.request = 3
            return
        }
        // GlobeScreen_StateNormal 0x80018854/0x80018884: the first zoom-out (button or −) ends the hint (+252 = 0).
        if ui.hovered?.name == "zoom_out" && !(ui.hovered?.disabled ?? true) && pad.trig.contains(.a) { zoomHint = false }
        else if pad.trig.contains(.minus) { zoomHint = false }
        if ui.buttonHeld("zoom_out", pad) { globe.reqZoomOut = true } else if pad.trig.contains(.minus) { globe.reqZoomOut = true; around.find("zoom_out")?.flash() }
        if ui.buttonHeld("zoom_in", pad) { globe.reqZoomIn = true } else if pad.trig.contains(.plus) { globe.reqZoomIn = true; around.find("zoom_in")?.flash() }
        if ui.buttonHeld("rot_a", pad) { globe.reqTiltUp = true } else if pad.trig.contains(.up) { globe.reqTiltUp = true; around.find("rot_a")?.flash() }
        if ui.buttonHeld("rot_b", pad) { globe.reqTiltDown = true } else if pad.trig.contains(.down) { globe.reqTiltDown = true; around.find("rot_b")?.flash() }
        // Held buttons repeat only on trigger in the original's request flags.
        if !pad.trig.contains(.a) { if ui.hovered?.name == "zoom_out" || ui.hovered?.name == "zoom_in" { globe.reqZoomOut = false; globe.reqZoomIn = false } }
        if ui.hovered?.name == "zoom_out" && pad.trig.contains(.a) { globe.reqZoomOut = true }
        if ui.hovered?.name == "zoom_in" && pad.trig.contains(.a) { globe.reqZoomIn = true }
        if (ui.hovered?.name == "rot_a" || ui.hovered?.name == "rot_b") && !pad.trig.contains(.a) { globe.reqTiltUp = false; globe.reqTiltDown = false }
        // iPhone: a tap is a one-frame press, too short for the held buttons' pressed look — give Zoom/tilt the same
        // press animation End and Next get from UI_ButtonTrig.
        if LogicalScreen.isPortrait, pad.trig.contains(.a), let h = ui.hovered, !h.disabled,
           ["zoom_out", "zoom_in", "rot_a", "rot_b"].contains(h.name) { h.flash() }
        // fn_8001B030: Next / d-pad RIGHT advance, LEFT go back (SE 0x2C, wraps at 6)
        if ui.buttonTrig("next", pad) || pad.trig.contains(.right) {
            ctx.globeMode = (ctx.globeMode + 1) % 6; ctx.playSE(0x2C)
            if pad.trig.contains(.right) { around.find("next")?.flash() }
            applyModeUI()
        } else if pad.trig.contains(.left) {
            ctx.globeMode = (ctx.globeMode + 5) % 6; ctx.playSE(0x2C)
            applyModeUI()
        }
        if !globe.camera.orienting && ui.buttonTrig("reset", pad) { ctx.playSE(0x13); globe.setTiltIndex(0, level: true) }

        if LogicalScreen.isPortrait { applyTouchGestures() }
        globe.updateInertia(stop: ui.hovered != nil)
        // fn_8001A758: zoom, grab loop, tilt
        globe.updateZoom()
        globe.syncDist()
        let y = pad.pointer.y
        if ui.hovered == nil && pad.pointerValid && y > AroundScreen.bandTop && y < AroundScreen.bandBottom && globe.tryBeginGrab(pad) { ctx.playSE(0x15) }
        if globe.updateGrab(pad) == .released {
            ctx.sound?.updateRotateSound(speed: (globe.velLat * globe.velLat + globe.velLon * globe.velLon).squareRoot())
        }
        globe.updateTilt()
        // fn_80018BE0
        globe.calcCamera(materials: &ctx.globeScene.earth.materials)
        globe.calcPoles()
        updateMarkers(input: true)
        globe.updateLight()
    }

    // MARK: - Hovered-marker weather sound (fn_8001BF20 → fn_800105AC → fn_8003B204)

    /// lbl_803309C8 (SE 0x31) and lbl_803309C0 (SE 0x32): looping handles with a "requested this frame" flag
    /// (+4). fn_8000DD24 (scene vtable +0x20, before the calc) clears the flags; fn_8000DD54 (+0x2C, after it)
    /// stops a playing handle nobody requested.
    let weatherSE = (h31: SoundHandle(), h32: SoundHandle())
    var weatherSERequested = (h31: false, h32: false)
    /// lbl_80179C50: volume by zoom index (SimpleGlobe +9C).
    static let hoverFalloff: [Float] = [1.0, 0.89, 0.78, 0.67, 0.56, 0.45, 0.34, 0.23, 0.12, 0.06]

    public func weatherSoundPreCalc() { weatherSERequested = (false, false) }
    public func weatherSoundPostCalc() {
        guard let snd = ctx.sound else { return }
        if !weatherSERequested.h32, snd.isAttached(weatherSE.h32) { snd.stop(weatherSE.h32, fadeFrames: 0) }
        if !weatherSERequested.h31, snd.isAttached(weatherSE.h31) { snd.stop(weatherSE.h31, fadeFrames: 0) }
    }

    /// fn_8001BF20: only in the weather-icon modes (lbl_803309E8 = mode; non-JP 0/2/4, JP 0/3). The hovered
    /// marker's weather (fn_8000A764, day = +300) → weather table entry (ForecastFindById) → its display code
    /// (+2) → fn_800105AC with volume lbl_80179C50[zoom index] (0.7 without a globe).
    func hoverWeatherSound(_ m: CityMarker) {
        let modeIdx = ctx.globeMode
        let allowed = ctx.lang == .jp ? (modeIdx == 0 || modeIdx == 3) : (modeIdx == 0 || modeIdx == 2 || modeIdx == 4)
        guard allowed, let code = m.weatherCode(day: mode.day),
              let t = ctx.data?.forecast.weatherTypes.first(where: { UInt32($0.code) == UInt32(code) }) else { return }
        let vol = AroundScreen.hoverFalloff[max(0, min(globe.zoomIdx, AroundScreen.hoverFalloff.count - 1))]
        // fn_800105AC (compare tree read from the asm — m2c's "default" case is wrong; the default is silence):
        // SE 0x31 only for the rain codes; 0x5/0x9/0xE/0x12/0x7D play SE 0x31 and SE 0x32.
        let c = Int(t.displayCode & 0x7FFF)
        let both: Set<Int> = [0x5, 0x9, 0xE, 0x12, 0x7D]
        let rainOnly = [0x3, 0x7, 0xC, 0x10, 0x1F, 0x20, 0x67, 0x69, 0x6C].contains(c)
            || (0x13...0x19).contains(c) || (0x6E...0x73).contains(c) || (0x77...0x79).contains(c)
        if rainOnly || both.contains(c) { startWeatherSE(weatherSE.h31, 0x31, vol); weatherSERequested.h31 = true }
        if both.contains(c) { startWeatherSE(weatherSE.h32, 0x32, vol); weatherSERequested.h32 = true }
    }

    /// fn_8003B204(handle, id, volume, pitch 1, pan 0): start if not playing, then set volume/pitch/pan.
    func startWeatherSE(_ h: SoundHandle, _ id: Int, _ vol: Float) {
        guard let snd = ctx.sound else { return }
        if !snd.isAttached(h) { _ = snd.startSound(h, id) }
        snd.setVolume(h, vol); snd.setPitch(h, 1); snd.setPan(h, 0)
    }

    // MARK: - Zoom-out hint (CAround +252 / +2B4 / +309, fn_8001BDCC + the zoom_out wrapper hook fn_8001C250)

    /// +252: set by the ctor, cleared for good by the first zoom-out.
    var zoomHint = true
    var hintBlink: Float = 0          // +2B4
    var hintPhase: UInt8 = 0          // +309
    /// +294 (zoom_outI0 TEV colour 1 alpha) and +190/+194, +198/+19C (zoom_outI0 / zoom_outI1 authored C0/C1),
    /// captured once from the material like the ctor's fn_800370AC / fn_80036E94.
    lazy var hintColors: (i0: (SIMD4<Int32>, SIMD4<Int32>), i1: (SIMD4<Int32>, SIMD4<Int32>), alpha: Int32)? = {
        guard let m0 = (around.layout.root.find("zoom_outI0") as? Picture)?.material,
              let m1 = (around.layout.root.find("zoom_outI1") as? Picture)?.material else { return nil }
        return ((m0.tevColors[0], m0.tevColors[1]), (m1.tevColors[0], m1.tevColors[1]), m0.tevColors[1].w)
    }()
    var hintI0Alpha: Int32 = 0        // +197

    /// fn_8001BDCC: while the hint is on, ping-pong +2B4 by 0.05 and show zoom_outI0 with alpha +294·+2B4.
    func updateZoomHint() {
        guard let i0 = around.layout.root.find("zoom_outI0") else { return }
        if zoomHint {
            if hintPhase != 0 {
                hintBlink -= 0.05
                if hintBlink < 0 { hintBlink = 0; hintPhase &-= 1 }
            } else {
                hintBlink += 0.05
                if hintBlink > 1 { hintBlink = 1; hintPhase &+= 1 }
            }
            hintI0Alpha = Int32(Float(hintColors?.alpha ?? 255) * hintBlink)
            i0.visible = true
        } else {
            hintPhase = 0; hintBlink = 0
            i0.visible = false
        }
    }

    /// fn_8001C250 (zoom_out +34, called by CPaneCtl_PreDraw after the scheme colours): while the hint is on,
    /// zoom_outI0/I1 get their authored colours back (I0's colour-1 alpha = the blink).
    func applyHintColors() {
        guard zoomHint, let c = hintColors,
              let m0 = (around.layout.root.find("zoom_outI0") as? Picture)?.material,
              let m1 = (around.layout.root.find("zoom_outI1") as? Picture)?.material else { return }
        m0.tevColors[0] = c.i0.0; m0.tevColors[1] = c.i0.1; m0.tevColors[1].w = hintI0Alpha
        m1.tevColors[0] = c.i1.0; m1.tevColors[1] = c.i1.1
    }

    // Draw lists rebuilt by updateMarkers (CAround +0x0C[11] content by rank, +0x3C[11] bars/labels by rank,
    // +0x08 / +0x38 pulsing (hovered) content / labels, +0x34 / +0x64 the user's city).
    var contentByRank = [[CityMarker]](repeating: [], count: 11)
    var labelByRank = [[CityMarker]](repeating: [], count: 11)
    var pulseContent: [CityMarker] = [], pulseLabel: [CityMarker] = []
    var homeContent: CityMarker?, homeLabel: CityMarker?

    // Marker click (fn_80019B90): the nearest visible marker within 50 px of the A press; it opens when A is
    // released without having dragged further than 40 px.
    var pressCandidate: CityMarker?, pressPos: SIMD2<Float>?
    /// iPhone: a press stops counting as a city tap once a second finger joins, the finger strays, it is held too
    /// long, or it began on a spinning globe (that touch just stops the spin).
    var pressTainted = false, pressFrames = 0
    public private(set) var hoveredMarker: CityMarker?

    /// City chosen by clicking a marker. The original posts lbl_8032FCF0 = 2 (and lbl_803309BC = place) inside
    /// CAround; the port's WeatherScene uses 2 internally for the back path, so the marker request stays 6.
    public var selectedLocation: LocationID?

    /// CAround_UpdateMarkers (fn_80019B90).
    func updateMarkers(input: Bool) {
        if freezeMarkers { return }   // +250: early return before any CityMarker_Calc
        let scale = markerScale
        let cam = globe.camera
        let pad = ctx.pad
        let minRank = globe.zoomIdx
        for m in markers {
            m.calc(camera: cam, minRank: minRank, homeID: ctx.locationID, scale: scale, screenWidth: ctx.screenWidth)
        }
        // Hover (+0x248: enabled when no button is hovered and the globe is not being dragged): the nearest
        // visible marker within 50 px of the pointer (pointer inside the 63..393 play band) gets flag 4.
        hoveredMarker = nil
        let hoverEnabled = input && ctx.ui.hovered == nil && !globe.grabbing && pad.pointerValid
        if hoverEnabled && pad.pointer.y > AroundScreen.bandTop && pad.pointer.y < AroundScreen.bandBottom {
            var best: Float = 2500
            for m in markers where m.flags & 1 != 0 {
                let d = m.screen - pad.pointer, d2 = simd_dot(d, d)
                if d2 < best { best = d2; hoveredMarker = m }
            }
            hoveredMarker?.flags |= 4
        }
        // Click
        if input {
            if pad.trig.contains(.a) && ctx.ui.hovered == nil {
                pressPos = pad.pointer
                pressTainted = false
                pressFrames = 0
                var best: Float = 2500
                pressCandidate = nil
                for m in markers where m.flags & 1 != 0 {
                    let d = m.screen - pad.pointer, d2 = simd_dot(d, d)
                    if d2 < best { best = d2; pressCandidate = m }
                }
                // iPhone: a finger on a city's name label (right of its icon) picks that city too.
                if LogicalScreen.isPortrait && pressCandidate == nil {
                    let p = pad.pointer
                    for m in markers where m.flags & 1 != 0 && m.labelListed {
                        let r = m.textRect
                        if p.x >= r.x - 10 && p.x <= r.z + 10 && p.y >= r.y - 12 && p.y <= r.w + 12 { pressCandidate = m; break }
                    }
                }
            }
            // iPhone: a finger resting on a marker is its hover (touch-down = the pointer arriving) until it travels
            // past the click radius — pulse, label bar, hover SEs, as the Wii Remote pointer would give.
            if LogicalScreen.isPortrait, pad.hold.contains(.a), !pressTainted, let c = pressCandidate, let p0 = pressPos,
               simd_dot(pad.pointer - p0, pad.pointer - p0) < 1600, c.flags & 1 != 0 {
                hoveredMarker = c; c.flags |= 4
            }
            if LogicalScreen.isPortrait, let p0 = pressPos, pressCandidate != nil {
                pressFrames += 1
                let d = pad.pointer - p0
                // real fingers wobble: 28 logical units (~18 pt) and ¾ s are still a tap; a second finger never is
                if ctx.gestures.fingers >= 2 || (pad.pointerValid && simd_dot(d, d) > 28 * 28) || pressFrames > 45 { pressTainted = true }
            }
            if pad.release.contains(.a), let c = pressCandidate, let p0 = pressPos {
                let d = pad.pointer - p0
                if simd_dot(d, d) < 1600 && c.flags & 1 != 0 && !pressTainted {
                    ctx.playSE(0x25)
                    globe.velLat = 0; globe.velLon = 0; globe.inertiaActive = false
                    selectedLocation = c.place.id
                    ctx.markerPoint = c.screen   // CAround_UpdateMarkers: lbl_803309D0 = marker +1F8/+1FC
                    ctx.request = 6
                }
                pressCandidate = nil; pressPos = nil
            }
        }
        // Label de-clutter (fn_8001ACFC) over the label-listed markers (fn_8000A0E0, previous-frame state).
        let listed = markers.filter { $0.labelListed }
        if listed.count > 1 {
            for i in 0..<(listed.count - 1) {
                for j in (i + 1)..<listed.count where CityMarker.overlapHidesFirst(listed[i], listed[j]) { listed[i].flags |= 2 }
            }
        }
        // Per-marker update (fn_800083F0 / fn_80008518 / fn_80009F24) and the draw lists.
        for r in 0..<11 { contentByRank[r] = []; labelByRank[r] = [] }
        pulseContent = []; pulseLabel = []; homeContent = nil; homeLabel = nil
        let labelScaleBase = min(2.5 * scale, 1.1)
        for m in markers {
            m.updateHover(playSE: { [weak self] in self?.ctx.playSE($0) })
            guard m.flags & 1 != 0 else { continue }
            m.updateLabelFade()
            if m.flags & 4 != 0 { hoverWeatherSound(m) }   // fn_8001BF20
            let p = CityMarker.pulseCurve(m.pulse)
            let box = boxSize(m)
            if p > 0 {
                m.placeLabel(at: m.screen + SIMD2(0.5 * box.x * (0.2 * p + scale), 0), scale: labelScaleBase + 0.1 * p)
                if m.labelListed { pulseLabel.append(m) }
                pulseContent.append(m)
            } else {
                m.placeLabel(at: m.screen + SIMD2(0.5 * box.x * scale, 0), scale: labelScaleBase)
                if m.labelListed {
                    if m.isHome { homeLabel = m } else { labelByRank[min(Int(m.rank), 10)].append(m) }
                }
                if m.isHome { homeContent = m } else { contentByRank[min(Int(m.rank), 10)].append(m) }
            }
        }
    }

    /// fn_8001BFF8 → the mode's box-size PTMF: icons fn_8000A7E0 (90×90); numbers fn_8000A82C (20 + string size).
    func boxSize(_ m: CityMarker) -> SIMD2<Float> {
        guard mode.showsNumber, let sprites else { return SIMD2(90, 90) }
        return sprites.stringSize(m.temperatureString(day: mode.day, unit: ctx.tempUnit)) + SIMD2(20, 20)
    }

    /// iPhone: a touch on the globe's buttons presses on release; anywhere else it grabs the globe.
    public func touchMode(at p: SIMD2<Float>) -> TouchInput.Mode {
        let q = ctx.ui.toLayout(p)
        if around.hitTest(q.x, q.y) != nil || belt.hitTest(q.x, q.y) != nil { return .pressOnRelease }
        return .grab
    }

    public var cursorState: Cursor.State {
        if globe.grabbing { return .hold }
        if ctx.ui.hovered != nil || hoveredMarker != nil { return .normal }
        let y = ctx.pad.pointer.y
        return ctx.pad.pointerValid && y > AroundScreen.bandTop && y < AroundScreen.bandBottom ? .open : .normal
    }

    // MARK: - Draw

    public func drawGlobe(_ enc: MTLRenderCommandEncoder) { ctx.globeScene.draw(enc) }

    /// +24F: the globe's own layouts are drawn. Cleared while the hub is up (StF660 0x8000F6A4 / 0x8000F9F4), set
    /// again on (re)entry (StNormal 0x8000F3A4, fn_8001BECC). The earth and markers are always drawn —
    /// WeatherScene_StE6C8 draws GlobeScreen_Draw under the hub, visible through its half-alpha base off the top level.
    public var layoutsVisible = false

    /// GlobeScreen_Draw (fn_80017548 area)
    public func draw(_ enc: MTLRenderCommandEncoder) {
        drawGlobe(enc)
        // Under the hub (a city opened from a marker) the original shows the bare earth — no markers (Wii capture).
        guard layoutsVisible else { return }
        drawMarkers(enc)
        belt.draw(ctx.lyt, enc)
        // CLayout_Draw(+6C) with the zoom_out wrapper's post-colour hook (fn_8001C250).
        if around.visible {
            _ = hintColors
            around.panes.forEach { $0.preDraw() }
            applyHintColors()
            ctx.lyt.draw(around.layout, enc, screenWidth: 608, locationAdjust: around.locationAdjust)
        }
    }

    /// The mode draw PTMF (fn_80019268 / fn_800198A4 / fn_80019734): bars by rank → content by rank → pulsing
    /// bars → labels by rank → pulsing content (scale + 0.2·pulse) → pulsing labels. The user's city goes
    /// after the ranked ones.
    func drawMarkers(_ enc: MTLRenderCommandEncoder) {
        guard sprites != nil else { return }
        let scale = markerScale
        var bars = labelByRank.flatMap { $0 }, contents = contentByRank.flatMap { $0 }
        if let h = homeLabel { bars.append(h) }
        if let h = homeContent { contents.append(h) }
        for m in bars { drawBars(m, enc) }
        for m in contents { drawContent(m, scale: scale, enc) }
        for m in pulseLabel { drawBars(m, enc) }
        for m in bars { drawLabel(m, enc) }
        for m in pulseContent { drawContent(m, scale: scale + 0.2 * CityMarker.pulseCurve(m.pulse), enc) }
        for m in pulseLabel { drawLabel(m, enc) }
    }

    /// fn_80008AF4: the two gradient bars behind the label (only while hovered: alpha 255·chase).
    func drawBars(_ m: CityMarker, _ enc: MTLRenderCommandEncoder) {
        guard let sprites, m.barAlpha > 0 else { return }
        let a = m.barAlpha, clear = SIMD4<UInt8>(255, 255, 255, 0), cyan = SIMD4<UInt8>(0x80, 0xFF, 0xFF, a)
        sprites.drawGradientRect(m.barLeft, [clear, clear, cyan, cyan], enc)
        sprites.drawGradientRect(m.barRight, [cyan, cyan, clear, clear], enc)
    }

    /// fn_80008B3C: city name in the city font, white, alpha = labelHide(+26C) · alpha(+27F), drawn with draw
    /// flag 0x100 (left origin, vertically centred) at scale +24C.
    func drawLabel(_ m: CityMarker, _ enc: MTLRenderCommandEncoder) {
        guard let f = cityFont else { return }
        let a = UInt8(max(0, min(255, m.labelHide * Float(m.alpha27F))))
        guard a > 0 else { return }
        telop.draw(m.place.city, font: f, at: m.labelPos, style: .init(scale: SIMD2(repeating: m.labelScale), flags: 0x100),
                   color: SIMD4(255, 255, 255, a), enc)
    }

    /// Content: weather icon (fn_80020574 via fn_800203F0) or temperature (fn_800095A8 current / fn_80009478 high):
    /// a backing pass in the temperature colour (fn_800099CC) then the digits in lbl_80330A38 = #202020.
    func drawContent(_ m: CityMarker, scale: Float, _ enc: MTLRenderCommandEncoder) {
        guard let sprites, let data = ctx.data else { return }
        let a = m.alpha27D
        guard a > 0 else { return }
        if mode.showsNumber {
            let s = m.temperatureString(day: mode.day, unit: ctx.tempUnit)
            // fn_800095A8 → fn_8003F088(str, pos, main = temperature colour, shadow = lbl_80330A38 #202020):
            // the #202020 shadow at (+2,+2) first, then the digits in the temperature colour.
            var main = CityMarker.temperatureColor(m.celsius(day: mode.day)); main.w = a
            sprites.drawCenteredTwoPass(s, center: m.screen, scale: scale, back: SIMD4(0x20, 0x20, 0x20, a), front: main, enc)
        } else if let code = m.weatherCode(day: mode.day),
                  let t = data.forecast.weatherTypes.first(where: { $0.code == code }) {
            sprites.drawWeatherIcon(code: t.displayCode, center: m.screen, alpha: a, scale: scale, enc)
        }
    }
}

/// CCityMarker (ctor fn_80006FC0, Calc fn_80007630, label/box fn_800085D8..fn_8000A0E0).
public final class CityMarker {
    public let place: Place
    public let position: SIMD3<Float>                    // +1C8: 3·(sinλcosφ, sinφ, cosλcosφ)
    public private(set) var screen = SIMD2<Float>(0, 0)  // +1F8
    public private(set) var rank: UInt8 = 0              // +280: place rank, 9 for the user's city
    public private(set) var isHome = false
    var flags = 0                            // +230: 1 visible, 2 label hidden (de-clutter), 4 hovered
    // Initial values as stored by CityMarker_ctor (0x8000714C..): +258/+25C = 0, +260/+264/+268/+26C = 1.
    var fade: Float = 0                      // +258 rank fade ±0.05
    var bandFade: Float = 0                  // +25C play-band fade ±0.1, floor 0.3 (fn_8000A690)
    var alpha27D: UInt8 = 0                  // +27D content alpha
    var depthLabel: Float = 1                // +264 label depth fade ±0.05
    var edgeFade: Float = 1                  // +268 play-area fade ±0.2
    var selectFade: Float = 1                // +260 selection fade (the selection PTMF never runs: +238 bit 0 is never set)
    var labelHide: Float = 1                 // +26C de-clutter fade ±0.1
    var alpha27F: UInt8 = 0                  // +27F label alpha
    var pulse = 0                            // +23C angle 0..0x8000
    var hoverChase: Float = 0                // +274
    var labelPos = SIMD2<Float>(0, 0)        // +208/+20C
    var labelScale: Float = 1                // +24C
    var textRect = SIMD4<Float>(0, 0, 0, 0)  // +15C..+168
    var barLeft = SIMD4<Float>(0, 0, 0, 0), barRight = SIMD4<Float>(0, 0, 0, 0)  // +16C / +17C
    var barAlpha: UInt8 { UInt8(max(0, min(255, 255 * hoverChase))) }
    var labelSize = SIMD2<Float>(0, 0)       // unscaled label width/height

    // fn_800079A4 strings: [day 0, day 1] × [°C, °F] highs; the current temperature (+0xE4/+0xEE).
    let highText: [[[UInt16]]]
    let highC: [Int8?]
    let currentText: [[UInt16]]
    let currentC: Int8?
    let dayWeather: [UInt16?]
    let currentWeather: UInt16?

    init(place: Place, data: WeatherData, sprites: SpriteText) {
        self.place = place
        let lat = place.latitudeDegrees * .pi / 180, lon = place.longitudeDegrees * .pi / 180
        position = 3 * SIMD3(sin(lon) * cos(lat), sin(lat), cos(lon) * cos(lat))
        let dash: [UInt16] = [0x2D, 0x2D]                      // lbl_8032F558
        let days: [DayForecast]? = data.forecast.longForecasts.first(where: { $0.location == place.id }).map { [$0.today, $0.tomorrow] }
            ?? data.forecast.summaries.first(where: { $0.location == place.id }).map { [$0.today, $0.tomorrow] }
        func fmt(_ v: Int8) -> [UInt16] { v > -128 ? sprites.formatInt(Int(v)) : dash }
        highText = (0..<2).map { i in days.map { [fmt($0[i].highC), fmt($0[i].highF)] } ?? [dash, dash] }
        highC = (0..<2).map { i in days.flatMap { $0[i].highC > -128 ? $0[i].highC : nil } }
        dayWeather = (0..<2).map { i in days.map { $0[i].weather } }
        let cur = data.short.current.first(where: { $0.location == place.id })
        currentText = cur.map { [fmt($0.tempC), fmt($0.tempF)] } ?? [dash, dash]
        currentC = cur.flatMap { $0.tempC > -128 ? $0.tempC : nil }
        currentWeather = cur.flatMap { $0.weather == 0xFFFF ? nil : $0.weather }
    }

    func temperatureString(day: Int, unit: Int) -> [UInt16] { day == 2 ? currentText[min(unit, 1)] : highText[day][min(unit, 1)] }
    func celsius(day: Int) -> Int { Int((day == 2 ? currentC : highC[day]) ?? -128) }
    func weatherCode(day: Int) -> UInt16? { day == 2 ? currentWeather : dayWeather[day] }   // fn_8000A764

    func measureLabel(_ t: TelopText, _ f: ResFont) {
        labelSize = SIMD2(t.width(place.city, font: f), t.height(place.city, font: f))
    }

    /// fn_80035FF8: 0.5 − 0.5·cos(angle) for a u16 angle (0x8000 = half turn) → 0..1.
    static func pulseCurve(_ v: Int) -> Float { 0.5 - 0.5 * cos(Float(v) / 65536 * 2 * .pi) }

    /// CityMarker_Calc (fn_80007630) + fn_80008194.
    func calc(camera: GlobeCamera, minRank: Int, homeID: LocationID, scale: Float, screenWidth: Float) {
        let look = camera.target - camera.eye
        let lookLen = simd_length(look)
        screen = camera.project(position)
        isHome = place.id == homeID
        rank = isHome ? 9 : place.zoom1
        let facing = simd_dot(simd_normalize(position), simd_normalize(look))
        let target: Float = Int(rank) >= minRank ? 1 : 0
        if fade < target { fade = min(fade + 0.05, target) } else if fade > target { fade = max(fade - 0.05, target) }
        flags = 0
        let onScreen = screen.x >= -50 && screen.x <= screenWidth + 50 && screen.y >= -50 && screen.y <= LogicalScreen.height + 50
        if onScreen && facing < 0 {
            let t = simd_length(camera.eye - position) - lookLen
            let k = min(facing * -3, 1)
            let depth: Float = t >= 3 ? 0 : (t > 0 ? 255 * cos(.pi / 2 * t / 3) : 255)
            alpha27D = UInt8(max(0, min(255, k * depth * fade)))
            if t >= 1 { depthLabel = max(depthLabel - 0.05, 0) } else { depthLabel = min(depthLabel + 0.05, 1) }
            if alpha27D != 0 { flags |= 1 }
        } else {
            alpha27D = 0; depthLabel = 0
        }
        // fn_80008194: fade out near the play-area edges (x margin 28 / 36 wide; y band 63..393 ± 40·scale)
        let margin: Float = screenWidth > 700 ? 36 : 28
        let half = 0.5 * 80 * scale
        let bandTop = AroundScreen.bandTop, bandBottom = AroundScreen.bandBottom
        if screen.x < margin || screen.y - half < bandTop || screen.x > screenWidth - margin || screen.y + half > bandBottom {
            edgeFade = max(edgeFade - 0.2, 0)
        } else {
            edgeFade = min(edgeFade + 0.2, 1)
        }
        // fn_8000A690 (CAround_UpdateMarkers, right after the Calc): outside the 63..393 band (±40·scale) the
        // content fades to 30 % (from a non-zero value only); inside it returns to 100 %. Scales +27D.
        if screen.y - half < bandTop || screen.y + half > bandBottom {
            if bandFade > 0 { bandFade = max(bandFade - 0.1, 0.3) }
        } else if bandFade < 1 {
            bandFade = min(bandFade + 0.1, 1)
        }
        alpha27D = UInt8(Float(alpha27D) * bandFade)
    }

    /// fn_8000A0E0: the label takes part in bars / labels / de-clutter.
    var labelListed: Bool { flags & 1 != 0 && flags & 2 == 0 && alpha27F != 0 && abs(labelScale) >= 0.0008 }

    /// fn_800083F0: selection fade and the hover pulse (+0x1800/frame up to 0x8000, SE 1 when it arrives).
    func updateHover(playSE: (Int) -> Void) {
        selectFade = min(selectFade + 0.1, 1)            // fn_800083F0: (+230&1 && +238&1) never holds → +260 rises
        if flags & 1 != 0 && flags & 4 != 0 {
            if pulse < 0x8000 { pulse += 0x1800; if pulse >= 0x8000 { pulse = 0x8000; playSE(1) } }
        } else if pulse > 0 {
            pulse = max(pulse - 0x1800, 0)
        }
    }

    /// fn_80008518: de-clutter fade and the label alpha (+27F = +268·+264·+27D·+260).
    func updateLabelFade() {
        if flags & 2 != 0 { labelHide = max(labelHide - 0.1, 0) } else { labelHide = min(labelHide + 0.1, 1) }
        alpha27F = UInt8(max(0, min(255, edgeFade * (depthLabel * (Float(alpha27D) * selectFade)))))
    }

    /// fn_80009F24 + fn_80009FCC: label origin/scale, its text rect, the hover bars and the hover chase.
    func placeLabel(at p: SIMD2<Float>, scale: Float) {
        labelPos = p; labelScale = scale
        let w = labelSize.x * scale, h = labelSize.y * scale
        var x0 = p.x - 4, x1 = p.x + w + 4
        let y0 = p.y - 0.5 * h - 4, y1 = p.y + 0.5 * h + 4
        barLeft = SIMD4(x0 - 100, y0, x0, y1)
        barRight = SIMD4(x0, y0, x1 + 50, y1)
        if flags & 4 != 0 { x0 -= 100; x1 += 50 }
        textRect = SIMD4(x0, y0, x1, y1)
        GlobeMath.chaseValue(&hoverChase, flags & 4 != 0 ? 1 : 0, 0.2, 1.0, 0.05)
    }

    /// fn_8001ACFC: two overlapping label rects — returns true to hide `a` (the earlier one), or hides `b`.
    /// Priority: hovered > the user's city > higher rank > later in the list.
    static func overlapHidesFirst(_ a: CityMarker, _ b: CityMarker) -> Bool {
        if a.flags & 2 != 0 { return false }
        let ra = a.textRect, rb = b.textRect
        let wa = ra.z - ra.x, ha = ra.w - ra.y, wb = rb.z - rb.x, hb = rb.w - rb.y
        let dx = abs((ra.x + 0.5 * wa) - (rb.x + 0.5 * wb)), dy = abs((ra.y + 0.5 * ha) - (rb.y + 0.5 * hb))
        if dx > 0.5 * (wa + wb) || dy > 0.5 * (ha + hb) { return false }
        if a.flags & 4 != 0 { b.flags |= 2; return false }
        if b.flags & 4 != 0 { return true }
        if a.isHome { b.flags |= 2; return false }
        if b.isHome { return true }
        if a.rank < b.rank { return true }
        b.flags |= 2
        return false
    }

    /// fn_800099CC: temperature (°C) → colour, piecewise lerp through the static palette (fn_80009E5C:
    /// out = b − (b − a)·(d/span)).
    static let palette: [SIMD4<UInt8>] = [
        SIMD4(0xFF, 0xFF, 0xFF, 0xFF), SIMD4(0xBB, 0xFF, 0xFF, 0xFF), SIMD4(0x00, 0xFF, 0xFF, 0xFF), SIMD4(0x21, 0xA5, 0xE3, 0xFF),
        SIMD4(0x00, 0x66, 0xCD, 0xFF), SIMD4(0x8C, 0xFF, 0x00, 0xFF), SIMD4(0xFF, 0xFF, 0x00, 0xFF), SIMD4(0xFF, 0xB6, 0x00, 0xFF),
        SIMD4(0xFF, 0x8C, 0x00, 0xFF), SIMD4(0xFF, 0x62, 0x20, 0xFF), SIMD4(0xBD, 0x00, 0x00, 0xFF)]
    static func temperatureColor(_ t: Int) -> SIMD4<UInt8> {
        let segs: [(Int, Float)] = [(-12, 6), (-7, 5), (-1, 6), (4, 5), (10, 6), (16, 6), (21, 5), (27, 6), (32, 5)]
        if t <= -18 { return palette[0] }
        for (i, s) in segs.enumerated() where t <= s.0 {
            let a = palette[i], b = palette[i + 1], k = Float(s.0 - t) / s.1
            func ch(_ c: Int) -> UInt8 { UInt8(max(0, min(255, Float(b[c]) - (Float(b[c]) - Float(a[c])) * k))) }
            return SIMD4(ch(0), ch(1), ch(2), 255)
        }
        return palette[10]
    }
}
