import Foundation
import Metal
import NW4R
import RVL
import simd

/// lbl_803309BC — the records the hub shows for the selected location:
/// {+0 place, +4 long forecast, +8 summary, +C current conditions (short.bin)}.
public struct HubRecord {
    public let place: Place?
    public let long: LongForecast?
    public let summary: SummaryForecast?
    public let current: CurrentWeather?
    public let data: WeatherData

    /// Look up `id` (falls back to the first long-forecast location when the id isn't in the data — preview/test only).
    public static func find(_ data: WeatherData?, _ id: LocationID) -> HubRecord? {
        guard let data else { return nil }
        let f = data.forecast
        var loc = id
        if f.place(loc) == nil, let first = f.longForecasts.first?.location { loc = first }
        return HubRecord(place: f.place(loc), long: f.longForecasts.first { $0.location == loc },
                         summary: f.summaries.first { $0.location == loc }, current: data.short.current.first { $0.location == loc },
                         data: data)
    }

    /// ForecastFindById → (icon/display code, name)
    public func weather(_ code: UInt16) -> (icon: UInt16, name: String)? {
        guard code != 0xFFFF, let t = data.forecast.weatherTypes.first(where: { $0.code == code }) else { return nil }
        return (t.displayCode, t.name)
    }
}

/// Strings that live in main.dol (wind direction / unit names), read at runtime from the user's own DOL.
final class DOLStrings {
    let dol: DOLImage
    init(_ assets: Assets) throws { dol = DOLImage(try assets.title.content(index: Assets.Content.mainDol.rawValue)) }

    func wstring(_ address: UInt32) -> String {
        guard address != 0, let o = dol.offset(address) else { return "" }
        let r = BEReader(dol.bytes)
        var u: [UInt16] = []
        var p = o
        while p + 1 < dol.bytes.count { let c = r.u16(p); if c == 0 { break }; u.append(c); p += 2 }
        return String(utf16CodeUnits: u, count: u.count)
    }
    /// Wind direction names: lbl_801994D8 (region US) / lbl_80199748 (EU), [lang][dir 0..16] (stride 0x44).
    func windDirection(_ dir: UInt8, lang: Int, region: Int) -> String {
        let base: UInt32 = region == 1 ? 0x8019_94D8 : 0x8019_9748
        return wstring(dol.u32(base + UInt32(lang) * 0x44 + UInt32(dir) * 4))
    }
    /// Wind unit names: lbl_801999B0 (US) / lbl_80199A70 (EU), [lang][unit].
    func windUnit(_ unit: Int, lang: Int, region: Int) -> String {
        let base: UInt32 = region == 1 ? 0x8019_99B0 : 0x8019_9A70
        return wstring(dol.u32(base + UInt32(lang) * 8 + UInt32(unit) * 4))
    }
    /// Weekday sprite (TPLCommon image) for lang/wday: lbl_80179CFC + lang·0x1C + wday·4.
    func weekdayImage(_ wday: Int, lang: Int) -> Int { Int(dol.u32(0x8017_9CFC + UInt32(lang) * 0x1C + UInt32(wday) * 4)) }
}

/// Common page object (fn_8001C334 base ctor; vtable {dtor, init, ?, ?, draw +0x10, calc +0x14, isAvailable +0x18}).
class HubPage {
    let ctx: SceneContext
    let hub: NormalScreen
    let layout: UILayout           // +04
    let noService: UILayout        // +A0 (life_no_service.brlyt)
    let titleIndex: Int            // +8C (belt title)
    let scrollTarget: Float        // +14 (456·index)
    var offset = SIMD2<Float>(0, 0) // +08/+0C
    var alphaFactor: Float = 1     // +88
    var alpha: Float = 255         // +94
    var anchors: [String: SIMD2<Float>] = [:]   // screen-space (y down) for offset 0
    var rects: [String: SIMD4<Float>] = [:]     // bounding panes: centre x,y + w,h (screen space)
    /// iPhone portrait: per-anchor sprite scale multipliers (icons / numbers drawn bigger in the taller band).
    var portraitScale: [String: Float] = [:]
    /// iPhone portrait: icons fitted (by their layer bounds) into a box and centred on their anchor.
    var portraitIconBox: [String: SIMD2<Float>] = [:]
    /// iPhone portrait: draw-flag overrides for telops (e.g. the wind text centred instead of right-aligned).
    var portraitFlags: [String: Int] = [:]
    var bandCentre: Float = 0
    var windY: Float = .nan

