import Foundation
import Metal
import NW4R
import simd

/// CNormal (d_weather_normal.cpp, ctor fn_80020F9C) — the hub: buttons (forecast.brlyt), background (base.brlyt),
/// top belt with page title / city telop / clock (base_belt.brlyt), the 6-hour strip (day_6h_nWW.brlyt), and the
/// vertically stacked pages (UV, Current, Today, Tomorrow, 5-Day) scrolled with up/down.
public final class NormalScreen: Screen {
    let ctx: SceneContext
    let forecast: UILayout        // +00
    let base: UILayout            // +04
    let belt: UILayout            // +08
    let sixHours: UILayout        // +0C
    let sprites: SpriteText
    let telop: TelopText
    let strings: DOLStrings
    var pages: [HubPage] = []     // +24[]

    /// TextWriter font lbl_80330BDC = m_pSysFont (wbf1.brfna, content 7).
    let telopFont: ResFont?
    let timeFont: ResFont?        // lbl_80330BE0 font_weather_timeWW.brfnt

    var record: HubRecord?

    // Scroll (unk72C/730, target unk7E0, state unk800)
    var scroll: Float = 456       // +730
    var scrollState = -1          // −1 settled/interactive, ≥0 scrolling
    var reqUp = false, reqDown = false   // +7F7/+7F8
    public internal(set) var globalAlpha: Float = 1    // +7D0
    /// +7F9: the button layout is drawn (cleared when the hub zooms back into the globe).
    var buttonsVisible = true

    // MARK: Globe ↔ city zoom — fn_80027270 (open, from the tapped marker) / fn_80026DC8 (close, back into it)
    enum ZoomMode { case none, open, close }
    var zoomMode = ZoomMode.none
    var zoomCounter = 0                     // +854 (+0x800 per frame, done past 0x8000 = 16 frames)
    var zoomFrom = SIMD2<Float>(0, 0)       // +7E8/+7EC
    var zoomDelta = SIMD2<Float>(0, 0)      // +7E0/+7E4
    var zoomCentre = SIMD2<Float>(0, 0)     // +768/+76C
    var zoomRectAlpha = 0                   // +804
    /// +7F5: the zoom quad is drawn.
    public var zoomActive: Bool { zoomMode != .none }
    var screenCentre: SIMD2<Float> { SIMD2(ctx.screenWidth / 2, LogicalScreen.halfHeight) }

    /// fn_80027270 step 0: alpha 0, the quad starts at the marker.
    public func startOpenZoom(from p: SIMD2<Float>) {
        zoomMode = .open; zoomCounter = 0
        zoomFrom = p; zoomDelta = screenCentre - p
        globalAlpha = 0; zoomCentre = p; zoomRectAlpha = 40
    }
    /// fn_80026DC8 step 0: from the current page's centre (page offset 0 at rest) toward the marker.
    public func startCloseZoom(to p: SIMD2<Float>) {
        zoomMode = .close; zoomCounter = 0
        zoomFrom = screenCentre; zoomDelta = p - screenCentre
        globalAlpha = 1; zoomCentre = zoomFrom; zoomRectAlpha = 0
    }
    /// The zoom sub-state's frame: t = ½ − ½·CosFIdx(+854 / 256) (fn_800D7AFC, 256 = one turn), so t eases 0 → 1.
    public func stepZoom() {
        guard zoomMode != .none else { return }
        zoomCounter += 0x800
        if zoomCounter > 0x8000 {
            globalAlpha = zoomMode == .open ? 1 : 0
            zoomMode = .none
        } else {
            let t = 0.5 - 0.5 * cos(Float.pi * Float(zoomCounter) / 0x8000)
            globalAlpha = zoomMode == .open ? t : 1 - t
            zoomCentre = zoomFrom + zoomDelta * t
            zoomRectAlpha = Int(40 * (1 - globalAlpha))
        }
        for (i, p) in pages.enumerated() { p.calc(offset: SIMD2(0, scroll - pageSpacing * Float(i)), alphaFactor: globalAlpha) }
    }
    // Belt title alpha (unk810 → unk814), clock alpha (unk81C → unk820)
    var titleAlpha = 255, titleTarget = 255
    var clockAlpha = 255, clockTarget = 255
    var shownTitle = 1            // +82C belt title text index
    // Title alternation page name ↔ weekday (fn_80026B34): state +828, timer +824
    var titleState = 0, titleTimer = 0xF0
    // City telop ticker (fn_80027998): state +848, line +84C, timer +850, scroll +7D8
    var tickerState = 0, tickerLine = 0, tickerTimer = 0xF0
    var tickerScroll: Float = 0
    // Timestamp "As of …" (fn_8002322C → fn_80023430): text +85C, scale +788/+78C, max width +780
    var stamp = ""
    var stampScale = SIMD2<Float>(0.6, 0.6)
    var stampPage = -1
    // 6-hour popup (fn_80025FA8): 0 closed, 1 opening, 2 open, 3 closing
    var popup = 0, popupT = 0      // unk854 in 0..0x8000
    var exitRequested = false

