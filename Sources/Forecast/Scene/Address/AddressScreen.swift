import Foundation
import Metal
import NW4R
import RVL
import simd

/// CAddress (d_weather_address.cpp, CAddress_ctor fn_80014B40 … CAddress_StConfirm fn_80016F4C).
/// City list (StList) for the current region with a trailing "other regions" row, region list (StList2),
/// globe fly-to (fn_800172A0) and the "is this location correct?" confirm (set_area2).
public final class AddressScreen: Screen {
    let ctx: SceneContext
    let around: AroundScreen
    let base: UILayout        // +10
    let list: UILayout        // +14 set_area1
    let confirm: UILayout     // +18 set_area2
    var active: UILayout      // +C

    /// One list row (0x48-byte item).
    struct Row {
        var place: Place?            // +8 (nil = the "other regions" row)
        var cityText: [UInt16]       // +C
        var regionText: [UInt16]     // +10
        var cityScale: Float         // +24
        var regionScale: Float       // +2C
        var y: Float = 0             // +18
        var hovered = false          // +44
        var wasHovered = false       // +45
        var hidden = false           // +46
        var rect = SIMD4<Float>(0, 0, 0, 0) // +34..+40 x0,y0,x1,y1 (screen, y down)
    }
    var items: [Row] = []            // all places of the country
    var rows: [Row] = []             // current list (+8 chain)
    var regionKey: UInt32 = 0        // +138
    var otherRegionsText: [UInt16] = []   // +BC  (lbl_80199428[lang])

    // Scrolling (+FC current offset, +128 target, +148 index, +144 max index), list geometry
    var scroll: Float = 0, scrollTarget: Float = 0
    var index = 0, maxIndex = 0
    let rowHeight: Float = 60        // +11C
    /// +118 / +120 and +124 (100 / 393 on the Wii). iPhone portrait: the list runs from just below the header box
    /// (moved to the top) to just above the bottom button row, keeping the original 32 / 30 px gaps.
    var listTop: Float { PortraitArrange.on ? PortraitSlots.pixelY(160 + PortraitSlots.topRowShift) + 32 : 100 }
    var listBottom: Float { PortraitArrange.on ? PortraitSlots.pixelY(-195 + PortraitSlots.bottomRowShift) - 30 : 393 }
    /// Rows that fit the list band (4 on the Wii → the original maxIndex = count − 3).
    var visibleRows: Int { max(1, Int((listBottom - listTop) / rowHeight)) }
    // iPhone touch scrolling (follow the finger, fling, then the original snap rule).
    var touchActive = false, touchInList = false, touchDragging = false, flinging = false
    var touchTravel: Float = 0, flingVel: Float = 0, flingDir: Float = 0
    var dragging = false             // +15E
    var dragVel: Float = 0           // +134

    public enum State { case idle, cityList, regionList, flyTo, confirm }
    public private(set) var state: State = .idle   // PTMF +2C
    var step = 0                                   // +14C
    var wait = 0                                   // +154
    var reqUp = false, reqDown = false, holdB = false, reqYes = false, reqNo = false   // +158..+15C
    var backEnabledInRegionList = true             // +15D
    var candidate: Place?                          // +4
    public var firstRun = true                     // !lbl_80330A09
    var drawer: SceneDraw2D?

    public init(ctx: SceneContext, around: AroundScreen) throws {
        self.ctx = ctx; self.around = around
        base = try ctx.layout("base.brlyt")
        list = try ctx.layout("set_area1.brlyt")
        confirm = try ctx.layout("set_area2.brlyt")
        active = list
        // iPhone portrait: list header under the safe area, the list filling the band, Back/▼/▲ in the bottom row;
        // the confirm dialog stays one centred group over the globe.
        PortraitArrange.stretchBackgrounds(base)
        PortraitArrange.place(list, top: ["text"], bottom: ["back", "down", "up", "blank"])
        PortraitArrange.extendBodies(list, ["back", "down", "up", "blank"], toTop: false)
        // "Other regions" row label: wide string table lbl_80199428 indexed by language (read from main.dol).
        if let dol = try? ctx.assets.title.content(index: Assets.Content.mainDol.rawValue) {
            let img = DOLImage(dol), r = BEReader(dol)
            if var o = img.offset(img.u32(0x8019_9428 + UInt32(ctx.lang.rawValue) * 4)) {
                while o + 1 < dol.count, r.u16(o) != 0, otherRegionsText.count < 64 { otherRegionsText.append(r.u16(o)); o += 2 }
            }
        }
        buildItems()
    }

    var width: Float { ctx.screenWidth }
    var textMaxWidth: Float { width - (ctx.isWide ? 0x24 : 0x1C) * 2 }