    init(_ hub: NormalScreen, layout name: String, index: Int, title: Int) throws {
        self.hub = hub; ctx = hub.ctx
        layout = try ctx.layout(name)
        noService = try ctx.layout("life_no_service.brlyt")
        titleIndex = title
        scrollTarget = hub.pageSpacing * Float(index)
        if ctx.isPortrait {
            let c = hub.portrait.bandCentre
            noService.placeAll(SIMD2(0, c))
            arrangePortrait(centre: c)
        }
        // Pane_GetScreenCenter for every empty anchor / bounding pane.
        let k: Float = ctx.isWide ? 1.368_421_1 : 1
        layout.layout.root.calculate(parentMtx: matrix_identity_float4x4, parentAlpha: 255)
        layout.layout.root.forEach { p in
            let c = hub.sprites.screenPoint(SpriteText.layoutCenter(p))
            anchors[p.name] = c
            if p is Bounding { rects[p.name] = SIMD4(c.x, c.y, p.size.x * k, p.size.y) }
        }
        if ctx.isPortrait { for n in ["telop", "wind_telop"] { widenRect(n, to: 560) } }
    }

    /// iPhone portrait arrangement of this page's panes around the content band centre `c` (layout space).
    func arrangePortrait(centre c: Float) {}

    /// Move a root pane group to an absolute layout position (portrait).
    func moveTo(_ name: String, _ x: Float?, _ y: Float) {
        guard let p = layout.find(name) else { return }
        let a = p.authored   // UILayout.place offsets are relative to the brlyt position
        layout.place([name: SIMD2((x ?? a.x) - a.x, y - a.y)])
    }
    /// Shift a nested (non-root) pane and optionally stretch it vertically.
    func nested(_ name: String, y: Float? = nil, scaleY: Float? = nil, x: Float? = nil, scale: Float? = nil) {
        guard let p = layout.pane(name) else { return }
        if let y { p.translate.y = y }
        if let x { p.translate.x = x }
        if let scaleY { p.scale.y *= scaleY }
        if let scale { p.scale *= scale }
        layout.relayout()
    }
    func k(_ name: String) -> Float { portraitScale[name] ?? 1 }

    /// Anchor in screen space with this page's scroll offset applied (sp10 = x + unk8, sp14 = y − unkC).
    func at(_ name: String) -> SIMD2<Float>? {
        guard var a = anchors[name] else { return nil }
        if let y = yOverride[name] { a.y = LogicalScreen.halfHeight - y }
        return SIMD2(a.x + offset.x, a.y - offset.y)
    }
    /// iPhone portrait: per-frame layout-space y for anchors/rects (the day pages re-flow around the icon's size).
    var yOverride: [String: Float] = [:]
    /// Per-frame portrait re-flow hook (called from calc).
    func portraitReflow() {}

    var isAvailable: Bool { true }
    var noServiceIndex: Int { 0 }

    /// vtable +0x14 calc
    func calc(offset o: SIMD2<Float>, alphaFactor a: Float) {
        offset = o; alphaFactor = a
        if ctx.isPortrait { portraitReflow() }
        layout.update(); noService.update()
    }

    /// vtable +0x10 draw
    func draw(_ enc: MTLRenderCommandEncoder) {
        let a = alphaFactor * alpha
        guard a > 0, abs(offset.y) < hub.pageSpacing else { return }
        if isAvailable {
            hub.drawLayout(layout, enc, translateY: offset.y, alpha: UInt8(max(0, min(255, a))))
            drawData(enc, alpha: UInt8(max(0, min(255, 255 * alphaFactor))))
        } else {
            noService.find("text")?.textIndex = noServiceIndex
            hub.drawLayout(noService, enc, translateY: offset.y, alpha: UInt8(max(0, min(255, a))))
        }
    }

    func drawData(_ enc: MTLRenderCommandEncoder, alpha: UInt8) {}