    // City telop (CNormal_SetupCityTelop): lines + per-line fit scale; city box (unk790..798, unk794..79C).
    var cityLines: [(String, Float)] = []
    var cityBox = SIMD4<Float>(0, 0, 0, 0)

    // MARK: iPhone portrait
    /// Vertical distance between stacked pages (456 on the Wii; the content band height in portrait).
    let pageSpacing: Float
    /// Logical rect → drawable scissor (set by WeatherScene) — portrait clips the pages to the content band.
    var scissor: ((Float, Float, Float, Float) -> MTLScissorRect)?
    /// Portrait one-finger swipe on the page band (▲/▼): accumulated travel, armed per touch.
    var swipeAccum: Float = 0, swipeArmed = false, swipeDone = false, lastFingers = 0

    /// Portrait arrangement of the original rows (layout space, origin = screen centre, y up).
    ///   belt (title + city) under the safe area → top button row under the belt → content band →
    ///   "supported by" / "As of" strip → bottom button row above the home indicator.
    struct Portrait {
        let beltShift: Float      // belt group + city box (authored y = +130)
        let topShift: Float       // blank / up / set (authored y = +195; body spans +166…+246)
        let bottomShift: Float    // back / down / around + the strip (authored −195 / −146)
        let bandTop: Float, bandBottom: Float
        var bandCentre: Float { (bandTop + bandBottom) / 2 }
        var bandHeight: Float { bandTop - bandBottom }
        static var current: Portrait {
            // Original order: the top button row first (its body runs up through the safe area to the screen edge),
            // then the green belt under it (same 6-unit gap as on the Wii: row bottom +166, belt top +160).
            let top = PortraitSlots.safeTopY
            let topShift = (top - 40) - 206             // row body (centre +206, 80 tall) starts at the safe top
            let beltCentre = (166 + topShift) - 6 - 30  // beltB is 60 tall
            let beltShift = beltCentre - 130
            let bottomShift = PortraitSlots.bottomRowShift
            return Portrait(beltShift: beltShift, topShift: topShift, bottomShift: bottomShift,
                            bandTop: beltCentre - 30, bandBottom: -135 + bottomShift)
        }
    }
    /// Band centre / pixel rect, for pages and the 6-hour popup.
    var portrait: Portrait { Portrait.current }

    public init(ctx: SceneContext) throws {
        self.ctx = ctx
        forecast = try ctx.layout("forecast.brlyt")
        base = try ctx.layout("base.brlyt")
        belt = try ctx.layout("base_belt.brlyt")
        sixHours = try ctx.layout(ctx.lang == .jp ? "day_6h_nJP.brlyt" : "day_6h_nWW.brlyt")
        sprites = try SpriteText(ctx: ctx)
        telop = TelopText(ctx: ctx)
        strings = try DOLStrings(ctx.assets)
        telopFont = ctx.assets.systemFont() ?? ctx.assets.font("font_weather_city.brfnt")   // m_pSysFont (wbf1.brfna)
        timeFont = ctx.assets.font(ctx.lang == .jp ? "font_weather_time.brfnt" : "font_weather_timeWW.brfnt")
        ctx.startPage = 1
        pageSpacing = ctx.isPortrait ? Portrait.current.bandHeight.rounded() : 456
        if ctx.isPortrait { arrangePortrait() }
        // Pages: page i centred at y = 228 + 456·i (fn_80020F9C).
        pages = [try UVPage(self, layout: "life_nWW.brlyt", index: 0, title: 0),
                 try CurrentPage(self, layout: "day_nWW.brlyt", index: 1, title: 1),
                 try DayPage(self, index: 2, tomorrow: false),
                 try DayPage(self, index: 3, tomorrow: true),
                 try WeekPage(self, layout: "week_nWW.brlyt", index: 4, title: 4)]
        ctx.pageCount = pages.count
        // fn_800393E8(belt_time wrapper, "belt_timeB") (Pane_SetChildVisible): only belt_timeB<lang> stays visible.
        if let g = belt.pane("belt_timeB") {
            let keep = "belt_timeB" + ctx.lang.suffix
            for c in g.children where c.name != keep { c.visible = false }
        }
        // City box from the `city` bounding pane (wide: ×1.3684211 about the screen centre).
        if let city = belt.pane("city") {
            belt.layout.root.calculate(parentMtx: matrix_identity_float4x4, parentAlpha: 255)
            let k: Float = ctx.isWide ? 1.368_421_1 : 1
            let c = SpriteText.layoutCenter(city)
            let w = city.size.x * k, h = city.size.y
            let x0 = ctx.screenWidth / 2 + c.x * k - w / 2
            let y0 = LogicalScreen.halfHeight - c.y - h / 2
            cityBox = SIMD4(x0, y0, x0 + w, y0 + h)
        }
    }

