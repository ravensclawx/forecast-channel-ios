/// The logical 2D screen every layout/sprite/projection is expressed in.
/// Wii: 608 (4:3) or 832 (16:9) × 456. iPhone portrait: 608 × (608 · screen aspect) — the brlyt design width,
/// so every original layout piece renders 1:1; screens place their layouts/pane groups into portrait slots.
public enum LogicalScreen {
    /// Height in logical units (456 on the Wii).
    public static var height: Float = 456
    public static var halfHeight: Float { height / 2 }
    /// Portrait (iPhone) presentation: screens use their portrait arrangements.
    public static var isPortrait = false
    /// Safe-area insets in logical units (top: status bar / Dynamic Island, bottom: home indicator).
    public static var safeTop: Float = 0
    public static var safeBottom: Float = 0
}
