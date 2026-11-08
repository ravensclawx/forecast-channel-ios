import Foundation
import Metal
import NW4R
import RVL
import simd

/// CWeatherScene ('WTH2', d_s_weather.cpp, 0x16C): the channel's top-level state machine plus the parts of
/// System_Frame the port needs (transition overlay, frame capture). See decomp/notes/scenes.md §1, §3 and
/// decomp/notes/scene_port.md for the state/PTMF mapping.
public final class WeatherScene {
    public let ctx: SceneContext
    let service: ForecastService
    let connect: Connect                      // +158
    let message: Message                      // +15C
    var address: AddressScreen?               // +B0
    var normal: NormalScreen?                 // +B4
    public internal(set) var around: AroundScreen?   // +B8
    var setting: SettingScreen?               // +BC
    let d2: SceneDraw2D
    var overlaySprites: SpriteText?
    /// lbl_803309F8 — credit variant for WeatherScene_StE6C8: bit 0 = second line (TPLCommon 3, or 6 with bit 1),
    /// bit 1 = globe variant (TPLWeather 0x19 instead of 0x18). Top-level hub 0, hub from a marker 1, globe 3.
    var creditFlags = 0
    /// +13C: fn_8001812C runs on the first hub → globe entry only.
    var globeInitDone = false
    /// lbl_801D6F7C.y (ctor: 365)
    var creditY: Float = 365
    var weatherTPL: TPLFile?                  // +AC TPLWeather.tpl.LZ

    /// Scene states (the PTMFs at lbl_80199AA8 + off).
    public enum State: String { case boot, address, normal, globe, setting, connectError }
    public private(set) var state: State = .boot
    var step = 0                              // +138
    var t144 = 0, t148 = 0                    // +144 / +148 timers
    var dimAlpha = 0                          // +140
    var save = SaveData()                     // +160
    var pendingOpenZoom = false
    var loadResult = SaveData.LoadResult.noFile   // +164
    var storeResult = 0                       // +168
    var settingsChangeCity = false            // +154
    var quitting = false

    /// Set when the channel would return to the Wii Menu (OSReturnToMenu); the app polls this.
    public var wantsQuit = false
    /// iPhone: "Wii Menu" finished its press/fade sequence — the shell sends the app to the Home Screen
    /// (instead of quitting) and calls `resumeFromSuspend()` when it comes back.
    public private(set) var wantsSuspend = false
    /// Cursor choice per channel (CErrorSystem): grab/open hand on the globe, otherwise the pointing hand.
    /// iPhone: how a touch starting at `p` maps to the A button (see TouchInput).
    public func touchMode(at p: SIMD2<Float>) -> TouchInput.Mode {
        if state == .globe, let around { return around.touchMode(at: p) }
        return .pressOnRelease
    }

    public var cursorState: Cursor.State {
        switch state {
        case .globe: return around?.cursorState ?? .normal
        case .address: return address?.cursorState ?? .normal
        default: return .normal
        }
    }

    // BGM layers (lbl_801F76D4[4]) and their fades (+F4 + 12·i: cur, target, step)
    var bgmCur = [Float](repeating: 0, count: 4), bgmTarget = [Float](repeating: 0, count: 4), bgmStep = [Float](repeating: 0, count: 4)
    var bgmMode = 0                           // +134
    var fadeIn: [[Float]] = [[1 / 135, 1 / 240, 1 / 240, 1 / 240], [1 / 120, 1 / 240, 1 / 240, 1 / 240]]   // day / night
    var fadeOut: [[Float]] = [[1 / 240, 1 / 135, 1 / 135, 1 / 135], [1 / 240, 1 / 120, 1 / 120, 1 / 120]]

    // System_Frame transition overlay (lbl_80330B48 mode, B4C counter, B50 length) and the frame-capture buffer.
    public private(set) var transitionMode = 0
    var transitionCount = 0, transitionLength = 1
    var sceneColor: MTLTexture?, sceneDepth: MTLTexture?, capture: MTLTexture?
    /// The last rendered scene frame (the HOME Menu draws it behind its dimmer).
    public var frameTexture: MTLTexture? { sceneColor }
    var pendingCapture = false