    // fn_8001C89C: fitted telop text with shadow in a bounding rect.
    func telop(_ s: String, rect name: String, flags: Int = 0x111, scale: Float = 1, alpha: UInt8, color: SIMD4<UInt8> = SpriteText.white, _ enc: MTLRenderCommandEncoder) {
        guard var r = rects[name], let f = hub.telopFont else { return }
        if let y = yOverride[name] { r.y = LogicalScreen.halfHeight - y }
        let scale = scale * k(name)
        let flags = portraitFlags[name] ?? flags
        var c = color; c.w = alpha
        var sh = SpriteText.shadow; sh.w = alpha
        let hO = (flags >> 4) & 3
        let x = r.x + offset.x + (hO == 0 ? -r.z / 2 : hO == 2 ? r.z / 2 : 0)
        // Width-only fit: in the original (Dolphin reference) single-line telops are never shrunk by the
        // CalcStringHeight branch — "SSE 10 mph" draws at scale 1.0 in the 28 px wind_telop box.
        hub.telop.drawFitted(s, font: f, at: SIMD2(x, r.y - offset.y), maxSize: SIMD2(r.z, .infinity), scale: SIMD2(scale, scale), flags: flags,
                             color: c, shadow: sh, enc)
    }

    /// Temperature-style number: digits (or "--") + optional suffix glyphs (0xFF9F = degree, 'C' / 'F'),
    /// centred on the anchor in the large sprite font (fn_8003F088). Shadow colour lbl_80330A20.
    func number(_ v: Int?, at name: String, scale: Float = 1, color: SIMD4<UInt8> = SpriteText.white, suffix: [UInt16] = [],
                alpha: UInt8, _ enc: MTLRenderCommandEncoder) {
        guard let p = at(name) else { return }
        let scale = scale * k(name)
        var c = color; c.w = alpha
        var sh = SpriteText.shadow; sh.w = alpha
        let s = (v.map { hub.sprites.formatInt($0) } ?? [0x2D, 0x2D]) + suffix
        var q = p
        // fn_800145B8: a single glyph is nudged right by half a digit width (record 0x21).
        if s.count == 1, let r = hub.sprites.records[safe: 0x21] { q.x += scale * 0.5 * r.w }
        // iPhone portrait: optical centring — the digits centre on the anchor and the unit (°) hangs to the right.
        if ctx.isPortrait, !suffix.isEmpty { q.x += scale * 0.5 * hub.sprites.width(suffix, .large) }
        hub.sprites.drawCentered(s, center: q, sx: scale, sy: scale, color: c, shadow: sh, enc)
    }
    /// Degree glyph (+ unit letter for °F) per the do/doF anchor split.
    /// Degree glyph only, for both units (verified against the original in Dolphin: "34°").
    var tempSuffix: [UInt16] { [0xFF9F] }

    func icon(_ code: UInt16?, at name: String, scale: Float = 1, alpha: UInt8, _ enc: MTLRenderCommandEncoder) {
        guard let p = at(name) else { return }
        var scale = scale * k(name)
        let shown = code.flatMap { hub.record?.weather($0)?.icon } ?? 0x7FFF
        var centre = p
        if let box = portraitIconBox[name], let b = hub.sprites.iconBounds(shown) {
            let size = b.max - b.min
            scale = min(box.x / max(size.x, 1), box.y / max(size.y, 1))
            centre = p - (b.min + b.max) / 2 * scale   // the composition's own centre on the anchor
        }
        hub.sprites.drawWeatherIcon(code: shown, center: centre, alpha: alpha, scale: scale, enc)
    }

    /// fn_8001D3C8 / fn_8001E9E8: "<direction> <speed> <unit>" right-aligned in `wind_telop`.
    func windText(direction: UInt8, kmh: UInt8, mph: UInt8) -> String? {
        guard direction != 0xFF else { return nil }
        let speed = ctx.windUnit == 0 ? mph : kmh
        let dir = hub.strings.windDirection(direction, lang: ctx.lang.rawValue, region: ctx.region)
        let unit = hub.strings.windUnit(ctx.windUnit, lang: ctx.lang.rawValue, region: ctx.region)
        if direction == 0 { return dir }                     // calm
        return speed == 0xFF ? "\(dir) -- \(unit)" : "\(dir) \(speed) \(unit)"
    }
}