    /// CAddress_ctor item setup: per place, the city text and the region text (region, else country, else city),
    /// each scaled to fit the list width.
    func buildItems() {
        items = []
        guard let places = ctx.data?.forecast.places, let font = Message.systemFont(ctx) else { return }
        for p in places where p.id.country == ctx.countryCode {
            let city = Array(p.city.utf16)
            let regionStr = p.region ?? p.country ?? p.city
            let region = Array(regionStr.utf16)
            let cw = SceneDraw2D.stringWidth(city, font: font), rw = SceneDraw2D.stringWidth(region, font: font)
            items.append(Row(place: p, cityText: city, regionText: region,
                             cityScale: cw > textMaxWidth ? textMaxWidth / cw : 1,
                             regionScale: rw > textMaxWidth ? textMaxWidth / rw : 1))
        }
    }

    // MARK: entering

    /// fn_80015340 reset + fn_800154C8: start in the city list of the user's region, else the region list.
    public func start() {
        buildItems()
        base.reset(); list.reset(); confirm.reset()
        regionKey = ctx.locationID.raw & 0xFFFF_0000
        if items.contains(where: { $0.place!.id.raw & 0xFFFF_0000 == regionKey }) { enterCityList() } else { enterRegionList() }
    }

    /// fn_8001576C: rows = places in `regionKey` + the "other regions" row; returns the user's row index.
    func buildCityRows() -> Int {
        rows = items.filter { $0.place!.id.raw & 0xFFFF_0000 == regionKey }
        var y = 0.5 * rowHeight
        for i in rows.indices { rows[i].y = y; y += rowHeight }
        if let font = Message.systemFont(ctx) {
            let w = SceneDraw2D.stringWidth(otherRegionsText, font: font)
            var other = Row(place: nil, cityText: otherRegionsText, regionText: otherRegionsText,
                            cityScale: w > textMaxWidth ? textMaxWidth / w : 1, regionScale: 1)
            other.y = y
            rows.append(other)
        }
        maxIndex = rows.count - visibleRows + 1
        return rows.firstIndex { $0.place?.id == ctx.locationID } ?? 0
    }

    /// fn_800158D0: one row per region (first place of each region), in data order.
    func buildRegionRows() -> Int {
        var seen = Set<UInt32>(); rows = []
        for it in items where !seen.contains(it.place!.id.raw & 0xFFFF_0000) {
            seen.insert(it.place!.id.raw & 0xFFFF_0000); rows.append(it)
        }
        var y = 0.5 * rowHeight
        for i in rows.indices { rows[i].y = y; y += rowHeight }
        maxIndex = rows.count - visibleRows + 1
        return rows.firstIndex { $0.place!.id.raw & 0xFFFF_0000 == regionKey } ?? 0
    }

    /// CAddress_StList step 0
    func enterCityList() {
        state = .cityList; step = 1; active = list
        index = min(max(buildCityRows(), 0), max(maxIndex - 1, 0))
        scrollTarget = -(rowHeight * Float(index)); scroll = scrollTarget
        if let back = list.find("back") {
            if firstRun { back.disabled = true; back.press() } else { back.disabled = false }
        }
        list.find("text").map { $0.textIndex = 0; $0.pendingTextIndex = 0 }
    }

    /// CAddress_StList2 step 0
    func enterRegionList() {
        state = .regionList; step = 1; active = list
        index = min(max(buildRegionRows(), 0), max(maxIndex - 1, 0))
        scrollTarget = -(rowHeight * Float(index)); scroll = scrollTarget
        backEnabledInRegionList = !firstRun || items.contains { $0.place!.id.raw & 0xFFFF_0000 == ctx.locationID.raw & 0xFFFF_0000 }
        list.find("back")?.disabled = !backEnabledInRegionList
        list.find("text").map { $0.textIndex = 1; $0.pendingTextIndex = 1 }
    }

    // MARK: frame

    /// CAddress_UpdateButtons (fn_80015668)
    func updateButtons() {
        reqUp = false; reqDown = false; reqYes = false; reqNo = false
        ctx.ui.updateHover(active, ctx.pad)
        holdB = ctx.pad.hold.contains(.b)
        if !holdB {
            if ctx.ui.buttonTrig("down", ctx.pad) { reqDown = true }
            else if ctx.pad.trig.contains(.down) { reqDown = true; list.find("down")?.flash() }
            if ctx.ui.buttonTrig("up", ctx.pad) { reqUp = true }
            else if ctx.pad.trig.contains(.up) { reqUp = true; list.find("up")?.flash() }
        }
        if ctx.ui.buttonTrig("yes", ctx.pad) { reqYes = true }
        if ctx.ui.buttonTrig("no", ctx.pad) { reqNo = true }
    }