    public init(ctx: SceneContext) throws {
        self.ctx = ctx
        service = ForecastService()
        connect = try Connect(ctx: ctx, service: service)
        message = try Message(ctx: ctx)
        d2 = SceneDraw2D(gx: ctx.gx, lyt: ctx.lyt, width: ctx.screenWidth)
        if let lz = try? ctx.assets.archive(.weather).find("TPLWeather.tpl.LZ") { weatherTPL = try? TPLFile(CX.uncompressIfNeeded(lz)) }
        // Fade-step tables (rodata 0x80179400 day in/out, 0x80179420 night in/out).
        if let dol = try? ctx.assets.title.content(index: Assets.Content.mainDol.rawValue) {
            let img = DOLImage(dol)
            func row(_ a: UInt32) -> [Float] { (0..<4).map { img.f32(a + UInt32($0 * 4)) } }
            let di = row(0x8017_9400), dout = row(0x8017_9410), ni = row(0x8017_9420), nout = row(0x8017_9430)
            if di.allSatisfy({ $0 > 0 && $0 < 1 }) { fadeIn = [di, ni]; fadeOut = [dout, nout] }
        }
        ctx.startPage = 1
        ctx.pageCount = ctx.lang == .jp ? 4 : 5
    }

    var dayIdx: Int { ctx.isDaytime ? 0 : 1 }

    // MARK: - Calc (WeatherScene_Calc → current state PTMF; fn_8000DD84 common per-frame work)

    public func calc() {
        // Everything uploaded ahead of first use, a few items per frame from boot (no art popping in later).
        if overlaySprites == nil { overlaySprites = try? SpriteText(ctx: ctx) }
        ctx.queuePrewarm(sprites: overlaySprites)
        ctx.stepPrewarm()
        ctx.fade.update(); ctx.fade2.update()
        if ctx.returnToWiiMenu && !quitting {
            quitting = true; ctx.fade.startFadeOut(0x19)
        }
        if quitting {
            if ctx.fade.isIdle { if ctx.isPortrait { wantsSuspend = true } else { wantsQuit = true } }
            updateBGM(); return
        }
        around?.weatherSoundPreCalc()   // vtable +0x20 fn_8000DD24
        // fn_8000DD84: CAround's calc (fn_8001864C) runs every frame before the state PTMF. CAddress drives the
        // globe itself while it owns it (port: AddressScreen.animateGlobe), so it is skipped there.
        if state != .address { around?.frame() }
        normal?.stepZoom()   // fn_8000DD84 → fn_800225FC: the hub's zoom sub-state runs whatever the scene state
        switch state {
        case .boot: stBoot()
        case .address: stAddress()
        case .normal: stNormal()
        case .globe: stGlobe()
        case .setting: stSetting()
        case .connectError: stConnect()
        }
        // fn_8000DD84: the credit's y chases 0x166 with the second line, else 0x16D (ChaseValue 0.1, 5, 1).
        GlobeMath.chaseValue(&creditY, creditFlags & 1 != 0 ? 0x166 : 0x16D, 0.1, 5, 1)
        updateBGM()
        around?.weatherSoundPostCalc()  // vtable +0x2C fn_8000DD54
        if transitionMode != 0 { transitionCount += 1; if transitionCount >= transitionLength { transitionMode = 0 } }
    }

    func go(_ s: State) { state = s; step = 0 }

    /// WeatherScene_StBoot (fn_8000FEB4)
    func stBoot() {
        switch step {
        case 0:
            ctx.request = 0; step = 1; fallthrough
        case 1:
            connect.start(); step = 2
        case 2:
            connect.update()
            if connect.isDone { step = 3 }
        case 3:
            let (r, s) = SaveData.load()
            loadResult = r; save = s
            switch r {
            case .ok:
                if s.country == UInt32(ctx.countryCode) << 24, ctx.data?.forecast.place(LocationID(raw: s.location)) != nil { step = 9 }
                else { message.open(3); step = 4 }
            // iPhone: no "Is this date and time correct?" — the phone's clock is always set.
            case .noFile: if ctx.isPortrait { step = 9 } else { message.open(1); step = 4 }
            case .broken: message.open(2); step = 4; ctx.playSE(0x19)
            case .nandError: message.open(4); step = 4; ctx.playSE(0x19)
            }
        case 4:
            message.update()
            if message.isClosed { step = 9; if loadResult == .ok { loadResult = .noFile } }
        default:
            applySettings()
        }
    }

