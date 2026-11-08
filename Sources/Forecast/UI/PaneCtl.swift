import NW4R
import simd

/// Language suffixes (GetLangSuffix, lbl_80330138..50): 0 JP, 1 US/English, 2 GE, 3 FR, 4 SP, 5 IT, 6 DU.
public enum Lang: Int { case jp = 0, us, ge, fr, sp, it, du
    public var suffix: String { ["JP", "US", "GE", "FR", "SP", "IT", "DU"][rawValue] }
}

/// CPaneCtl (0xA0) — per top-level pane wrapper: companion panes, hover/press state, colouring. fn_80037184..fn_800389C4.
public final class PaneCtl {
    public let pane: Pane                 // +08
    public let body: Pane                 // +10 (PB, falls back to P)
    public let icon: Pane?                // +14 (PI<lang> | PI)
    public let text: Pane?                // +18 (PT<lang> | PT)
    public let pressFrame0: Pane?, pressFrame1: Pane?   // +1C/+20 (PF0/PF1)
    public var hitRect: SIMD4<Float>      // +3C..+48 x0,y0,x1,y1 (layout space, y up)
    var baseTranslate: SIMD3<Float>       // +4C (portrait placement moves it; see UILayout.place)
    /// The brlyt position (portrait offsets are relative to it).
    var authored = SIMD3<Float>(repeating: 0)
    public var scheme: Int                // +6C
    public var alpha: UInt8 = 255         // +70 (layout fade)
    public var brightness: Int = 255      // +74
    public var hoverRamp = 0              // +78 (0..12)
    public var pressTimer = 0             // +7C (18-frame press)
    public var textIndex = 0              // +80
    public var pendingTextIndex = 0       // +84 (applied when the press ends)
    public var blinkRamp = 0, blinkMax = 1 // +88/+8C
    public var fixed: Bool                // +90 ('f'/'F' user data)
    public var keepPressed = false        // +92
    public var hidden = false             // +94
    var hoveredThisFrame = false          // +95
    public internal(set) var pressing = false   // +96
    public var selected = false           // +97
    public var disabled: Bool             // +98 ('d' user data)
    /// iPhone: hit area extension past the body (layout units; + up / − down) and the body's matching edge y.
    public var hitExtend: Float = 0
    var bodyEdge: Float = 0
    /// +38: the text colour computed by the last PreDraw.
    public private(set) var lastTextColor = ButtonColors.RGBA(0, 0, 0, 255)
    public var slideOffset: Float = 0     // +9C
    /// Optional text-colour override (+30).
    public var textColorHook: ((TextBox, inout ButtonColors.RGBA) -> Void)?

    public var name: String { pane.name }

    /// CPaneCtl ctor (fn_80037184)
    init(_ p: Pane, lang: Lang, defaultScheme: Int) {
        pane = p
        let n = p.name
        func child(_ s: String) -> Pane? { p.find(n + s) }
        body = child("B") ?? p
        func langOrSelf(_ g: Pane?) -> Pane? {
            guard let g else { return nil }
            if let l = g.find(g.name + lang.suffix) {
                for c in g.children { c.visible = c === l }
                return l
            }
            return g
        }
        icon = langOrSelf(child("I"))
        text = langOrSelf(child("T"))
        pressFrame0 = child("F0"); pressFrame1 = child("F1")
        // CPaneCtl ctor user-data scan (8 chars): 'd' disabled, 'f'/'F' fixed, 'c'/'C' + digit = colour scheme.
        let ud = Array(p.userData.utf8.prefix(8))
        var dis = false, fix = false, sch = defaultScheme, i = 0
        while i < ud.count {
            switch ud[i] {
            case UInt8(ascii: "d"): dis = true
            case UInt8(ascii: "f"), UInt8(ascii: "F"): fix = true
            case UInt8(ascii: "c"), UInt8(ascii: "C"):
                i += 1
                if i < ud.count, ud[i] >= 0x30, ud[i] <= 0x39 { sch = Int(ud[i]) - 0x30 }
            default: break
            }
            i += 1
        }
        disabled = dis; fixed = fix; scheme = sch
        baseTranslate = p.translate
        authored = p.translate
        hitRect = .zero
    }

