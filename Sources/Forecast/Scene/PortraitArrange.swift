import NW4R
import simd

/// iPhone-portrait arrangements shared by the dialog-style screens (settings, address, messages, connect).
/// Everything is a no-op unless LogicalScreen.isPortrait. Layout space: origin = screen centre, y up.
enum PortraitArrange {
    static var on: Bool { LogicalScreen.isPortrait }

    /// Full-screen 608×456 background pictures cover the whole tall screen (scale Y about the centre).
    static func stretchBackgrounds(_ ui: UILayout, names: Set<String> = ["bg", "bg_filter", "back_00", "back_01", "back_02"]) {
        guard on else { return }
        var changed = false
        for p in ui.panes where names.contains(p.name) {
            p.pane.scale.y = PortraitSlots.backgroundScaleY
            changed = true
        }
        if changed { ui.relayout() }
    }

    /// Shift root pane groups: `top` → under the safe area (as the original top row), `bottom` → thumb zone (as the
    /// original bottom row), `extra` → arbitrary offsets. Everything else stays centred.
    static func place(_ ui: UILayout, top: [String] = [], bottom: [String] = [], extra: [String: SIMD2<Float>] = [:]) {
        guard on else { return }
        var d: [String: SIMD2<Float>] = extra
        for n in top { d[n] = SIMD2(0, PortraitSlots.topRowShift) }
        for n in bottom { d[n] = SIMD2(0, PortraitSlots.bottomRowShift) }
        ui.place(d)
    }

    /// Edge-to-edge rows: stretch each wrapper's body picture/group (`<name>B`) so it reaches the screen's top
    /// (`toTop`) or bottom edge through the safe area. The inner edge stays put, so labels/icons don't move; hit rects
    /// follow the body. Top rows keep the original 18-unit overhang so the press dip never shows a gap.
    /// Replace an (English) text box's text — iPhone wording for Wii-specific strings.
    static func setText(_ ui: UILayout, _ name: String, _ s: String) {
        (ui.pane(name) as? TextBox)?.text = Array(s.utf16)
    }

    static func extendBodies(_ ui: UILayout, _ names: [String], toTop: Bool, overlap ov: Float = 40) {
        guard on else { return }
        ui.relayout()
        let half = LogicalScreen.halfHeight
        var extents: [String: Float] = [:]
        for n in names {
            guard let b = ui.pane(n + "B") else { continue }
            let cy = (b.globalMtx * SIMD4<Float>(0, 0, 0, 1)).y     // o=4: the pane origin is its centre
            let h = b.size.y * abs(b.scale.y)
            let ext = toTop ? (half + 18) - (cy + h / 2) : (cy - h / 2) + half
            guard ext > 0, h > 0 else { continue }
            // The art keeps its size (gloss band intact); every picture gets a strip past its local bottom (the
            // screen edge for both rows — the top row's body is the bottom row mirrored) sampling the body grey.
            func strip(_ p: Pane) {
                if let pic = p as? Picture {
                    // Which local edge faces the screen edge we extend to (mirrored bodies flip it).
                    let down = (pic.globalMtx * SIMD4<Float>(0, -1, 0, 0)).y   // screen y of local −y
                    let localTop = toTop ? down < 0 : down > 0
                    let overlap = min(ov, pic.size.y)
                    let h = max(pic.size.y, 1)
                    // sample the art row where the strip meets it → the extension continues the button seamlessly
                    // the renderer trims the art at `overlap` from its outer edge and stretches that row outward
                    let t = localTop ? min(overlap / h, 1) : max(1 - overlap / h, 0)
                    pic.edgeStrip = (ext, t, localTop, overlap)
                }
                p.children.forEach(strip)
            }
            strip(b)
            extents[n] = (toTop ? ext : -ext)
        }
        // Touch: the whole visible body plus its strip is the hit area (kept by PaneCtl.computeHitRect, so it survives
        // later relayouts).
        for n in names {
            guard let p = ui.find(n), let b = ui.pane(n + "B"), let e = extents[n] else { continue }
            let cy = (b.globalMtx * SIMD4<Float>(0, 0, 0, 1)).y, h = b.size.y * abs(b.scale.y)
            p.bodyEdge = e > 0 ? cy + h / 2 : cy - h / 2
            p.hitExtend = e
        }
        ui.relayout()
    }

    /// Vertical shift that moves dialog buttons (authored in the lower half of the 456 screen) into the thumb zone:
    /// the lowest one lands `margin` above the bottom row's top edge.
    static func thumbShift(lowestY: Float, margin: Float = 40) -> Float {
        guard on else { return 0 }
        let rowTop = PortraitSlots.safeBottomY + PortraitSlots.rowHeight
        return (rowTop + margin) - lowestY
    }

    /// Vertical shift that moves a dialog's text block (authored near the top of the 456 screen) up by part of the
    /// extra height so the dialog reads as a sheet: header high, buttons low.
    static func textShift(_ fraction: Float = 0.22) -> Float {
        guard on else { return 0 }
        return (LogicalScreen.height - 456) * fraction
    }
}