    /// iPhone portrait: move the original rows to their portrait slots, stretch the background plate, centre the
    /// 6-hour popup in the content band. Hit rects follow (UILayout.place recomputes them).
    func arrangePortrait() {
        // No Wii-Remote glyphs on the iPhone: the Ⓐ beside "Back" goes, the caption centres.
        forecast.pane("backI")?.suppressed = true
        if let t = forecast.pane("backT" + ctx.lang.suffix + "1") { t.translate.x = 0 }
        let g = Portrait.current
        if let bg = base.find("bg") { bg.pane.scale.y = PortraitSlots.backgroundScaleY; base.relayout() }
        forecast.place(["blank": SIMD2(0, g.topShift), "up": SIMD2(0, g.topShift), "set": SIMD2(0, g.topShift),
                        "back": SIMD2(0, g.bottomShift), "down": SIMD2(0, g.bottomShift), "around": SIMD2(0, g.bottomShift)])
        belt.place(["belt": SIMD2(0, g.beltShift), "city": SIMD2(0, g.beltShift),
                    "belt_logo": SIMD2(0, g.bottomShift), "belt_time": SIMD2(0, g.bottomShift),
                    "timeJP": SIMD2(0, g.bottomShift), "timeWW": SIMD2(0, g.bottomShift)])
        PortraitArrange.extendBodies(forecast, ["back", "down", "around"], toTop: false)   // bottom row to the screen edge
        PortraitArrange.extendBodies(forecast, ["blank", "up", "set"], toTop: true)        // top row to the screen edge
        if let f = sixHours.find("bg_filter") { f.pane.scale.y = PortraitSlots.backgroundScaleY }
        sixHours.placeAll(SIMD2(0, g.bandCentre), except: ["bg_filter"])
    }

    /// Content band in SetOrtho2D pixels (y down): x, y, w, h.
    var bandPixels: SIMD4<Float> {
        let g = portrait
        return SIMD4(0, PortraitSlots.pixelY(g.bandTop), ctx.screenWidth, g.bandHeight)
    }

    /// Enter the hub (from boot / settings / globe).
    public func enter(fromGlobe: Bool) {
        record = HubRecord.find(ctx.data, ctx.displayLocation ?? ctx.locationID)
        setupCityTelop()
        forecast.reset(); base.reset(); belt.reset(); sixHours.reset()
        scroll = pages[min(ctx.startPage, pages.count - 1)].scrollTarget
        scrollState = -1
        shownTitle = pages[ctx.startPage].titleIndex
        titleAlpha = 255; titleTarget = 255
        titleState = 0; tickerState = 0; tickerScroll = 0; stampPage = -1
        popup = 0; popupT = 0
        exitRequested = false
        buttonsVisible = true; zoomMode = .none; globalAlpha = 1
        // Ready before the first visible frame (the hub is drawn under the fade-in before its first calc):
        // button state for this level, and every page's alpha/offset at full opacity — no stale values from the
        // last close-zoom (alpha 0) popping in a frame later.
        applyButtonState()
        forecast.update()
        for (i, p) in pages.enumerated() { p.calc(offset: SIMD2(0, scroll - pageSpacing * Float(i)), alphaFactor: globalAlpha) }
    }