    /// fn_80015EFC (button scrolling) / fn_8001611C (B-drag scrolling)
    func updateScroll() {
        if PortraitArrange.on, touchScroll() { return }
        GlobeMath.chaseValue(&scroll, scrollTarget, 0.1, 20, 5)
        // fn_8001611C (B held): step 0 plays SE 0x16 and raises +15E; each frame the speed +134 = 0.1·v where
        // v = 228 − pointer y with a ±20 dead zone (fn_80035C28, lbl_801F72B8), the cursor shows the scroll
        // sprite (lbl_801D6F98 = 4) and +FC moves by the speed, clamped to [−row·(n−1), 0].
        if maxIndex > 1 && holdB {
            if !dragging { dragging = true; dragVel = 0; ctx.playSE(0x16) }
            let v = 228 - ctx.pad.pointer.y
            dragVel = (v < 20 && v > -20) ? 0 : 0.1 * v
            let top: Float = 0, bottom = -(rowHeight * Float(maxIndex - 1))
            scroll = min(top, max(bottom, scroll + dragVel))
            scrollTarget = scroll
            return
        }
        if dragging {
            // case −1 on leaving: nearest row in the scroll direction becomes the target (+128).
            dragging = false
            index = dragVel < 0 ? Int((-scroll + rowHeight) / rowHeight) : Int(-scroll / rowHeight)
            index = min(max(index, 0), max(maxIndex - 1, 0))
            dragVel = 0
        }
        if reqDown && maxIndex > 1 && index < maxIndex - 1 { index += 1; ctx.playSE(0x30) }
        else if reqUp && index > 0 { index -= 1; ctx.playSE(0x30) }
        if index == 0 { list.find("up")?.disabled = true } else { list.find("up")?.disabled = false }
        if maxIndex <= 0 || index == maxIndex - 1 { list.find("down")?.disabled = true } else { list.find("down")?.disabled = false }
        scrollTarget = -(rowHeight * Float(index))
    }

    /// iPhone: one finger dragged in the list moves it directly; on release it keeps the finger's speed, decays,
    /// then snaps like the original's B-scroll exit (nearest row in the travel direction). Returns true while the
    /// touch owns the scroll (the button/snap path is skipped that frame).
    func touchScroll() -> Bool {
        let g = ctx.gestures, pad = ctx.pad
        let bottom = -(rowHeight * Float(max(maxIndex - 1, 0)))
        if pad.pointerValid && g.fingers == 1 {
            if !touchActive {
                touchActive = true; touchTravel = 0; touchDragging = false; flinging = false
                touchInList = pad.pointer.y > listTop && pad.pointer.y < listBottom
            }
            guard touchInList, maxIndex > 1 else { return false }
            touchTravel += abs(g.dragY)
            if !touchDragging && touchTravel > 18 { touchDragging = true }
            guard touchDragging else { return false }
            scroll = min(0, max(bottom, scroll + g.dragY))
            scrollTarget = scroll
            flingVel = g.dragY
            if abs(g.dragY) > 0.5 { flingDir = g.dragY < 0 ? -1 : 1 }
            return true
        }
        touchActive = false
        if touchDragging { touchDragging = false; flinging = true }
        guard flinging else { return false }
        flingVel *= 0.92
        scroll = min(0, max(bottom, scroll + flingVel))
        scrollTarget = scroll
        if abs(flingVel) < 1 || scroll <= bottom || scroll >= 0 {
            flinging = false
            index = flingDir < 0 ? Int((-scroll + rowHeight) / rowHeight) : Int(-scroll / rowHeight)
            index = min(max(index, 0), max(maxIndex - 1, 0))
            return false
        }
        return true
    }

    /// Row rects + hover (fn_800164F0 / fn_8001673C first loop, fn_80017368 hit test). Returns the chosen row.
    func updateRows() -> Int? {
        var chosen: Int? = nil
        for i in rows.indices {
            rows[i].wasHovered = rows[i].hovered; rows[i].hovered = false
            let y0 = rows[i].y + (scroll + listTop) - 20
            rows[i].rect = SIMD4(0, y0, width, y0 + 40)
            rows[i].hidden = y0 + 40 < 0 || y0 > listBottom
        }
        guard ctx.pad.pointerValid, !dragging, !touchDragging, !flinging else { return nil }
        let p = ctx.pad.pointer
        guard p.y > listTop, p.y < listBottom else { return nil }
        for i in rows.indices where !rows[i].hidden {
            let r = rows[i].rect
            if p.x > r.x && p.x < r.z && p.y > r.y && p.y < r.w {
                rows[i].hovered = true
                if !rows[i].wasHovered { ctx.playSE(0x2E) }
                if ctx.pad.trig.contains(.a) { chosen = i }
            }
        }
        return chosen
    }