/// Page 0 — UV index (d_weather_a_other.cpp, life_nWW.brlyt; fn_8001199C).
final class UVPage: HubPage {
    var day: DayForecast? { hub.record?.long?.today ?? hub.record?.summary?.today }
    var uv: IndexText? {
        guard let d = day, d.uvIndex != 0xFF else { return nil }
        return hub.record?.data.forecast.uvIndex.first { $0.id == d.uvIndex }
    }
    override var isAvailable: Bool { hub.record?.long != nil && uv != nil }
    override var noServiceIndex: Int { hub.record?.long == nil ? 0 : 5 }
    /// Portrait: the sun-and-sunglasses picture moves above the "UV Index" box (×1.6); the box keeps its art.
    override func arrangePortrait(centre c: Float) {
        // The UV box group is authored at x = +40: shift everything 40 left so the box is centred, and stack the
        // sun-and-sunglasses picture (×2.6) above it; the pair is centred vertically in the band.
        let sunH: Float = 112 * 2.6, boxH: Float = 147, gap: Float = 46
        let top = c + (sunH + gap + boxH) / 2
        let sunY = top - sunH / 2, headerTop = top - sunH - gap
        let groupY = headerTop - 18                      // life_bB0 header (36 tall) is centred on life_b
        layout.placeAll(SIMD2(-40, groupY - 39))
        nested("life_bI", y: sunY - groupY, x: 0, scale: 2.6)
        portraitScale = ["life_b_1-1": 1.25, "life_b_1-10": 1.25, "life_b_1-100": 1.25]
    }
    override func drawData(_ enc: MTLRenderCommandEncoder, alpha: UInt8) {
        guard let uv else { return }
        telop(uv.text, rect: "life_b_telop", alpha: alpha, enc)
        // UV value: digits on the life_b_1-1 / -10 / -100 anchors (ones, tens, hundreds).
        let v = Int(uv.id)
        let digits = String(v).compactMap { Int(String($0)) }
        let names = ["life_b_1-1", "life_b_1-10", "life_b_1-100"]
        for (i, d) in digits.reversed().enumerated() where i < names.count { number(d, at: names[i], alpha: alpha, enc) }
    }
}

/// Portrait arrangement of day_nWW (Current / Today / Tomorrow): one centred column that fills the content
/// band — weather icon (fitted into 460×300 by its own layer bounds, so a small moon reads as large as a cloud
/// bank), temperature ×2.3, condition ×1.7, and the wind strip widened into a full-width ribbon with the wind text
/// centred on it. The column re-flows every frame around the icon's real height so the gaps stay even.
func arrangeDayPortrait(_ p: HubPage, centre c: Float) {
    p.bandCentre = c
    p.moveTo("icon", 0, c); p.moveTo("kion_do_cnt", 0, c); p.moveTo("kion_doF_cnt", 0, c); p.moveTo("telop", 0, c)
    p.moveTo("belt_wind", 304, c); p.moveTo("wind_telop", 120, c)   // wind_telop: o=5, 240 wide → centre x = 0
    // belt_windB spans −280…0 from the right screen edge (solid 200 + fade 80): stretch it across the width.
    p.nested("belt_windB", scaleY: 1.4)
    if let b = p.layout.pane("belt_windB") { b.scale.x = 608 / 280; p.layout.relayout() }
    p.portraitScale = ["kion_do_cnt": 2.3, "kion_doF_cnt": 2.3, "telop": 1.7, "wind_telop": 1.4]
    p.portraitIconBox = ["icon": SIMD2(420, 255)]
    p.portraitFlags = ["wind_telop": 0x111]
}

/// The day-page column for an icon of display code `shown`: icon, gap, temperature, gap, condition, gap, wind.
func reflowDayPortrait(_ p: HubPage, iconCode: UInt16?) {
    let shown = iconCode.flatMap { p.hub.record?.weather($0)?.icon } ?? 0x7FFF
    var iconH: Float = 260
    if let b = p.hub.sprites.iconBounds(shown), let box = p.portraitIconBox["icon"] {
        let s = b.max - b.min
        iconH = s.y * min(box.x / max(s.x, 1), box.y / max(s.y, 1))
    }
    let tempH: Float = 142, condH: Float = 48, windH: Float = 53
    let gaps: [Float] = [56, 36, 58]
    let total = iconH + tempH + condH + windH + gaps.reduce(0, +)
    var y = p.bandCentre + total / 2
    func next(_ h: Float, _ gap: Float) -> Float { let m = y - h / 2; y -= h + gap; return m }
    let iconY = next(iconH, gaps[0]), tempY = next(tempH, gaps[1]), condY = next(condH, gaps[2]), windY = next(windH, 0)
    p.yOverride = ["icon": iconY, "kion_do_cnt": tempY, "kion_doF_cnt": tempY, "telop": condY, "wind_telop": windY + 1]
    if p.windY != windY {
        p.windY = windY
        p.moveTo("belt_wind", 304, windY)
    }
}