    /// Hit rectangle = PR (or PB) pane rect transformed into layout space.
    func computeHitRect() {
        let r = pane.find(pane.name + "R") ?? body
        let o = r.vertexOrigin, s = r.size, m = r.globalMtx
        let pts = [SIMD2(o.x, o.y), SIMD2(o.x + s.x, o.y), SIMD2(o.x, o.y - s.y), SIMD2(o.x + s.x, o.y - s.y)].map { p -> SIMD2<Float> in
            let v = m * SIMD4(p.x, p.y, 0, 1); return SIMD2(v.x, v.y)
        }
        hitRect = SIMD4(pts.map(\.x).min()!, pts.map(\.y).min()!, pts.map(\.x).max()!, pts.map(\.y).max()!)
        // iPhone: the body extended to the screen edge (PortraitArrange.extendBodies) is touchable too.
        if hitExtend > 0 { hitRect.w = max(hitRect.w, bodyEdge + hitExtend) } else if hitExtend < 0 { hitRect.y = min(hitRect.y, bodyEdge + hitExtend) }
    }

    public func contains(_ x: Float, _ y: Float) -> Bool { x >= hitRect.x && x <= hitRect.z && y >= hitRect.y && y <= hitRect.w }

    /// CPaneCtl_Update (fn_80037B64)
    func update() {
        guard !hidden else { return }
        if hoveredThisFrame { if hoverRamp < 12 { hoverRamp += 1 }; hoveredThisFrame = false }
        else if hoverRamp > 0 { hoverRamp -= 1 }
        if pressing {
            if pressTimer > 0 { pressTimer -= 1; if pressTimer == 0 { textIndex = pendingTextIndex } }
            if pressTimer == 0 { pressing = false }
            if pressTimer == 9 { hoverRamp = 12 }
        } else if pressTimer > 1 { pressTimer -= 1 }
    }

    /// CPaneCtl_SetHoverTree (fn_80038768)
    public func setHover() { guard !fixed, !disabled, !hidden else { return }; hoveredThisFrame = true }
    /// CPaneCtl_Press (fn_800389C4): sets the "pressing" flag (+96) and the hover flag (+95) of the *child*
    /// wrappers (+24/+28, enabled and shown ones only) — never its own. The timer is untouched: with a zero timer
    /// this releases the wrapper on the next Update (used on hover-leave). A disabled wrapper pressed every frame
    /// (CNormal_StInteractive off the top level) therefore keeps its normal body colour with text/icon hidden.
    public func press() { guard !fixed else { return }; pressing = true }
    /// CPaneCtl_Flash(p, on) (fn_80038990): the 18-frame press animation (UI_ButtonTrig / hardware buttons).
    public func flash(_ on: Bool = true) {
        guard !fixed, !disabled, !hidden else { return }
        pressing = on; pressTimer = 0x12
    }
    /// CPaneCtl_ResetPos: hide, clear hover/press, restore the base position.
    public func resetPos() {
        hoveredThisFrame = false; hoverRamp = 0; pressing = false; pressTimer = 0; hidden = true
        pane.translate = baseTranslate
    }

    /// Pane_SetTevColorRec: TEV colour 0/1 RGB on every material in the subtree (skips user data 'F').
    static func setTevColor(_ p: Pane, _ c: ButtonColors.RGBA, reg: Int) {
        if p.userData.hasPrefix("F") { return }
        let m = (p as? Picture)?.material ?? (p as? TextBox)?.material ?? (p as? Window)?.material
        if let m { for i in 0..<3 { m.tevColors[reg][i] = Int32(c[i]) } }
        for ch in p.children { setTevColor(ch, c, reg: reg) }
    }
    /// Pane_SetAlphaRec: material element 0xB (TEV colour 1 alpha) on the pane and three levels of descendants.
    /// Pane alpha itself is never touched (verified against the original in Dolphin).
    static func setAlpha(_ p: Pane, _ a: Int, depth: Int = 0) {
        let v = Int32(max(0, min(255, a)))
        let m = (p as? Picture)?.material ?? (p as? TextBox)?.material ?? (p as? Window)?.material
        m?.tevColors[1].w = v
        if depth < 3 { for c in p.children { setAlpha(c, a, depth: depth + 1) } }
    }
    /// fn_80036BA4: text colours of every TextBox in the subtree.
    static func setTextColor(_ p: Pane, _ c: ButtonColors.RGBA) {
        if p.userData.hasPrefix("F") { return }
        if let t = p as? TextBox { t.topColor = c; t.bottomColor = c }
        for ch in p.children { setTextColor(ch, c) }
    }

