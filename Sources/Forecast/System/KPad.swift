import simd

/// Wii Remote button bits (WPAD_BUTTON_*), as tested by main.dol.
public struct WPAD: OptionSet, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public static let left = WPAD(rawValue: 0x0001), right = WPAD(rawValue: 0x0002)
    public static let down = WPAD(rawValue: 0x0004), up = WPAD(rawValue: 0x0008)
    public static let plus = WPAD(rawValue: 0x0010), two = WPAD(rawValue: 0x0100), one = WPAD(rawValue: 0x0200)
    public static let b = WPAD(rawValue: 0x0400), a = WPAD(rawValue: 0x0800)
    public static let minus = WPAD(rawValue: 0x1000), home = WPAD(rawValue: 0x8000)
}

/// Raw controller sample supplied by the platform shell each frame (mouse/keyboard on Mac, touch on iPhone).
public struct PointerSample: Sendable {
    public var position: SIMD2<Float>   // logical screen px (0..W, 0..456), y down — what KPADGetProjectionPos yields
    public var valid: Bool
    public var held: WPAD
    public var twistDegrees: Float      // Wii Remote roll; from KPADStatus.horizon via Atan2FIdx(h.x, -h.y)
    /// Touch: this A press is a tap (not a held drag) — the globe must not start a grab for it.
    public var tap = false
    public init(position: SIMD2<Float> = .zero, valid: Bool = false, held: WPAD = [], twistDegrees: Float = 0) {
        self.position = position; self.valid = valid; self.held = held; self.twistDegrees = twistDegrees
    }
}

/// Port of the channel's input update (fn_8002F9CC): KPADRead → hold/trig/release + smoothed pointer.
public final class KPad {
    public private(set) var hold: WPAD = [], trig: WPAD = [], release: WPAD = []
    public private(set) var pointer = SIMD2<Float>(304, 228)   // lbl_801D9730 / lbl_801D9740
    public private(set) var pointerValid = false
    public private(set) var twist: Float = 0
    public private(set) var isTap = false

    /// Touch (iPhone): the finger position is exact — no IR-jitter smoothing.
    public var smoothPointer = true

    public init() {}

    public func update(_ s: PointerSample) {
        trig = s.held.subtracting(hold)
        release = hold.subtracting(s.held)
        hold = s.held
        twist = s.twistDegrees
        isTap = s.tap
        pointerValid = s.valid
        guard s.valid else { return }
        if !smoothPointer { pointer = s.position; return }
        // a = clamp(0.002·|raw − smoothed|, 0.1, 1); smoothed = (1−a)·smoothed + a·raw, per axis
        for i in 0..<2 {
            let a = min(max(0.002 * abs(s.position[i] - pointer[i]), 0.1), 1)
            pointer[i] = (1 - a) * pointer[i] + a * s.position[i]
        }
    }
}
