import Metal
import NW4R
import simd

/// CLayout (0x434, fn_80039994) — a weather_layout.arc layout plus one CPaneCtl per root child,
/// layout-wide slide/fade, hit testing and widescreen location adjust.
public final class UILayout {
    public let layout: Layout
    public private(set) var panes: [PaneCtl] = []      // +14[], count +414
    public var slideOut = false                        // +418
    public var slideMax = 15                           // +41C
    var slideCount = 0                                 // +420
    public var fadeOut = false                         // +424
    public var fadeMax = 0                             // +428
    var fadeCount = 0                                  // +42C
    public private(set) var layoutAlpha: UInt8 = 255   // +430
    public var visible = true
    let isWide: Bool

    /// CLayout(arc, name, ?, colorScheme, wideFlag)
    public init(_ layout: Layout, lang: Lang, colorScheme: Int = 0, isWide: Bool) {
        self.layout = layout; self.isWide = isWide
        panes = layout.root.children.prefix(256).map { PaneCtl($0, lang: lang, defaultScheme: colorScheme) }
        layout.root.calculate(parentMtx: matrix_identity_float4x4, parentAlpha: 255, locationAdjust: locationAdjust)
        panes.forEach { $0.computeHitRect() }
    }

    public convenience init(assets: Assets, _ name: String, lang: Lang, colorScheme: Int = 0, isWide: Bool) throws {
        self.init(try assets.layout(name), lang: lang, colorScheme: colorScheme, isWide: isWide)
    }

    /// DrawInfo::SetLocationAdjustScale(1/1.3684211, 1) in widescreen.
    var locationAdjust: SIMD2<Float>? { isWide ? SIMD2(1 / 1.368_421_1, 1) : nil }

    // MARK: - iPhone portrait placement

    /// Move root pane groups (and their hit rects) to new layout-space positions (origin = screen centre, y up).
    /// `offsets`: pane name → translation added to the authored position. Call once after construction (and after
    /// `reset()` if a screen re-arranges dynamically).
    public func place(_ offsets: [String: SIMD2<Float>]) {
        for p in panes {
            guard let d = offsets[p.name] else { continue }
            p.baseTranslate = SIMD3(p.authored.x + d.x, p.authored.y + d.y, p.authored.z)
            p.pane.translate = p.baseTranslate
        }
        relayout()
    }
    /// Move every root pane group by the same offset.
    public func placeAll(_ d: SIMD2<Float>, except: Set<String> = []) {
        place(Dictionary(uniqueKeysWithValues: panes.filter { !except.contains($0.name) }.map { ($0.name, d) }))
    }
    /// Recompute matrices and hit rects after panes moved or scaled.
    public func relayout() {
        layout.root.calculate(parentMtx: matrix_identity_float4x4, parentAlpha: 255, locationAdjust: locationAdjust)
        panes.forEach { $0.computeHitRect() }
    }

    /// CLayout_FindPane
    public func find(_ name: String) -> PaneCtl? { panes.first { $0.name == name } }
    public func pane(_ name: String) -> Pane? { layout.find(name) }

    /// CLayout_Reset (fn_80039D40)
    public func reset() {
        for p in panes { p.hoverRamp = 0; p.pressTimer = 0; p.keepPressed = false; p.selected = false; p.slideOffset = 0 }
        slideCount = 0; slideOut = false; fadeCount = 0; fadeOut = false
    }

    /// CLayout_Update (fn_80039E28)
    public func update() {
        panes.forEach { $0.update() }
        if slideOut { if slideCount < slideMax { slideCount += 1 } } else if slideCount > 0 { slideCount -= 1 }
        let h = panes.first.map { abs($0.hitRect.y - $0.hitRect.w) } ?? 0
        for p in panes {
            let sign: Float = p.pane.translate.y > 0 ? 1 : -1
            p.slideOffset = h * Float(slideCount) / Float(max(slideMax, 1)) * sign
        }
        if fadeOut { if fadeCount < fadeMax { fadeCount += 1 } } else if fadeCount > 0 { fadeCount -= 1 }
        layoutAlpha = fadeMax > 0 ? UInt8(255 - (255 * fadeCount) / fadeMax) : 255
        for p in panes { p.alpha = layoutAlpha }
    }

    public var isSlidOut: Bool { slideCount >= slideMax }
    /// fn_8003A2A4 / fn_8003A2D0: slide in / out over `frames`; a new length rescales the current count.
    public func slideIn(_ frames: Int) { slideOut = false; setSlideMax(frames) }
    public func slideOut(_ frames: Int) { slideOut = true; setSlideMax(frames) }
    private func setSlideMax(_ n: Int) {
        guard n != slideMax, slideMax > 0 else { return }
        slideCount = slideCount * n / slideMax; slideMax = n
    }
    public var isFadedOut: Bool { fadeMax > 0 && fadeCount >= fadeMax }

    /// CLayout_Draw (fn_8003A00C): 608x456 ortho; pre-draw every wrapper; Layout::Draw.
    public func draw(_ r: LytRenderer, _ enc: MTLRenderCommandEncoder) {
        guard visible else { return }
        panes.forEach { $0.preDraw() }
        r.draw(layout, enc, screenWidth: 608, locationAdjust: locationAdjust)
    }

    /// CLayout_HitTest (fn_8003A140): topmost enabled, visible wrapper containing (x, y) in layout space.
    public func hitTest(_ x: Float, _ y: Float) -> PaneCtl? {
        if fadeOut && fadeCount >= fadeMax && fadeMax > 0 { return nil }
        for p in panes.reversed() where !p.hidden && p.pane.visible && !p.disabled && p.contains(x, y) { return p }
        return nil
    }
}