    /// CNormal_StInteractive step 1 (button state for top level / city opened from the globe).
    func applyButtonState() {
        guard let set = forecast.find("set"), let back = forecast.find("back"), let up = forecast.find("up"),
              let down = forecast.find("down"), let around = forecast.find("around") else { return }
        // CNormal_StInteractive: +10 = "around", +14 = "set", +18 = "back" (ctor 0x800215AC..). Top level:
        // around/set enabled, backI hidden, caption "Wii Menu"; opened from a globe marker: around and set
        // disabled + pressed, back shows backI and "Back".
        if ctx.isTopLevel {
            // iPhone: settings live in the iOS Settings app — the Settings slot stays as a blank, inert button.
            around.disabled = false; set.disabled = ctx.isPortrait
            back.pane.find("backI")?.visible = false
            back.textIndex = 0; back.pendingTextIndex = 0
        } else {
            around.disabled = true; around.press(); set.disabled = true; set.press()
            back.pane.find("backI")?.visible = true
            back.textIndex = 1; back.pendingTextIndex = 1
        }
        updateUpDownButtons(up, down)
        if ctx.isPortrait { portraitBottomRow(topLevel: ctx.isTopLevel, back: back, down: down) }
    }

    // MARK: - Calc (CNormal_StInteractive fn_800227B0)

    public func calc() {
        if record == nil { record = HubRecord.find(ctx.data, ctx.displayLocation ?? ctx.locationID); setupCityTelop() }
        let pad = ctx.pad
        reqUp = false; reqDown = false
        guard let set = forecast.find("set"), let back = forecast.find("back"), let up = forecast.find("up"),
              let down = forecast.find("down"), let around = forecast.find("around") else { return }
        // 1. CNormal_StInteractive: +10 = "around", +14 = "set", +18 = "back" (ctor 0x800215AC..). Top level:
        //    around/set enabled, backI hidden, caption "Wii Menu"; opened from a globe marker: around and set
        //    disabled + pressed, back shows backI and "Back".
        applyButtonState()
        forecast.update(); base.update(); belt.update(); sixHours.update()

        if popup == 0 {
            ctx.ui.updateHover(forecast, pad, hoverSE: 0x28)
            if !up.disabled, ctx.ui.buttonTrig("up", pad) { reqUp = true }
            else if pad.trig.contains(.up) { if !up.disabled { reqUp = true; up.flash() } else { ctx.playSE(0x2B) } }
            if !down.disabled, ctx.ui.buttonTrig("down", pad) { reqDown = true }
            else if pad.trig.contains(.down) { if !down.disabled { reqDown = true; down.flash() } else { ctx.playSE(0x2B) } }
            if ctx.ui.buttonTrig("set", pad) { ctx.playSE(0x25); ctx.request = 4; set.keepPressed = true }
            if ctx.ui.buttonTrig("back", pad) {
                if ctx.isTopLevel { ctx.playSE(0x25); ctx.returnToWiiMenu = true }
                ctx.playSE(0x26); ctx.request = 3; back.keepPressed = true
                // off the top level: CNormal_StInteractive switches +168 to fn_80026DC8 (zoom back into the marker)
                if !ctx.isTopLevel { startCloseZoom(to: ctx.markerPoint) }
                exitRequested = true
            }
            if ctx.ui.buttonTrig("around", pad) { ctx.playSE(0); ctx.request = 5; around.keepPressed = true; exitRequested = true }
            if ctx.isPortrait { portraitSwipe(up, down) }
            // A outside the buttons on Today/Tomorrow opens the 6-hour strip (fn_80025FA8 state 3 entry).
            // (Portrait: only a tap on the page band itself.)
            if pad.trig.contains(.a), ctx.ui.hovered == nil, scrollState < 0, [2, 3].contains(ctx.startPage),
               !ctx.isPortrait || inBand(pad.pointer),
               (pages[ctx.startPage] as? DayPage)?.isAvailable == true {
                popup = 1; popupT = 0; ctx.playSE(0x29)
            }
        } else if pad.trig.contains(.a) || pad.trig.contains(.b) {
            if popup == 2 { popup = 3; ctx.playSE(0x26) }
        }
        scrollUpdate()
        if scrollState < 0 { titleUpdate() }
        tickerUpdate()
        popupUpdate()
        beltFade()
        if stampPage != ctx.startPage && titleAlpha == 0 || stampPage < 0 { buildStamp(); stampPage = ctx.startPage }
        for (i, p) in pages.enumerated() { p.calc(offset: SIMD2(0, scroll - pageSpacing * Float(i)), alphaFactor: globalAlpha) }
    }

