/// Shared iPhone-portrait arrangement: where the original rows go on the tall screen, in layout space
/// (origin = screen centre, y up — the brlyt convention). Every screen uses these so rows line up across screens.
///
///   ┌ safe area (status bar / Dynamic Island) ┐
///   │ top button row      (original y = +195) │  ← zoom/next/zoom on the globe, ▲/Settings on the hub
///   │ belt                (original y ≈ +130) │  ← page/mode title + city
///   │                                         │
///   │ content             (original y ≈ 0)    │  ← pages / globe / lists, centred in the free band
///   │                                         │
///   │ strip               (original y ≈ −146) │  ← "supported by" / "As of" stamp
///   │ bottom button row   (original y = −195) │  ← Wii Menu / ▼ / Globe — in the thumb zone
///   └ safe area (home indicator)              ┘
public enum PortraitSlots {
    static var H: Float { LogicalScreen.height }
    static var half: Float { H / 2 }
    /// Layout-space y of the top edge / bottom edge of the usable (safe) area.
    public static var safeTopY: Float { half - LogicalScreen.safeTop }
    public static var safeBottomY: Float { -half + LogicalScreen.safeBottom }
    /// The original button rows are 66 tall, centred at ±195 on the 456 screen.
    public static let rowHeight: Float = 66
    /// Offset that moves something authored at the original top row (y = +195) to the portrait top row.
    public static var topRowShift: Float { (safeTopY - rowHeight / 2) - 195 }
    /// Offset that moves the original bottom row (y = −195) to the portrait bottom row.
    public static var bottomRowShift: Float { (safeBottomY + rowHeight / 2) - (-195) }
    /// Generic: shift for an element authored at original y `y` that hugs the top / bottom of the 456 screen.
    public static func topShift(_ y: Float = 0) -> Float { topRowShift }
    public static func bottomShift(_ y: Float = 0) -> Float { bottomRowShift }
    /// Scale for a full-screen 608×456 background pane to cover the whole tall screen.
    public static var backgroundScaleY: Float { H / 456 }
    /// Layout y ↔ SetOrtho2D pixel y.
    public static func pixelY(_ layoutY: Float) -> Float { half - layoutY }
    /// For 2D sprites authored in the 456-high SetOrtho2D space (pixels, y down): where an original pixel y lands
    /// when the element moves with the centre band / the top row / the bottom row.
    public static func pixelCentre(_ y: Float) -> Float { y + (H - 456) / 2 }
    public static func pixelTop(_ y: Float) -> Float { pixelCentre(y) - topRowShift }
    public static func pixelBottom(_ y: Float) -> Float { pixelCentre(y) - bottomRowShift }
}