/// Widen bounding rects used for fitting telops (portrait text is larger and centred).
extension HubPage {
    func widenRect(_ name: String, to w: Float) { if var r = rects[name] { r.z = w; rects[name] = r } }
}

/// Page 1 — current conditions (fn_80010B7C module, day_nWW.brlyt; fn_80010EB0).
final class CurrentPage: HubPage {
    override var isAvailable: Bool { hub.record?.current != nil && hub.record?.current?.weather != 0xFFFF }
    override var noServiceIndex: Int { 1 }
    override func arrangePortrait(centre c: Float) { arrangeDayPortrait(self, centre: c) }
    override func portraitReflow() { reflowDayPortrait(self, iconCode: hub.record?.current?.weather) }
    override func drawData(_ enc: MTLRenderCommandEncoder, alpha: UInt8) {
        guard let cur = hub.record?.current else { return }
        icon(cur.weather, at: "icon", alpha: alpha, enc)
        if let w = hub.record?.weather(cur.weather) { telop(w.name, rect: "telop", alpha: alpha, enc) }
        if let s = windText(direction: cur.windDirection, kmh: cur.windKmh, mph: cur.windMph) {
            telop(s, rect: "wind_telop", flags: 0x122, alpha: alpha, enc)
        }
        if ctx.tempUnit == 0 { number(cur.tempC <= -128 ? nil : Int(cur.tempC), at: "kion_do_cnt", suffix: tempSuffix, alpha: alpha, enc) }
        else { number(cur.tempF <= -128 ? nil : Int(cur.tempF), at: ctx.region == 1 ? "kion_doF_cnt" : "kion_do_cnt", suffix: tempSuffix, alpha: alpha, enc) }
    }
}

/// Pages 2/3 — today / tomorrow (d_weather_base_day.cpp, day_nWW.brlyt; fn_800126B4 → fn_8001E10C).
final class DayPage: HubPage {
    let tomorrow: Bool
    init(_ hub: NormalScreen, index: Int, tomorrow: Bool) throws {
        self.tomorrow = tomorrow
        try super.init(hub, layout: "day_nWW.brlyt", index: index, title: index)
    }
    var day: DayForecast? {
        let r = hub.record
        return tomorrow ? (r?.long?.tomorrow ?? r?.summary?.tomorrow) : (r?.long?.today ?? r?.summary?.today)
    }
    override var isAvailable: Bool { day.map { $0.weather != 0xFFFF } ?? false }
    override var noServiceIndex: Int { tomorrow ? 3 : 2 }
    override func arrangePortrait(centre c: Float) { arrangeDayPortrait(self, centre: c) }
    override func portraitReflow() { reflowDayPortrait(self, iconCode: day?.weather) }
    override func drawData(_ enc: MTLRenderCommandEncoder, alpha: UInt8) {
        guard let d = day else { return }
        icon(d.weather, at: "icon", alpha: alpha, enc)
        if let w = hub.record?.weather(d.weather) { telop(w.name, rect: "telop", alpha: alpha, enc) }
        if let s = windText(direction: d.windDirection, kmh: d.windKmh, mph: d.windMph) {
            telop(s, rect: "wind_telop", flags: 0x122, alpha: alpha, enc)
        }
        // fn_8001230C: non-JP day pages colour the temperature anchors lbl_80330A40.
        let col = ctx.lang == .jp ? SpriteText.white : SpriteText.yellow
        if ctx.tempUnit == 0 { number(d.highC <= -128 ? nil : Int(d.highC), at: "kion_do_cnt", color: col, suffix: tempSuffix, alpha: alpha, enc) }
        else { number(d.highF <= -128 ? nil : Int(d.highF), at: ctx.region == 1 ? "kion_doF_cnt" : "kion_do_cnt", color: col, suffix: tempSuffix, alpha: alpha, enc) }
    }
}