    /// iPhone: no "Wii Menu" at the top level (the Home Screen is the iPhone's own) — the back wrapper is hidden and
    /// ▼ widens over its slot (body stretched to 424 = 184 + 240, arrow kept at its left inset) so ▼ and Globe share
    /// the row edge to edge. Off the top level the original three-button row ("Back" / ▼ / Globe) returns.
    /// iPhone: at top level the bottom-left slot stays as a blank, inert button (no "Wii Menu" caption, no action) so
    /// the bottom row mirrors the top row's blank slot — the original disabled look (normal body, text/icon alpha 0,
    /// excluded from hit tests). Off the top level it is the original "Back".
    func portraitBottomRow(topLevel: Bool, back: PaneCtl, down: PaneCtl) {
        back.hidden = false
        back.disabled = topLevel
    }

    func inBand(_ p: SIMD2<Float>) -> Bool {
        let b = bandPixels
        return p.y >= b.y && p.y <= b.y + b.w
    }

    /// iPhone: a vertical one-finger swipe on the page band works like ▲/▼ (same request path as the Remote's
    /// d-pad: the button flashes, or SE 0x2B at the end). Finger up = next page (content moves up with it).
    func portraitSwipe(_ up: PaneCtl, _ down: PaneCtl) {
        let g = ctx.gestures
        if g.fingers == 1 && lastFingers == 0 {
            swipeArmed = ctx.pad.pointerValid && inBand(ctx.pad.pointer) && ctx.ui.hovered == nil
            swipeAccum = 0; swipeDone = false
        }
        lastFingers = g.fingers
        guard swipeArmed, !swipeDone, g.fingers == 1 else { return }
        swipeAccum += g.dragY
        if swipeAccum <= -60 {
            swipeDone = true
            if !down.disabled { reqDown = true; down.flash() } else { ctx.playSE(0x2B) }
        } else if swipeAccum >= 60 {
            swipeDone = true
            if !up.disabled { reqUp = true; up.flash() } else { ctx.playSE(0x2B) }
        }
    }

    /// up/down captions show the neighbour page names (upT 0..3 = page i−1, downT 1..4 = page i+1); disabled at the ends.
    func updateUpDownButtons(_ up: PaneCtl, _ down: PaneCtl) {
        let cur = ctx.startPage
        up.disabled = cur == 0
        down.disabled = cur >= pages.count - 1
        if cur > 0 { up.textIndex = cur - 1; up.pendingTextIndex = cur - 1 }
        if cur < pages.count - 1 { down.textIndex = cur; down.pendingTextIndex = cur }
    }

    /// fn_80025CF8: ChaseValue(scroll, target, 0.1125, 100, 1); title fades out while moving, swaps when invisible.
    func scrollUpdate() {
        if reqDown, ctx.startPage < pages.count - 1 { ctx.startPage += 1; scrollState = 0; ctx.playSE(0x29) }
        if reqUp, ctx.startPage > 0 { ctx.startPage -= 1; scrollState = 0; ctx.playSE(0x29) }
        guard scrollState >= 0 else { return }
        if scrollState == 0 { titleTarget = 0; clockTarget = 0; scrollState = 1; titleState = 0 }
        let target = pages[ctx.startPage].scrollTarget
        let k = pageSpacing / 456   // portrait: same feel over the taller page spacing (k = 1 on the Wii)
        let rem = GlobeMath.chaseValue(&scroll, target, 0.1125, 100 * k, 1 * k)
        if titleAlpha == 0 {
            shownTitle = pages[ctx.startPage].titleIndex; titleTarget = 255; clockTarget = 255
            buildStamp(); stampPage = ctx.startPage
        }
        if abs(rem) < 0.0008 { scrollState = -1; titleTarget = 255; clockTarget = 255 }
    }

    /// MinutesToDate (fn_800364D8): minutes since 2000-01-01 00:00 → calendar fields (wday 0 = Sunday).
    struct WDate { var minute: Int, hour: Int, mday: Int, mon: Int, year: Int, wday: Int }
    static func minutesToDate(_ m: UInt32) -> WDate {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        let d = Date(timeIntervalSince1970: 946_684_800 + Double(m) * 60)
        let c = cal.dateComponents([.minute, .hour, .day, .month, .year], from: d)
        let days = Int(m) / 1440
        return WDate(minute: c.minute ?? 0, hour: c.hour ?? 0, mday: c.day ?? 1, mon: (c.month ?? 1) - 1, year: c.year ?? 2000,
                     wday: (days + 6) % 7)
    }