    /// fn_8000E078: apply save (or defaults from the forecast header), create the screens, enter hub or address.
    func applySettings() {
        if loadResult == .ok {
            ctx.locationID = LocationID(raw: save.location)
            ctx.tempUnit = Int(save.tempUnit); ctx.windUnit = Int(save.windUnit)
        } else {
            ctx.locationID = LocationID(raw: UInt32(ctx.countryCode) << 24)
            if ctx.data?.forecast.header.regionFlag == 1 { ctx.tempUnit = 1; ctx.windUnit = 0 }
            else { ctx.tempUnit = 0; ctx.windUnit = 1 }
        }
        do {
            let ar = try AroundScreen(ctx: ctx)
            ar.initOnce()   // fn_8000E384 → fn_80017FC8 (the only call)
            around = ar
            address = try AddressScreen(ctx: ctx, around: ar)
            normal = try NormalScreen(ctx: ctx)
            setting = try SettingScreen(ctx: ctx)
        } catch {
            message.open(5); go(.connectError); return
        }
        address?.drawer = d2; address?.scissor = { [weak self] x, y, w, h in self?.scissor(x, y, w, h) ?? MTLScissorRect(x: 0, y: 0, width: 1, height: 1) }
        normal?.scissor = { [weak self] x, y, w, h in self?.scissor(x, y, w, h) ?? MTLScissorRect(x: 0, y: 0, width: 1, height: 1) }
        setting?.drawer = d2
        ctx.ui.clearHover()
        if loadResult == .ok {
            ctx.request = 2
            go(.normal)
        } else {
            ctx.request = 1
            address?.firstRun = true
            go(.address)
        }
        ctx.fade.startFadeIn(0x19)
    }

    /// WeatherScene_StAddress (fn_8000E934)
    func stAddress() {
        guard let address else { return }
        switch step {
        case 0:
            ctx.request = 1
            bgmEnterOption()
            address.start()
            step = 1
        case 1:
            address.calc()
            if ctx.fade.isIdle { step = 2 }
        case 2:
            address.calc()
            if ctx.request == 2 { step = 3; ctx.fade.startFadeOut(0x19) }
            else if ctx.request == 4 { step = 4; ctx.fade.startFadeOut(0x19) }
        case 3:
            address.calc()
            if ctx.fade.isIdle {
                applyPendingData()   // fully black
                storeResult = storeSave()
                if storeResult == 0 {
                    address.firstRun = false
                    ctx.fade.startFadeIn(0x19); ctx.ui.clearHover()
                    ctx.isTopLevel = true
                    go(.normal)
                } else { ctx.ui.clearHover(); go(.connectError) }
            }
        default:
            if ctx.fade.isIdle {
                setting?.reset()
                ctx.fade.startFadeIn(0x19); ctx.ui.clearHover()
                go(.setting); step = 1   // StFAE4 entered with the fade already running
            }
        }
    }

    // MARK: - iPhone: native Settings

    /// The settings currently in effect (location ID raw, temp unit 0 °C / 1 °F, wind unit 0 mph / 1 km/h);
    /// nil location before the first-run location has been chosen.
    public var currentSettings: (location: UInt32?, temp: Int, wind: Int) {
        let loc = ctx.locationID.raw & 0xFFFF != 0 ? ctx.locationID.raw : nil
        return (loc, ctx.tempUnit, ctx.windUnit)
    }

    /// Apply settings changed in the iOS Settings app (the CSetting screen's job on the Wii): store the save like
    /// StFAE4 step 3 and re-enter the hub so it shows the new city/units. Ignored until the channel has booted.
    public func applyExternalSettings(location: UInt32?, temp: Int, wind: Int) {
        guard state == .normal || state == .globe, ctx.data != nil else { return }
        var changed = false
        if temp != ctx.tempUnit { ctx.tempUnit = temp; changed = true }
        if wind != ctx.windUnit { ctx.windUnit = wind; changed = true }
        var moved = false
        if let l = location, l != ctx.locationID.raw, ctx.data?.forecast.place(LocationID(raw: l)) != nil {
            ctx.locationID = LocationID(raw: l); moved = true; changed = true
        }
        guard changed else { return }
        storeResult = storeSave()
        if moved { around?.reloadMarkers() }
        if state == .normal && step >= 1 && step < 4, let normal {
            ctx.isTopLevel = true; ctx.displayLocation = nil
            normal.enter(fromGlobe: false)
        }
    }

    func storeSave() -> Int {
        save.location = ctx.locationID.raw
        save.country = UInt32(ctx.countryCode) << 24   // stored as country<<24 (lbl_803309FC), verified in Dolphin
        save.tempUnit = UInt32(ctx.tempUnit); save.windUnit = UInt32(ctx.windUnit)
        return save.store()
    }