    /// Pick (c0, c1) from the scheme for a role (offsets: normal, pressed/hover, selected).
    private func colors(normal: Int, pressed: Int, selected sel: Int, hasBlink: Bool) -> (ButtonColors.RGBA, ButtonColors.RGBA) {
        let s = scheme
        if selected { return (ButtonColors.at(s, sel), ButtonColors.at(s, sel + 4)) }
        if keepPressed && pressTimer > 0 { return (ButtonColors.at(s, pressed), ButtonColors.at(s, pressed + 4)) }
        if hoverRamp > 0 {
            return (ButtonColors.lerp(ButtonColors.at(s, normal), ButtonColors.at(s, pressed), hoverRamp, 12),
                    ButtonColors.lerp(ButtonColors.at(s, normal + 4), ButtonColors.at(s, pressed + 4), hoverRamp, 12))
        }
        if pressTimer > 0 { return (ButtonColors.at(s, pressed), ButtonColors.at(s, pressed + 4)) }
        if hasBlink && blinkRamp > 0 {
            return (ButtonColors.lerp(ButtonColors.at(s, normal), ButtonColors.at(s, pressed), blinkRamp, blinkMax),
                    ButtonColors.lerp(ButtonColors.at(s, normal + 4), ButtonColors.at(s, pressed + 4), blinkRamp, blinkMax))
        }
        return (ButtonColors.at(s, normal), ButtonColors.at(s, normal + 4))
    }

    /// CPaneCtl_PreDraw (fn_80037C20)
    func preDraw() {
        pane.visible = !hidden
        guard !hidden else { return }
        // +99 defaults to 1: fixed ('f'/'F') wrappers keep their authored alpha.
        if !fixed { PaneCtl.setAlpha(pane, Int(alpha)) }
        // Text variant: show child #textIndex of the PT<lang> group, hide its siblings.
        var textPane: Pane? = nil
        if let t = text {
            textPane = t
            if textIndex >= 0, t.children.count > 0 {
                for (i, c) in t.children.enumerated() { c.visible = i == textIndex; if i == textIndex { textPane = c } }
            }
        }
        if !fixed {
            let a = Int(alpha) * min(brightness + 0x80, 255) / 255
            var iconAlpha = a, textAlpha = a
            var (b0, b1) = colors(normal: 0x00, pressed: 0x14, selected: 0x28, hasBlink: false)
            if brightness < 255 {
                b0 = ButtonColors.lerp(b0, ButtonColors.RGBA(255, 255, 255, 0), 255 - brightness, 255)
                b1 = ButtonColors.lerp(b1, ButtonColors.RGBA(255, 255, 255, 0), 255 - brightness, 255)
            }
            PaneCtl.setTevColor(body, b0, reg: 0); PaneCtl.setTevColor(body, b1, reg: 1)
            PaneCtl.setAlpha(body, Int(alpha) * brightness / 255)
            if let icon, !icon.userData.hasPrefix("F") {
                if disabled && !selected { iconAlpha = 0 }
                let (i0, i1) = colors(normal: 0x08, pressed: 0x1C, selected: 0x30, hasBlink: true)
                PaneCtl.setTevColor(icon, i0, reg: 0); PaneCtl.setTevColor(icon, i1, reg: 1)
                PaneCtl.setAlpha(icon, iconAlpha)
            }
            if let tp = textPane {
                if disabled && !selected { textAlpha = 0 }
                var c = colors(normal: 0x10, pressed: 0x24, selected: 0x38, hasBlink: true).0
                c.w = UInt8(max(0, min(255, textAlpha)))
                lastTextColor = c   // +38: also read by draws that write text themselves (CSetting city name)
                if let hook = textColorHook, let tb = tp as? TextBox { hook(tb, &c) }
                PaneCtl.setTextColor(tp, c)
            }
            if let f0 = pressFrame0, let f1 = pressFrame1 { f0.visible = pressTimer <= 0; f1.visible = pressTimer > 0 }
        }
        // Press dip: 18·(1 − sin(π/2·(14 − min(t,14))/14)), or a fixed 12 while latched.
        var dip: Float = 0
        if pressTimer > 0 && pressFrame0 == nil {
            if keepPressed { dip = 12 }
            else { let t = Float(14 - min(pressTimer, 14)); dip = 18 * (1 - sin(1.5708 * t / 14)) }
        }
        pane.translate = baseTranslate + SIMD3(0, slideOffset - dip, 0)
    }
}