    /// Weekday title index for the shown page (fn_8002698C): UV → today, Current → the current-conditions entry,
    /// Today → today, Tomorrow → today + 0x5A0 min; 5-Day keeps its page title. Belt titles 5..11 = weekdays.
    func weekdayTitle() -> Int? {
        let longTime = record?.long?.time.localTime ?? record?.summary?.time.localTime
        switch ctx.startPage {
        case 0: return longTime.map { 5 + NormalScreen.minutesToDate($0).wday }
        case 1: return record?.current.map { 5 + NormalScreen.minutesToDate($0.time.localTime).wday }
        case 2: return longTime.map { 5 + NormalScreen.minutesToDate($0).wday }
        case 3: return longTime.map { 5 + NormalScreen.minutesToDate($0 + 0x5A0).wday }
        default: return nil
        }
    }

    /// fn_80026B34: hold the page title 240 frames, fade (±0x10/frame), weekday 240 frames, fade back.
    func titleUpdate() {
        let page = pages[ctx.startPage]
        guard page.isAvailable, let weekday = weekdayTitle() else { shownTitle = page.titleIndex; return }
        switch titleState {
        case 0: titleState = 1; titleTimer = 0xF0; shownTitle = page.titleIndex
        case 1:
            if titleTimer > 0 { titleTimer -= 1 }
            if titleTimer == 0 { titleState = 2; titleTarget = 0 }
        case 2:
            if titleAlpha == 0 { titleState = 3; titleTimer = 0xF0; shownTitle = weekday; titleTarget = 255 }
        case 3:
            if titleTimer > 0 { titleTimer -= 1 }
            if titleTimer == 0 { titleState = 4; titleTarget = 0 }
        default:
            if titleAlpha == 0 { titleState = 1; titleTimer = 0xF0; shownTitle = page.titleIndex; titleTarget = 255 }
        }
    }

    /// fn_80027998: city telop ticker — hold a line 240 frames, then slide up 50 px to the next
    /// (ChaseValue(+7D8, lbl_8017B440[line] = {0, −50, −100}, 0.1, 10, 0.5)), wrapping to the first.
    func tickerUpdate() {
        if tickerState == 0 { tickerState = 1; tickerLine = 0; tickerTimer = 0xF0; tickerScroll = 0; return }
        if tickerTimer > 0 { tickerTimer -= 1 }
        let rem = GlobeMath.chaseValue(&tickerScroll, -50 * Float(tickerLine), 0.1, 10, 0.5)
        if tickerState == 1 {
            if tickerTimer == 0 {
                tickerState = 2; tickerLine += 1
                if tickerLine >= cityLines.count { tickerLine = 0 }
                tickerTimer = 0xF0
            }
        } else if abs(rem) < 0.0008 {
            tickerState = 1
        }
    }

    /// fn_8002322C + the US formatter fn_80023430: "<prefix><h>:<mm><sp><a.m./p.m.><, ><MM>/<DD>" from the
    /// entry time (Current page: the current-conditions entry; other pages: the long/summary forecast entry).
    /// All strings are read from main.dol: lbl_8019BC2C[lang], lbl_8032FF68, *lbl_803300F8 / *lbl_803300FC, lbl_8032FF6C.
    func buildStamp() {
        let t: UInt32?
        if ctx.startPage == 1 { t = record?.current?.time.localTime } else { t = record?.long?.time.localTime ?? record?.summary?.time.localTime }
        guard let m = t, m != 0, let f = telopFont else { stamp = ""; return }
        let d = NormalScreen.minutesToDate(m)
        let lang = UInt32(ctx.lang.rawValue)
        let h12 = d.hour == 0 ? 12 : (d.hour > 12 ? d.hour - 12 : d.hour)
        var out = strings.wstring(strings.dol.u32(0x8019_BC2C + lang * 4))
        out += "\(h12):" + String(format: "%02d", d.minute)
        out += strings.wstring(0x8032_FF68)
        out += strings.wstring(strings.dol.u32(d.hour < 12 ? 0x8033_00F8 : 0x8033_00FC))
        out += strings.wstring(0x8032_FF6C)
        out += String(format: "%02d/%02d", d.mon + 1, d.mday)
        stamp = out
        // scale 0.6, x shrunk to fit the timeWW box width (+780 = 1.3684211·width when wide)
        let k: Float = ctx.isWide ? 1.368_421_1 : 1
        let maxW = (belt.pane("timeWW")?.size.x ?? 280) * k
        stampScale = SIMD2(0.6, 0.6)
        let w = telop.width(out, font: f, style: TelopText.Style(scale: stampScale))
        if w > maxW, w > 0 { stampScale.x *= maxW / w }
    }

    /// fn_80025B58: belt title / clock alpha step 0x10 per frame toward their targets.
    func beltFade() {
        func step(_ v: inout Int, _ t: Int) { if v < t { v = min(v + 0x10, t) } else if v > t { v = max(v - 0x10, t) } }
        step(&titleAlpha, titleTarget); step(&clockAlpha, clockTarget)
    }