    /// WeatherScene_StNormal (fn_8000EF08)
    /// A background refresh is applied only while the screen is fully black (hub↔globe, settings/address fades), so
    /// values and markers never change in view.
    func applyPendingData() {
        guard let fresh = ctx.pendingData.take() else { return }
        ctx.data = fresh; around?.reloadMarkers()
    }

    func stNormal() {
        guard let normal else { return }
        switch step {
        case 0:
            step = 1
            ctx.request = 0   // the request that led here (address confirm / settings back) is consumed
            bgmEnterSelf()
            creditFlags = ctx.isTopLevel ? 0 : 1   // StNormal step 0: lbl_803309F8 = (lbl_8032FD00 == 0)
            normal.enter(fromGlobe: false)
            // StF660 request 2 put CNormal into fn_80027270: the hub zooms out of the tapped marker.
            if pendingOpenZoom { pendingOpenZoom = false; normal.startOpenZoom(from: ctx.markerPoint) }
            fallthrough
        case 1:
            normal.calc()
            switch ctx.request {
            case 5:   // open globe: dim, then reset the globe to the user's city
                step = 4; ctx.request = 0   // consumed (AroundScreen posts 3 for "back")
                ctx.fade2.maxAlpha = 255   // StNormal: m_pFade2 colour = (0,0,0,0xFF) → a full fade to black
                ctx.fade2.startFadeOut(0x14)
                t148 = 0xC; t144 = 0x28
                bgmEnterGlobe()
            case 4:   // settings
                step = 3; ctx.fade.startFadeOut(0x19)
            case 3 where !ctx.isTopLevel:   // back to the globe (hub was opened from a marker)
                t144 = 0xC; step = 2; ctx.request = 0   // consumed, or CAround reads it as its own back request
                normal.buttonsVisible = false           // 0x8000F39C: +7F9 = 0
                around?.layoutsVisible = true          // 0x8000F3A4
                bgmEnterGlobe()
            default: break
            }
        case 2:
            if t144 > 0 { t144 -= 1 } else { ctx.ui.clearHover(); go(.globe); step = 1; creditFlags = 3; around?.enterGlobe() }   // StF660 step 0
        case 3:
            if ctx.fade.isIdle { ctx.ui.clearHover(); go(.setting) }
        case 4:
            dimAlpha = min(dimAlpha + t148, 255)
            if ctx.fade2.isIdle {
                if t144 > 0 { t144 -= 1 } else {
                    step = 5
                    applyPendingData()   // fully black
                    resetGlobeToHome()
                    ctx.fade2.startFadeIn(0x28)
                    around?.layoutsVisible = true   // +24F = 1
                    if !globeInitDone { globeInitDone = true; around?.enterForAddress(ctx.displayLocation ?? ctx.locationID) }   // +13C → fn_8001812C
                    creditFlags = 3   // StNormal 0x8000F3C4
                }
            }
        default:
            dimAlpha = max(dimAlpha - t148, 0)   // the passive CAround frame keeps the globe/markers current
            if ctx.fade2.isIdle { dimAlpha = 0; ctx.ui.clearHover(); go(.globe); step = 1; creditFlags = 3; around?.enterGlobe() }
        }
    }

    func resetGlobeToHome() {
        guard let p = ctx.data?.forecast.place(ctx.locationID) else { return }
        let g = ctx.globeScene.globe
        g.reset(latLon: SIMD3(p.latitudeDegrees, p.longitudeDegrees, 0), zoomIdx: 0)
        g.setTiltIndex(0, level: false)
        g.setTiltIndexImmediate(0)
        g.camera.twist = 0
    }

