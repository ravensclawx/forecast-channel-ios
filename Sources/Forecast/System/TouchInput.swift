import simd

/// Touch → Wii Remote translation for the iPhone port (no cursor is drawn).
///
/// One finger is the pointer. How it maps to the A button depends on what the scene wants under the finger:
/// - `.pressOnRelease` (buttons, lists): while the finger is down the pointer is valid and hovers (button highlight,
///   hover SE, haptic) without A; lifting the finger produces one frame with A triggered at the lift point, then the
///   pointer becomes invalid. A finger that travelled more than `tapSlop` (a scroll/drag) never presses.
/// - `.grab` (globe): A is held for as long as the finger is down — the original grab-and-spin with inertia, and the
///   original marker click rule (press within 50 px, release without moving 40 px).
/// Two fingers never press anything: they feed `Gestures` (pinch → zoom, vertical pan → tilt, rotation → twist).
public final class TouchInput {
    public enum Mode { case pressOnRelease, grab }

    /// Per-frame gesture deltas consumed by the screens (reset by `sample()`).
    public struct Gestures {
        /// Pinch scale ratio accumulated this frame (1 = none, >1 fingers apart).
        public var pinch: Float = 1
        /// Two-finger vertical travel this frame, logical units (positive = fingers moved down).
        public var panY: Float = 0
        /// Two-finger rotation this frame, degrees (positive = clockwise).
        public var rotation: Float = 0
        /// One-finger vertical travel this frame (lists scroll with this), logical units (positive = down).
        public var dragY: Float = 0
        public var fingers = 0
        public init() {}
    }

    public var tapSlop: Float = 18
    public private(set) var gestures = Gestures()

    private var pending = Gestures()
    private var fingers: [Int: SIMD2<Float>] = [:]
    private var primary: Int?
    private var startPos = SIMD2<Float>.zero
    private var lastPos = SIMD2<Float>.zero
    private var travelled: Float = 0
    private var releaseAt: SIMD2<Float>?
    private var releaseWasTap = false
    private var multi = false
    private var mode: Mode = .pressOnRelease
    private var twoFingerRef: (dist: Float, midY: Float, angle: Float)?

    public init() {}

    // MARK: raw touches (logical coordinates: 0..608 × 0..LogicalScreen.height, y down)

    /// `modeAt` asks the scene what kind of touch starts at this point (globe body → `.grab`).
    public func began(id: Int, at p: SIMD2<Float>, modeAt: (SIMD2<Float>) -> Mode) {
        fingers[id] = p
        if fingers.count == 1 {
            primary = id; startPos = p; lastPos = p; travelled = 0; multi = false
            mode = modeAt(p); panning = false
        } else {
            multi = true
            twoFingerRef = twoFingerState()
        }
    }

    public func moved(id: Int, to p: SIMD2<Float>) {
        guard fingers[id] != nil else { return }
        fingers[id] = p
        if multi, fingers.count >= 2, let ref = twoFingerRef, let now = twoFingerState() {
            if ref.dist > 1 { pending.pinch *= now.dist / ref.dist }
            pending.panY += now.midY - ref.midY
            var da = now.angle - ref.angle
            if da > 180 { da -= 360 } else if da < -180 { da += 360 }
            pending.rotation += da
            twoFingerRef = now
        } else if id == primary {
            pending.dragY += p.y - lastPos.y
            travelled = max(travelled, simd_length(p - startPos))
            lastPos = p
        }
    }

    public func ended(id: Int, cancelled: Bool = false) {
        guard let p = fingers.removeValue(forKey: id) else { return }
        if id == primary {
            if !multi && !cancelled { releaseAt = p; releaseWasTap = travelled <= tapSlop }
            primary = nil
        }
        if fingers.count >= 2 { twoFingerRef = twoFingerState() } else { twoFingerRef = nil }
        if fingers.isEmpty { multi = false }
    }

    private func twoFingerState() -> (dist: Float, midY: Float, angle: Float)? {
        let pts = fingers.sorted { $0.key < $1.key }.prefix(2).map(\.value)
        guard pts.count == 2 else { return nil }
        let d = pts[1] - pts[0]
        return (simd_length(d), (pts[0].y + pts[1].y) / 2, atan2(d.y, d.x) * 180 / .pi)
    }

    // MARK: per frame

    /// The Wii Remote sample for this frame (fed to KPad.update) and the gestures for the screens.
    public func sample() -> PointerSample {
        gestures = pending; gestures.fingers = fingers.count
        pending = Gestures()
        if let r = releaseAt {
            releaseAt = nil
            switch mode {
            case .pressOnRelease:
                // A tap: hover + A on this frame at the lift point. A drag only releases the hover.
                return PointerSample(position: r, valid: true, held: releaseWasTap ? [.a] : [])
            case .grab:
                // Never panned: a tap — a one-frame A at the start point (marker click), flagged so the globe doesn't
                // treat it as a grab (no grab sound for taps). Panned: A released, the grab ends.
                if !panning { var t = PointerSample(position: startPos, valid: true, held: [.a]); t.tap = true; return t }
                panning = false
                return PointerSample(position: r, valid: true, held: [])
            }
        }
        guard !multi, let id = primary, let p = fingers[id] else { return PointerSample(position: lastPos, valid: false) }
        switch mode {
        case .pressOnRelease: return PointerSample(position: p, valid: true, held: [])
        case .grab:
            // The globe holds still until the finger has really moved, so a slightly wobbly tap on a city is a tap,
            // not a tiny spin.
            // A is held only once the finger really pans (the grab — and its sound — starts then); a resting or
            // slightly wobbly finger is just a pointer, so taps, pinches and two-finger tilts never grab.
            if travelled > grabSlop { panning = true }
            return PointerSample(position: panning ? p : startPos, valid: true, held: panning ? [.a] : [])
        }
    }
    public var grabSlop: Float = 14
    private var panning = false
}