    /// fn_80025FA8 popup: 0x800 per frame up to 0x8000 (16 frames), sin-eased; dim quad alpha 40·t.
    func popupUpdate() {
        switch popup {
        case 1: popupT = min(popupT + 0x800, 0x8000); if popupT >= 0x8000 { popup = 2 }
        case 3: popupT = max(popupT - 0x800, 0); if popupT <= 0 { popup = 0 }
        default: break
        }
    }
    var popupEase: Float { sin(Float(popupT) / 0x8000 * .pi / 2) }

    // MARK: - City telop (CNormal_SetupCityTelop fn_80022D2C)

    func setupCityTelop() {
        cityLines = []
        guard let place = record?.place, let f = telopFont else { return }
        let boxW = cityBox.z - cityBox.x
        var lines = [place.city]
        if ctx.lang == .jp, place.id.country == 1 {
            if let r = place.region { lines[0] += r }
            if let c = place.country { lines.append(c) }
        } else {
            if let r = place.region, !r.isEmpty { lines.append(r) }
            if let c = place.country, !c.isEmpty { lines.append(c) }
        }
        for l in lines {
            let w = telop.width(l, font: f)
            cityLines.append((l, w > boxW && w > 0 ? boxW / w : 1))
        }
        tickerState = 0
    }

    // MARK: - Draw (fn_80023E58)

    /// CLayout_Draw with a page translation and layout alpha (fn_8003A35C + fn_8003A3CC).
    func drawLayout(_ ui: UILayout, _ enc: MTLRenderCommandEncoder, translateY: Float = 0, alpha: UInt8 = 255, before: (() -> Void)? = nil) {
        guard ui.visible else { return }
        // fn_8003A35C → fn_8003927C: every root pane's mGlbAlpha (+0xCD) = alpha — ignores the wrappers' fixed flag
        // (so the base plate really is half transparent off the top level, showing the globe).
        for p in ui.panes { p.pane.subtreeAlpha = alpha }
        ui.panes.forEach { $0.preDraw() }
        before?()
        ui.layout.root.translate = SIMD3(0, translateY, 0)
        ctx.lyt.draw(ui.layout, enc, screenWidth: 608, locationAdjust: ui.locationAdjust)
    }

    public func draw(_ enc: MTLRenderCommandEncoder) {
        let a = UInt8(255 * globalAlpha)
        // background plate: full on top level, half otherwise
        drawLayout(base, enc, alpha: ctx.isTopLevel ? a : UInt8(128 * globalAlpha))
        if ctx.isPortrait, let sc = scissor {
            let b = bandPixels
            enc.setScissorRect(sc(b.x, b.y, b.z, b.w))
            for p in pages { p.draw(enc) }
            enc.setScissorRect(sc(0, 0, ctx.screenWidth, LogicalScreen.height))
        } else {
            for p in pages { p.draw(enc) }
        }
        // fn_80023E58 (+7F5): the white zoom quad, centre +768/+76C, half size (W/2, H/2)·+7D0, alpha +804
        // (fn_8002E79C → fn_8002E5C0: GX quad, raster colour).
        if zoomActive && zoomRectAlpha > 0 {
            let h = SIMD2(ctx.screenWidth / 2, LogicalScreen.halfHeight) * globalAlpha
            ctx.lyt.drawScreenRect(x0: zoomCentre.x - h.x, y0: zoomCentre.y - h.y, x1: zoomCentre.x + h.x, y1: zoomCentre.y + h.y,
                                   color: SIMD4(255, 255, 255, UInt8(zoomRectAlpha)), screenWidth: ctx.screenWidth, enc)
        }
        if buttonsVisible { drawLayout(forecast, enc) }
        if popup != 0 { drawSixHours(enc) }
        // belt with fading title
        // Closing back into the globe: the belt (title, city, clock strip) is gone at once, before the zoom — only
        // the pages and the zoom quad play the close.
        if zoomMode == .close { return }
        drawLayout(belt, enc, alpha: a) { [self] in
            if let t = belt.pane("beltT") { PaneCtl.setAlpha(t, titleAlpha * Int(a) / 255) }
            if let bp = belt.find("belt") {
                // CPaneCtl text variant = page title index (beltT<lang><N>: A main, B shadow).
                bp.textIndex = shownTitle
                if let tg = bp.text { for (i, c) in tg.children.enumerated() { c.visible = i == shownTitle } }
            }
        }
        drawCityTelop(enc, alpha: a)
        drawStamp(enc, alpha: UInt8(Float(clockAlpha) * globalAlpha))
        // The credit is CWeatherScene's (WeatherScene_StE6C8 → WeatherScene.drawCredit).
    }