/// Page 4 — 5-day (d_weather_a_week.cpp, week_nWW.brlyt; fn_800145B8). Columns a..e start at tomorrow
/// (entry time + 0x5A0 minutes per column) and read week[0..4].
final class WeekPage: HubPage {
    override var isAvailable: Bool { hub.record?.long != nil }
    override var noServiceIndex: Int { 4 }
    /// Portrait: the five columns stretch vertically (body ×2.6 below the weekday header, dividers spanning header
    /// top → body bottom), icons fitted to the column width, numbers ×1.45, rows at 22 / 56 / 84 % of the body.
    override func arrangePortrait(centre c: Float) {
        // Column art (relative to week_x at the weekday header): header B0 40 tall at 0 (+20…−20), body B1 184 tall
        // centred −112 (−20…−204), left divider B3 224 tall centred −92 (+20…−204). Stretch the body ×f downward from
        // the header's bottom edge and make the divider span exactly header top → body bottom.
        // Original rows sit at 41 / 109 / 159 of the 184-tall body (icon y 13, high −55, low −105 vs header 74,
        // body top 54): fractions 0.22 / 0.59 / 0.86 — kept, with a ×2 stretch so gaps grow with the type.
        let f: Float = 2.0, head: Float = 74
        let bodyH = 184 * f
        let colTop: Float = 20, colBottom = 20 + bodyH          // below/above the header anchor
        let dy = (c + (colBottom - colTop) / 2) - head          // centre the whole column in the band
        func inBody(_ frac: Float) -> Float { head + dy - 20 - bodyH * frac }
        for col in ["a", "b", "c", "d", "e"] {
            moveTo("week_\(col)", nil, head + dy)
            moveTo("week_\(col)_youbi", nil, head + dy)
            moveTo("week_\(col)_icon", nil, inBody(41.0 / 184))
            for n in ["H_do_cnt", "H_cnt"] { moveTo("week_\(col)\(n)", nil, inBody((159.0 / 184 * bodyH - 50 * 1.6) / bodyH)) }   // original 50-unit high→low gap, at the ×1.6 type size
            for n in ["L_do_cnt", "L_cnt"] { moveTo("week_\(col)\(n)", nil, inBody(159.0 / 184)) }
            nested("week_\(col)B1", y: -20 - bodyH / 2, scaleY: f)
            nested("week_\(col)B3", y: (20 + (-20 - bodyH)) / 2, scaleY: (40 + bodyH) / 224)
            portraitIconBox["week_\(col)_icon"] = SIMD2(110 - 1 - 2 * 6, 90)   // column inner width − 6 px padding each side
            for n in ["H_do_cnt", "H_cnt", "L_do_cnt", "L_cnt"] { portraitScale["week_\(col)\(n)"] = 1.6 }
        }
    }
    override func drawData(_ enc: MTLRenderCommandEncoder, alpha: UInt8) {
        guard let long = hub.record?.long else { return }
        let cols = ["a", "b", "c", "d", "e"]
        var minutes = long.time.localTime &+ 0x5A0
        for (i, col) in cols.enumerated() where i < long.week.count {
            let w = long.week[i]
            let hi = ctx.tempUnit == 0 ? w.highC : w.highF, lo = ctx.tempUnit == 0 ? w.lowC : w.lowF
            let suffix = ctx.tempUnit == 0 ? "_do_cnt" : "_cnt"
            // fn_80013738 anchor table (names lbl_8019A268+0x498, scales lbl_801797B8): numbers/icons 0.5;
            // high → lbl_80330A40, low → lbl_80330A3C; °C anchors (_do_cnt) carry the degree glyph.
            let deg: [UInt16] = ctx.tempUnit == 0 ? [0xFF9F] : []
            number(hi <= -128 ? nil : Int(hi), at: "week_\(col)H\(suffix)", scale: 0.5, color: SpriteText.yellow, suffix: deg, alpha: alpha, enc)
            number(lo <= -128 ? nil : Int(lo), at: "week_\(col)L\(suffix)", scale: 0.5, color: SpriteText.lightCyan, suffix: deg, alpha: alpha, enc)
            // Weekday sprite (fn_8001C714: TPLCommon image, shadow at +3,+3). Sat/Sun → lbl_80330A40, else lbl_80330A1C.
            let wday = HubDate(minutes: minutes).weekday
            if let p = at("week_\(col)_youbi") {
                let img = hub.strings.weekdayImage(wday, lang: ctx.lang.rawValue)
                var c = (wday == 6 || wday == 0) ? SpriteText.yellow : SpriteText.lightGrey; c.w = alpha
                var sh = SpriteText.shadow; sh.w = alpha
                hub.sprites.drawImageCentered(img, center: p, scale: 1, color: c, shadow: sh, shadowOffset: 3, enc)
            }
            icon(w.weather == 0xFFFF ? nil : w.weather, at: "week_\(col)_icon", scale: 0.5, alpha: alpha, enc)
            minutes &+= 0x5A0
        }
    }
}

