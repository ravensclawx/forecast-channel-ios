import Metal
import NW4R
import simd

/// CSetting (d_weather_setting.cpp, CSetting_ctor fn_80027DA8 … CSetting_StInteractive fn_80028598).
/// Rows: city (city_set + city_btn "Change"), temperature (kion_set variants by unit + kion_btn),
/// wind (wind_set + wind_btn; hidden in JP), back.
public final class SettingScreen: Screen {
    let ctx: SceneContext
    let set: UILayout             // +0 set.brlyt
    let base: UILayout            // +4 base.brlyt
    let kionSet: PaneCtl?         // +8
    let citySet: PaneCtl?         // +C
    let windSet: PaneCtl?         // +10
    let kionBtn: PaneCtl?         // +14 (linked to kion_set)
    let cityBtn: PaneCtl?         // +18 (linked to city_set)
    let windBtn: PaneCtl?         // +1C (linked to wind_set)
    enum State { case idle, interactive, passive }
    var state: State = .idle      // PTMF +84
    var cityName: [UInt16] = []   // +C0
    var cityScale: Float = 1      // +A0

    public init(ctx: SceneContext) throws {
        self.ctx = ctx
        set = try ctx.layout("set.brlyt")
        base = try ctx.layout("base.brlyt")
        kionSet = set.find("kion_set"); citySet = set.find("city_set")
        cityBtn = set.find("city_btn"); kionBtn = set.find("kion_btn")
        if ctx.lang == .jp {
            for n in ["wind", "wind_set", "wind_btn"] { set.find(n)?.hidden = true; set.find(n)?.pane.visible = false }
            windSet = nil; windBtn = nil
        } else {
            set.find("text")?.hidden = true; set.find("text")?.pane.visible = false
            windSet = set.find("wind_set"); windBtn = set.find("wind_btn")
        }
        // iPhone portrait: title belt under the safe area, the three setting rows centred, Back in the bottom row.
        PortraitArrange.stretchBackgrounds(base)
        // The "Change Settings" strip sits at the hub belt's height (same vertical rhythm across screens).
        let hub = NormalScreen.Portrait.current
        PortraitArrange.place(set, bottom: ["back", "blank"],
                              extra: ctx.isPortrait ? ["belt": SIMD2(0, (hub.beltShift + 130) - 180)] : [:])
        PortraitArrange.extendBodies(set, ["back", "blank"], toTop: false)
        setupCityName()
        applyUnits()
    }

    func applyUnits() {
        kionSet?.textIndex = ctx.tempUnit; kionSet?.pendingTextIndex = ctx.tempUnit
        windSet?.textIndex = ctx.windUnit; windSet?.pendingTextIndex = ctx.windUnit
    }

    /// fn_8002881C: city name for city_set, scaled to fit the text box.
    func setupCityName() {
        guard let place = ctx.data?.forecast.place(ctx.locationID) else { cityName = []; return }
        cityName = Array(place.city.utf16)
        guard let font = Message.systemFont(ctx), let box = set.pane("city_setTUS") else { return }
        let w = SceneDraw2D.stringWidth(cityName, font: font)
        cityScale = w > box.size.x ? box.size.x / w : 1
    }

    /// fn_80028258 — reset (entering the screen).
    public func reset() {
        set.reset(); base.reset()
        updateBrightness()
        setupCityName(); applyUnits()
        state = .idle
    }
    /// fn_80028430 / fn_800284E4
    public func startInteractive() { state = .interactive }
    public func startPassive() { state = .passive }

    func updateBrightness() {
        func lerp(_ ramp: Int) -> Int { 0x40 + (0xC0 - 0x40) * ramp / 12 }        // LerpU8(0x40, 0xC0, hover, 12)
        if let c = cityBtn { citySet?.brightness = lerp(c.hoverRamp) }
        if let k = kionBtn { kionSet?.brightness = lerp(k.hoverRamp) }
        if let w = windBtn { windSet?.brightness = lerp(w.hoverRamp) }
    }

    public func calc() {
        switch state {
        case .idle: break
        case .passive:                                   // fn_80028798
            applyUnits(); base.update(); set.update()
        case .interactive:                               // CSetting_StInteractive
            base.update(); set.update()
            ctx.ui.updateHover(set, ctx.pad)
            // Hovering a button also lights its value row (+24 link).
            if let h = ctx.ui.hovered {
                if h === cityBtn { citySet?.setHover() } else if h === kionBtn { kionSet?.setHover() } else if h === windBtn { windSet?.setHover() }
            }
            updateBrightness()
            if ctx.ui.buttonTrig("back", ctx.pad) {
                set.find("back")?.keepPressed = true
                ctx.playSE(0x27); ctx.request = 2
            }
            if ctx.ui.buttonTrig("city_btn", ctx.pad) { ctx.request = 1; ctx.playSE(0x2D) }
            if ctx.ui.buttonTrig("kion_btn", ctx.pad) {
                ctx.tempUnit = ctx.tempUnit == 0 ? 1 : 0; ctx.playSE(0x2C)
                kionSet?.textIndex = ctx.tempUnit; kionSet?.pendingTextIndex = ctx.tempUnit
            }
            if windBtn != nil, ctx.ui.buttonTrig("wind_btn", ctx.pad) {
                ctx.windUnit = ctx.windUnit == 0 ? 1 : 0; ctx.playSE(0x2C)
                windSet?.textIndex = ctx.windUnit; windSet?.pendingTextIndex = ctx.windUnit
            }
        }
    }

    /// fn_80028308: base, set, then the city name (TextWriter, centred on city_setTUS).
    public func draw(_ enc: MTLRenderCommandEncoder) {
        base.draw(ctx.lyt, enc)
        set.draw(ctx.lyt, enc)
        guard let d2 = drawer, let font = Message.systemFont(ctx), let box = set.pane("city_setTUS") else { return }
        let m = box.globalMtx
        let cx = m.columns.3.x, cy = m.columns.3.y
        let a = UInt8(Int(set.layoutAlpha))
        d2.text(cityName, font: font, x: 0.5 * ctx.screenWidth + cx, y: LogicalScreen.halfHeight - cy, scale: SIMD2(cityScale, 1),
                color: citySet?.lastTextColor ?? SIMD4(0, 0, 0, a), enc)   // city_set +38 (RGBA, alpha +3B)
    }

    /// Supplied by WeatherScene (shared 2D drawer).
    var drawer: SceneDraw2D?
}