    /// WeatherScene_StF660 — the globe (CAround).
    func stGlobe() {
        guard let around else { return }
        switch step {
        case 0, 1:
            // (CAround's frame already ran this frame, from calc().)
            if ctx.request == 3 {
                around.leaveGlobe(markerChosen: false)   // +A4 = fn_80018C9C
                // back to the hub
                step = 2; ctx.request = 2
                ctx.fade2.maxAlpha = 255   // StF660: m_pFade2 colour = (0,0,0,0xFF)
                ctx.fade2.startFadeOut(0xC)
                ctx.isTopLevel = true
                ctx.displayLocation = nil
                bgmEnterSelf()
                t144 = 0x1E
                ctx.startPage = startPageForGlobeMode()
            } else if ctx.request == 6 {
                // a marker was chosen (AroundScreen.selectedLocation): show that city's pages (hub not top level)
                ctx.request = 0
                ctx.startPage = startPageForGlobeMode()
                ctx.isTopLevel = false
                ctx.displayLocation = around.selectedLocation
                around.layoutsVisible = false   // 0x8000F6A4
                around.leaveGlobe(markerChosen: true)   // +250 = 1, +A4 = fn_80018C9C
                ctx.ui.clearHover()
                pendingOpenZoom = true                  // fn_80025C40(CNormal, fn_80027270)
                go(.normal)
            }
        case 2:
            if ctx.fade2.isIdle {
                if t144 > 0 { t144 -= 1 } else {
                    step = 3
                    around.layoutsVisible = false   // 0x8000F9F4
                    creditFlags = 0                 // 0x8000F960
                    creditY = 365                   // 0x8000F948: lbl_801D6F7C.y = 365
                    ctx.fade2.startFadeIn(0x19)
                    ctx.isTopLevel = true
                    ctx.startPage = startPageForGlobeMode()
                    applyPendingData()   // fully black
                    normal?.enter(fromGlobe: true)
                }
            }
        default:
            if ctx.fade2.isIdle { ctx.ui.clearHover(); go(.normal); step = 1 }
        }
    }

    /// Hub start page from the globe display mode (non-JP: current 0–1 → 1, today 2–3 → 2, tomorrow 4–5 → 3).
    func startPageForGlobeMode() -> Int {
        let m = ctx.globeMode
        if ctx.lang == .jp { return m < 6 ? 2 : 1 }
        if m < 2 { return 1 }
        if m < 4 { return 2 }
        if m < 6 { return 3 }
        return 1
    }

    /// WeatherScene_StFAE4 — settings (CSetting).
    func stSetting() {
        guard let setting else { return }
        switch step {
        case 0:
            bgmEnterOption()
            setting.reset()
            ctx.fade.startFadeIn(0x19)
            step = 1
        case 1:
            setting.calc()
            if ctx.fade.isIdle { step = 2; setting.startInteractive(); ctx.request = 0 }
        case 2:
            setting.calc()
            switch ctx.request {
            case 1:   // change city
                step = 4; ctx.fade.startFadeOut(0x19); setting.startPassive(); settingsChangeCity = true
            case 2:   // back (save if changed)
                step = 3; ctx.fade.startFadeOut(0x19); setting.startPassive()
            default: break
            }
        case 3:
            setting.calc()
            if ctx.fade.isIdle {
                // StFAE4 step 3: store only when the location or a unit changed.
                if save.location != ctx.locationID.raw || save.tempUnit != UInt32(ctx.tempUnit) || save.windUnit != UInt32(ctx.windUnit) {
                    storeResult = storeSave()
                    if storeResult != 0 { go(.connectError); return }
                }
                applyPendingData()   // fully black
                ctx.fade.startFadeIn(0x19)
                ctx.isTopLevel = true
                go(.normal)
            }
        default:
            setting.calc()
            if ctx.fade.isIdle {
                ctx.fade.startFadeIn(0x19)   // StFAE4 step 4
                address?.firstRun = false
                ctx.request = 1
                go(.address)
            }
        }
    }

    /// WeatherScene_StConnect (fn_80010114)
    func stConnect() {
        if step == 0 {
            message.open(storeResult == 3 ? 4 : 5)
            ctx.playSE(0x19)
            step = 1
        }
        message.update()
    }

    // MARK: - BGM (fn_8000ED20 / fn_8000F4B8 / fn_8000E7FC / fn_8000DD84)

    var bgmIDs: [Int] { ctx.isDaytime ? [30, 28, 29, 34] : [33, 31, 32, 34] }

    func bgmStart(_ i: Int) {
        guard let s = ctx.sound else { return }
        if !s.isAttached(s.bgmHandles[i]) { _ = s.startSound(s.bgmHandles[i], bgmIDs[i]); s.setVolume(s.bgmHandles[i], bgmCur[i]) }
        else { s.pause(s.bgmHandles[i], false) }
    }