/// MinutesToDate (fn_800364D8): minutes since 2000-01-01 00:00; wday = (days + 6) % 7 (2000-01-01 was a Saturday).
struct HubDate {
    let minute: Int, hour: Int, day: Int, month: Int, year: Int, weekday: Int
    init(minutes m: UInt32) {
        let mins = Int(m)
        minute = mins % 60; hour = (mins / 60) % 24
        let days = mins / 1440
        weekday = (days + 6) % 7
        var y = 2000, d = days
        func leap(_ y: Int) -> Bool { (y % 4 == 0 && y % 100 != 0) || y % 400 == 0 }
        while d >= (leap(y) ? 366 : 365) { d -= leap(y) ? 366 : 365; y += 1 }
        let ml = [31, leap(y) ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        var mo = 0
        while d >= ml[mo] { d -= ml[mo]; mo += 1 }
        year = y; month = mo; day = d + 1
    }
}

extension SpriteText {
    /// fn_8001C714: a TPLCommon image centred on `center`, shadow first at +offset.
    func drawImageCentered(_ image: Int, center: SIMD2<Float>, scale: Float, color: SIMD4<UInt8>, shadow: SIMD4<UInt8>, shadowOffset: Float,
                           _ enc: MTLRenderCommandEncoder) {
        guard let im = common.images[safe: image] else { return }
        let tl = SIMD2(center.x - scale * 0.5 * Float(im.width), center.y - scale * 0.5 * Float(im.height))
        drawImage(common: true, image, topLeft: tl + SIMD2(shadowOffset, shadowOffset), sx: scale, sy: scale, color: shadow, enc)
        drawImage(common: true, image, topLeft: tl, sx: scale, sy: scale, color: color, enc)
    }
}

extension SpriteText {
    /// Union of a weather icon's layer rects at scale 1, relative to the draw centre (drawWeatherIcon geometry).
    /// Measured on the visible artwork (alpha > 1/8), not the texture box: icons like the moon sit in a big
    /// transparent canvas, so fitting the canvas would leave them small.
    func iconBounds(_ code: UInt16) -> (min: SIMD2<Float>, max: SIMD2<Float>)? {
        guard let layers = iconLayers[Int(code & 0x7FFF)], !layers.isEmpty else { return nil }
        var lo = SIMD2<Float>(repeating: .greatestFiniteMagnitude), hi = -lo
        let night = code & 0x8000 != 0
        for l in layers {
            var img = l.image
            if night { if img == 4 { img = 1 } else if img == 15 { img = 0xB } }   // drawWeatherIcon's night swap
            guard let (o0, o1) = SpriteText.opaqueRect(weather, img) else { continue }
            let size = imageSize(common: false, img)
            // texture-space rect → centre-relative, scaled like drawWeatherIcon
            let a = (o0 - size / 2) * l.scale + l.offset, b = (o1 - size / 2) * l.scale + l.offset
            lo = simd_min(lo, simd_min(a, b)); hi = simd_max(hi, simd_max(a, b))
        }
        return lo.x <= hi.x ? (lo, hi) : nil
    }

    nonisolated(unsafe) private static var opaqueCache: [Int: (SIMD2<Float>, SIMD2<Float>)?] = [:]
    /// Pixel bounding box of the image's visible pixels (alpha > 32), in texture pixels.
    static func opaqueRect(_ tpl: TPLFile, _ i: Int) -> (SIMD2<Float>, SIMD2<Float>)? {
        if let c = opaqueCache[i] { return c }
        guard i >= 0, i < tpl.images.count else { return nil }
        let im = tpl.images[i]
        var x0 = im.width, y0 = im.height, x1 = -1, y1 = -1
        for y in 0..<im.height {
            for x in 0..<im.width where im.rgba8[(y * im.width + x) * 4 + 3] > 32 {
                if x < x0 { x0 = x }; if x > x1 { x1 = x }; if y < y0 { y0 = y }; if y > y1 { y1 = y }
            }
        }
        let r: (SIMD2<Float>, SIMD2<Float>)? = x1 < 0 ? nil : (SIMD2(Float(x0), Float(y0)), SIMD2(Float(x1 + 1), Float(y1 + 1)))
        opaqueCache[i] = r
        return r
    }
}