    public func calc() {
        base.update(); list.update(); confirm.update()
        switch state {
        case .idle: break
        case .cityList:
            updateButtons()
            if step == 1 {
                if !firstRun, ctx.ui.buttonTrig("back", ctx.pad) {
                    list.find("back")?.keepPressed = true
                    ctx.playSE(0x26); ctx.request = 4; step = 2
                } else if let i = updateRows() {
                    if let p = rows[i].place {
                        ctx.playSE(0x24)
                        candidate = p; beginFlyTo()
                    } else {
                        ctx.playSE(0x2F)
                        enterRegionList()
                    }
                }
                updateScroll()
            }
        case .regionList:
            updateButtons()
            if step == 1 {
                if backEnabledInRegionList, ctx.ui.buttonTrig("back", ctx.pad) {
                    list.find("back")?.keepPressed = true
                    ctx.playSE(0x26); wait = 0x14; step = 2
                } else if let i = updateRows() {
                    regionKey = rows[i].place!.id.raw & 0xFFFF_0000
                    ctx.playSE(0x23)
                    enterCityList()
                }
                updateScroll()
            } else if step == 2 {
                if wait > 0 { wait -= 1 } else { regionKey = ctx.locationID.raw & 0xFFFF_0000; enterCityList() }
            }
        case .flyTo:
            // fn_800172A0: the globe flies to the candidate (CAround/SimpleGlobe), then confirm.
            animateGlobe()
            if wait > 0 { wait -= 1 } else { enterConfirm() }
        case .confirm:
            updateButtons()
            animateGlobe()
            if step == 1 {
                if reqYes {
                    ctx.playSE(0x25); step = 2; wait = 0
                    confirm.find("yes")?.keepPressed = true
                    if let c = candidate { ctx.locationID = c.id }
                    ctx.request = 2
                }
                if reqNo {
                    ctx.playSE(0x26); step = 3; wait = 0xC
                    confirm.find("no")?.keepPressed = true
                }
            } else if step == 3 {
                if wait > 0 { wait -= 1 } else { enterCityList() }
            }
        }
    }

    /// Globe camera/material update only (fn_80018BE0 subset) — no CAround input while CAddress owns the pointer.
    func animateGlobe() {
        let g = ctx.globeScene.globe
        g.updateZoom(); g.syncDist(); g.updateTilt()
        g.calcCamera(materials: &ctx.globeScene.earth.materials)
        g.calcPoles(); g.updateLight()
    }

    func beginFlyTo() {
        state = .flyTo; step = 0; wait = 40
        if let c = candidate { around.enterForAddress(c.id) }
    }

    /// CAddress_StConfirm step 0
    func enterConfirm() {
        state = .confirm; step = 1; active = confirm
        confirm.reset()
        scroll = 0; scrollTarget = 0
    }

    /// fn_800101C0 input: the scroll sprite while B-scrolling the list.
    public var cursorState: Cursor.State { dragging ? .scroll : .normal }

    public var showsGlobe: Bool { state == .flyTo || state == .confirm }

    /// fn_80015380 + row drawing (fn_80015A58 city rows / fn_80015C10 region rows)
    public func draw(_ enc: MTLRenderCommandEncoder) {
        if showsGlobe {
            around.drawGlobe(enc)
            if state == .confirm { confirm.draw(ctx.lyt, enc) }
            return
        }
        base.draw(ctx.lyt, enc)
        if let d2 = drawer, let font = Message.systemFont(ctx) {
            let a = Float(list.layoutAlpha) / 255
            if PortraitArrange.on {
                enc.setScissorRect(scissor(0, listTop + 3, width, LogicalScreen.height - (listTop + 3)))
            } else {
                enc.setScissorRect(scissor(0, 0x67, width, 0x161))
            }
            for r in rows where !r.hidden {
                let c: SIMD4<UInt8> = r.hovered ? SIMD4(0x8C, 0xB4, 0xB4, 0xFF) : SIMD4(0xFF, 0xFF, 0xFF, 0x40)
                d2.fillRect(r.rect.x, r.rect.y, r.rect.z, r.rect.w, color: SIMD4(c.x, c.y, c.z, UInt8(Float(c.w) * a)), enc)
            }
            for r in rows where !r.hidden {
                let txt = state == .regionList ? r.regionText : r.cityText
                let sc = state == .regionList ? r.regionScale : r.cityScale
                d2.text(txt, font: font, x: width * 0.5, y: r.y + scroll + listTop, scale: SIMD2(sc, 1),
                        color: SIMD4(255, 255, 255, UInt8(255 * a)), enc)
            }
            enc.setScissorRect(scissor(0, 0, width, LogicalScreen.height))
        }
        list.draw(ctx.lyt, enc)
    }

    /// Screen-space scissor (logical 0..W × 0..456 → drawable pixels) — provided by WeatherScene.
    var scissor: (Float, Float, Float, Float) -> MTLScissorRect = { _, _, _, _ in MTLScissorRect(x: 0, y: 0, width: 1, height: 1) }
}