    /// fn_8000ED20 — entering the hub ("SELF").
    func bgmEnterSelf() {
        let d = dayIdx
        if ctx.isTopLevel {
            if let s = ctx.sound, !s.isAttached(s.bgmHandles[0]) {
                _ = s.startSound(s.bgmHandles[0], bgmIDs[0])
                bgmCur[0] = 1; bgmTarget[0] = 1; s.setVolume(s.bgmHandles[0], 1)
            } else {
                ctx.sound.map { $0.pause($0.bgmHandles[0], false) }
                bgmTarget[0] = 1; bgmStep[0] = fadeIn[d][0]
            }
            bgmTarget[1] = 0; bgmStep[1] = fadeOut[d][1]
        } else {
            ctx.sound.map { $0.pause($0.bgmHandles[1], false); $0.pause($0.bgmHandles[2], false) }
            bgmTarget[0] = 0; bgmStep[0] = fadeOut[d][0]
            bgmTarget[1] = 1; bgmStep[1] = fadeIn[d][1]
        }
        bgmTarget[2] = 0; bgmStep[2] = fadeOut[d][2]
        bgmTarget[3] = 0; bgmStep[3] = fadeOut[d][min(bgmMode, 3)]
    }

    /// fn_8000F4B8 — entering the globe group (forecast + globe layers).
    func bgmEnterGlobe() {
        let d = dayIdx
        bgmMode = 2
        bgmTarget[0] = 0; bgmStep[0] = fadeOut[d][0]
        bgmStart(1); bgmStart(2)
        bgmTarget[1] = 1; bgmStep[1] = fadeIn[d][1]
        bgmTarget[2] = 1; bgmStep[2] = fadeIn[d][2]
        bgmTarget[3] = 0; bgmStep[3] = fadeOut[d][bgmMode]
    }

    /// fn_8000E7FC — entering settings / city select ("OPTION").
    func bgmEnterOption() {
        let d = dayIdx
        bgmMode = 3
        bgmStart(3)
        bgmTarget[1] = 0; bgmStep[1] = fadeOut[d][1]
        bgmTarget[0] = 0; bgmStep[0] = fadeOut[d][0]
        bgmTarget[2] = 0; bgmStep[2] = fadeOut[d][2]
        bgmTarget[3] = 1; bgmStep[3] = fadeIn[d][bgmMode]
    }

    /// fn_8000DD84 tail: move each layer toward its target (fn_800369A8), apply volume, pause silent layers.
    func updateBGM() {
        guard let s = ctx.sound else { return }
        for i in 0..<4 where s.isAttached(s.bgmHandles[i]) {
            if bgmCur[i] < bgmTarget[i] { bgmCur[i] = min(bgmCur[i] + bgmStep[i], bgmTarget[i]) }
            else if bgmCur[i] > bgmTarget[i] { bgmCur[i] = max(bgmCur[i] - bgmStep[i], bgmTarget[i]) }
            s.setVolume(s.bgmHandles[i], bgmCur[i])
        }
        if bgmCur[0] == 0, s.isAttached(s.bgmHandles[0]) { s.pause(s.bgmHandles[0], true) }
        if bgmCur[1] == 0 && bgmCur[2] == 0 {
            if s.isAttached(s.bgmHandles[1]) { s.pause(s.bgmHandles[1], true) }
            if s.isAttached(s.bgmHandles[2]) { s.pause(s.bgmHandles[2], true) }
        }
        if bgmCur[3] == 0, s.isAttached(s.bgmHandles[3]) { s.pause(s.bgmHandles[3], true) }
    }

    // MARK: - System_Frame transition overlay

    /// Start a System_Frame overlay. mode 1 black fade, 2 captured-frame cross-fade, 3/4 zoom cross-fade
    /// (texcoord inset 0.1·e; mode 3 inverts alpha). The current frame is captured at the end of this frame.
    public func startTransition(mode: Int, frames: Int) {
        transitionMode = mode; transitionLength = max(frames, 1); transitionCount = 0
        if mode >= 2 { pendingCapture = true }
    }

    // MARK: - Render

    var viewportSize = SIMD2<Float>(1, 1)
    var viewportOrigin = SIMD2<Float>(0, 0)

    /// Logical (0..W × 0..456) rect → drawable scissor (offscreen scene texture coordinates).
    func scissor(_ x: Float, _ y: Float, _ w: Float, _ h: Float) -> MTLScissorRect {
        let sx = viewportSize.x / ctx.screenWidth, sy = viewportSize.y / LogicalScreen.height
        let x0 = max(0, Int(x * sx)), y0 = max(0, Int(y * sy))
        let x1 = min(Int(viewportSize.x), Int((x + w) * sx)), y1 = min(Int(viewportSize.y), Int((y + h) * sy))
        return MTLScissorRect(x: x0, y: y0, width: max(1, x1 - x0), height: max(1, y1 - y0))
    }