    /// fn_80023E58 telop part: lines spaced 50 px (+400 − +3F8), x = box right edge (+798), y = box centre + ticker
    /// scroll + i·50, draw flag 0x122, writer scale (fit, 1.0); scissor y 74..124; shadow (0x20) at +1,+1, then white.
    func drawCityTelop(_ enc: MTLRenderCommandEncoder, alpha: UInt8) {
        guard let f = telopFont, !cityLines.isEmpty else { return }
        let centre = (cityBox.y + cityBox.w) / 2
        let clip: ClosedRange<Float> = (centre - 23)...(centre + 27)   // 74…124 on the Wii (box centre 97)
        for (i, (s, fit)) in cityLines.enumerated() {
            let y = centre + tickerScroll + 50 * Float(i)
            guard y + 30 > clip.lowerBound, y - 30 < clip.upperBound else { continue }
            let st = TelopText.Style(scale: SIMD2(fit, 1), flags: 0x122)
            telop.draw(s, font: f, at: SIMD2(cityBox.z + 1, y + 1), style: st, color: SIMD4(0x20, 0x20, 0x20, alpha), enc, clipY: clip)
            telop.draw(s, font: f, at: SIMD2(cityBox.z, y), style: st, color: SIMD4(255, 255, 255, alpha), enc, clipY: clip)
        }
    }

    /// Timestamp at the timeWW anchor: x = W − 36 (wide; 28 otherwise), y = 228 − centre.y, flag 0x122, white × +81C.
    func drawStamp(_ enc: MTLRenderCommandEncoder, alpha: UInt8) {
        guard let f = telopFont, !stamp.isEmpty, let box = belt.pane("timeWW") else { return }
        belt.layout.root.calculate(parentMtx: matrix_identity_float4x4, parentAlpha: 255)
        let y = LogicalScreen.halfHeight - SpriteText.layoutCenter(box).y
        let x = ctx.screenWidth - (ctx.isWide ? 36 : 28)
        telop.draw(stamp, font: f, at: SIMD2(x, y), style: TelopText.Style(scale: stampScale, flags: 0x122),
                   color: SIMD4(255, 255, 255, alpha), enc)
    }

    /// 6-hour strip overlay (day_6h_nWW): dim quad + layout + 4 slot icons and precipitation texts.
    func drawSixHours(_ enc: MTLRenderCommandEncoder) {
        let e = popupEase
        ctx.lyt.drawScreenRect(x0: 0, y0: 0, x1: ctx.screenWidth, y1: LogicalScreen.height, color: SIMD4(0, 0, 0, UInt8(40 * e * 3)), screenWidth: ctx.screenWidth, enc)
        let a = UInt8(255 * e)
        drawLayout(sixHours, enc, alpha: a)
        guard let page = pages[safe: ctx.startPage] as? DayPage, let d = page.day else { return }
        let k: Float = ctx.isWide ? 1.368_421_1 : 1
        sixHours.layout.root.calculate(parentMtx: matrix_identity_float4x4, parentAlpha: 255)
        for (i, col) in ["a", "b", "c", "d"].enumerated() {
            if let p = sixHours.pane("icon_\(col)"), i < d.slots.count {
                let code = d.slots[i]
                let sp = sprites.screenPoint(SpriteText.layoutCenter(p))
                if code != 0xFFFF, let w = record?.weather(code) { sprites.drawWeatherIcon(code: w.icon, center: sp, alpha: a, scale: 0.7, enc) }
                else { sprites.drawWeatherIcon(code: 0x7FFF, center: sp, alpha: a, scale: 0.7, enc) }
            }
            if let p = sixHours.pane("text_icon_\(col)USA") ?? sixHours.pane("text_icon_\(col)"), i < d.precipitation.count, let f = telopFont {
                let sp = sprites.screenPoint(SpriteText.layoutCenter(p))
                let v = d.precipitation[i]
                let s = v == 0xFF ? "--%" : "\(v)%"
                telop.drawFitted(s, font: f, at: sp, maxSize: SIMD2(p.size.x * k, p.size.y), scale: SIMD2(1, 1), flags: 0x111,
                                 color: SIMD4(255, 255, 255, a), shadow: SIMD4(0x20, 0x20, 0x20, a), enc)
            }
        }
    }
}
