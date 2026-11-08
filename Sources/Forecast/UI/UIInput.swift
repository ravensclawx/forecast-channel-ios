import simd

/// d_scene.cpp input helpers: UI_UpdateHover (fn_8003DAD0), UI_ButtonTrig (fn_8003DEAC), UI_ClearHover (fn_8003DD50).
public final class UIInput {
    public private(set) var hovered: PaneCtl?           // lbl_801F72F0[chan]
    public var playSE: (Int) -> Void = { _ in }
    public var rumble: (Int, Int) -> Void = { _, _ in }   // WPAD_RumblePattern(ch, 3, 0x14) — Mac: no-op / haptics
    let isWide: Bool
    public init(isWide: Bool) { self.isWide = isWide }

    /// Pointer (logical px, y down) → layout space (origin centre, y up), scaled to the 608 design width.
    public func toLayout(_ p: SIMD2<Float>) -> SIMD2<Float> {
        let w: Float = isWide ? 832 : 608
        var x = p.x - w / 2
        if isWide { x *= 608 / 832 }
        let h = LogicalScreen.halfHeight
        return SIMD2(x, min(max(h - p.y, -h), h))
    }

    /// UI_UpdateHover(layout, hoverSE)
    public func updateHover(_ layout: UILayout, _ pad: KPad, hoverSE: Int = 0x28) {
        var hit: PaneCtl? = nil
        if pad.pointerValid { let q = toLayout(pad.pointer); hit = layout.hitTest(q.x, q.y) }
        if hit !== hovered {
            hovered?.press()                       // release the old wrapper (its press timer runs out)
            hovered = hit
            if let h = hit, !(h.fixed || h.disabled || h.hidden) { playSE(hoverSE); rumble(3, 0x14) }
        }
        if let h = hovered {
            if pad.trig.contains(.a) { h.press() }
            h.setHover()
        }
    }

    /// UI_ButtonTrig(paneName, mask): true when the hovered wrapper named `name` is enabled and `mask` was triggered.
    public func buttonTrig(_ name: String, _ pad: KPad, _ mask: WPAD = .a) -> Bool {
        guard let h = hovered, h.name == name, !h.disabled, pad.trig.contains(mask) else { return false }
        h.flash()
        return true
    }

    /// Held variant used for zoom/tilt buttons (LayoutButtonHeld).
    public func buttonHeld(_ name: String, _ pad: KPad, _ mask: WPAD = .a) -> Bool {
        guard let h = hovered, h.name == name, !h.disabled else { return false }
        return pad.hold.contains(mask)
    }

    /// UI_ClearHover
    public func clearHover() { hovered = nil }
}