    func ensureTargets(_ w: Int, _ h: Int) {
        if let t = sceneColor, t.width == w, t.height == h { return }
        let cd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: ctx.gx.colorFormat, width: w, height: h, mipmapped: false)
        cd.usage = [.renderTarget, .shaderRead]; cd.storageMode = .private
        sceneColor = ctx.device.makeTexture(descriptor: cd)
        capture = ctx.device.makeTexture(descriptor: cd)
        let dd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: ctx.gx.depthFormat, width: w, height: h, mipmapped: false)
        dd.usage = .renderTarget; dd.storageMode = .private
        sceneDepth = ctx.device.makeTexture(descriptor: dd)
    }

    /// Draws the whole frame: scene into an offscreen target, then composite + overlay into `pass` at `viewport`.
    public func render(commandBuffer cb: MTLCommandBuffer, pass: MTLRenderPassDescriptor, viewport: MTLViewport) {
        let w = max(Int(viewport.width), 1), h = max(Int(viewport.height), 1)
        viewportSize = SIMD2(Float(w), Float(h)); viewportOrigin = SIMD2(Float(viewport.originX), Float(viewport.originY))
        ensureTargets(w, h)
        guard let color = sceneColor, let depth = sceneDepth else { return }
        ctx.gx.beginFrame()

        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = color; rp.colorAttachments[0].loadAction = .clear; rp.colorAttachments[0].storeAction = .store
        rp.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        rp.depthAttachment.texture = depth; rp.depthAttachment.loadAction = .clear; rp.depthAttachment.clearDepth = 1
        rp.depthAttachment.storeAction = .dontCare
        if let enc = cb.makeRenderCommandEncoder(descriptor: rp) {
            enc.setViewport(MTLViewport(originX: 0, originY: 0, width: Double(w), height: Double(h), znear: 0, zfar: 1))
            drawScene(enc)
            enc.endEncoding()
        }
        if pendingCapture, let cap = capture, let blit = cb.makeBlitCommandEncoder() {
            blit.copy(from: color, to: cap); blit.endEncoding(); pendingCapture = false
        }
        guard let enc = cb.makeRenderCommandEncoder(descriptor: pass) else { return }
        enc.setViewport(viewport)
        d2.texture(color, x0: 0, y0: 0, x1: ctx.screenWidth, y1: LogicalScreen.height, alpha: 255, enc)
        drawTransition(enc)
        enc.endEncoding()
    }

    /// CScene_Draw: state draw PTMF, then the two CFade quads.
    func drawScene(_ enc: MTLRenderCommandEncoder) {
        switch state {
        case .boot:
            if step >= 4 { message.draw(enc, d2) } else { connect.draw(enc, d2, weatherTPL: weatherTPL) }
        case .address:
            address?.draw(enc)
        case .normal:
            // step 4: the hub dims while the overlay fades in; step 5: the reset globe shows as it fades out.
            // WeatherScene_StE6C8: GlobeScreen_Draw, then the hub (fn_80023E58) over it.
            around?.draw(enc)
            // (not on the frame between a marker tap and StNormal step 0 — the hub isn't entered yet: no flicker)
            if step < 5 && !(step == 0 && pendingOpenZoom) { normal?.draw(enc) }
            drawCredit(enc)
        case .globe:
            around?.draw(enc)
            // StE6C8 keeps drawing the hub: it finishes zooming back into the marker over the globe.
            if step >= 3 || normal?.zoomActive == true { normal?.draw(enc) }
            drawCredit(enc)
        case .setting:
            setting?.draw(enc)
        case .connectError:
            message.draw(enc, d2)
        }
        // m_pFade2 (dim) then m_pFade (black)
        if ctx.fade2.alpha > 0 { d2.fillRect(0, 0, ctx.screenWidth, LogicalScreen.height, color: SIMD4(0, 0, 0, UInt8(min(255, ctx.fade2.alpha))), enc) }
        if ctx.fade.alpha > 0 { d2.fillRect(0, 0, ctx.screenWidth, LogicalScreen.height, color: SIMD4(0, 0, 0, UInt8(min(255, ctx.fade.alpha))), enc) }
        drawOverlay(enc)
    }

    /// WeatherScene_StE6C8 tail: after the hub, Setup2DRender (TEV REG0 white, so opaque whatever the hub's
    /// fade) and TPLWeather image 0x18 + bit 1 (JP 0x16) at lbl_801D6F7C = (28 / 36 wide, creditY + lbl_803309D8).
    /// lbl_803309D8 = CAround +2AC = +2B0·slide; the globe layout never slides out, so it stays 0. With bit 0,
    /// TPLCommon 3 (6 with bit 1) directly below it.
    /// iPhone: back from the Home Screen after "Wii Menu" — re-enter the hub from black (StNormal step 0).
    public func resumeFromSuspend() {
        guard wantsSuspend else { return }
        wantsSuspend = false; quitting = false; ctx.returnToWiiMenu = false; ctx.request = 0
        ctx.isTopLevel = true; ctx.displayLocation = nil
        ctx.ui.clearHover()
        ctx.fade.startFadeIn(0x19)
        go(.normal)
    }

    func drawCredit(_ enc: MTLRenderCommandEncoder) {
        // The hub's credit fades with the hub (zooms from a marker); over the globe it is drawn as in the original.
        var alpha: UInt8 = 255
        if state == .normal && step < 5, let n = normal {
            alpha = UInt8(max(0, min(255, 255 * n.globalAlpha)))
            if alpha == 0 { return }
        }
        if overlaySprites == nil { overlaySprites = try? SpriteText(ctx: ctx) }
        guard let sp = overlaySprites else { return }
        let x: Float = ctx.isWide ? 36 : 28
        // + lbl_803309D8 (always 0). Portrait: the credit rides with the bottom row (above the strip).
        let y = ctx.isPortrait ? PortraitSlots.pixelBottom(creditY) : creditY
        let img = (ctx.lang == .jp ? 0x16 : 0x18) + ((creditFlags >> 1) & 1)
        let white = SIMD4<UInt8>(255, 255, 255, alpha)
        sp.drawImage(common: false, img, topLeft: SIMD2(x, y), sx: 1, sy: 1, color: white, enc)
        if creditFlags & 1 != 0 {
            let h = sp.imageSize(common: false, img).y
            sp.drawImage(common: true, creditFlags & 2 != 0 ? 6 : 3, topLeft: SIMD2(x, y + h), sx: 1, sy: 1, color: white, enc)
        }
    }

    /// fn_8000DCA4 (CWeatherScene vtable +0x38, called by CScene_Draw after the fades): TPLCommon image
    /// lbl_8018F64C[lang] centred on screen, TEV REG0 = (+D8..DA = white, alpha = +140 dimAlpha).
    func drawOverlay(_ enc: MTLRenderCommandEncoder) {
        guard dimAlpha > 0 else { return }
        if overlaySprites == nil { overlaySprites = try? SpriteText(ctx: ctx) }
        guard let sp = overlaySprites else { return }
        let table = [0x64, 0x66, 0x62, 0x66, 0x65, 0x63, 0x61]   // lbl_8018F64C
        let idx = table[min(ctx.lang.rawValue, table.count - 1)]
        let size = sp.imageSize(common: true, idx)
        sp.drawImage(common: true, idx, topLeft: SIMD2(0.5 * ctx.screenWidth - 0.5 * size.x, LogicalScreen.halfHeight - 0.5 * size.y), sx: 1, sy: 1,
                     color: SIMD4(255, 255, 255, UInt8(dimAlpha)), enc)
    }

    /// System_Frame overlay, eased with sin(t·π/2).
    func drawTransition(_ enc: MTLRenderCommandEncoder) {
        guard transitionMode != 0 else { return }
        let t = Float(transitionCount) / Float(transitionLength)
        let e = sin(t * .pi / 2)
        switch transitionMode {
        case 1:
            d2.fillRect(0, 0, ctx.screenWidth, LogicalScreen.height, color: SIMD4(0, 0, 0, UInt8(255 * e)), enc)
        case 2:
            if let cap = capture { d2.texture(cap, x0: 0, y0: 0, x1: ctx.screenWidth, y1: LogicalScreen.height, alpha: UInt8(255 * (1 - e)), enc) }
        default:
            if let cap = capture {
                let inset = 0.1 * e
                let a = transitionMode == 3 ? 1 - e : e
                d2.texture(cap, x0: 0, y0: 0, x1: ctx.screenWidth, y1: LogicalScreen.height, uv: SIMD4(inset, inset, 1 - inset, 1 - inset),
                           alpha: UInt8(255 * a), enc)
            }
        }
    }
}
