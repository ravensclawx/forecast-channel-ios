/// CFade (0x64): full-screen black quad. m_pFade = opaque, m_pFade2 = dim to 0xA0 behind dialogs.
public final class Fade {
    public enum State { case idle, fadeIn, fadeOut }
    public private(set) var state: State = .idle
    /// CFade +13: the quad colour's alpha (m_pFade2 starts at 0xA0; the hub↔globe transitions set it to 0xFF).
    public var maxAlpha: Float
    public private(set) var alpha: Float          // 0..maxAlpha (255-scale)
    var frames = 1, counter = 0

    public init(maxAlpha: Float = 255, startOpaque: Bool = true) { self.maxAlpha = maxAlpha; alpha = startOpaque ? maxAlpha : 0 }

    /// CFade_StartFadeOut(frames): to black.
    public func startFadeOut(_ frames: Int) { state = .fadeOut; self.frames = max(frames, 1); counter = 0 }
    /// CFade_StartFadeIn(frames): from black.
    public func startFadeIn(_ frames: Int) { state = .fadeIn; self.frames = max(frames, 1); counter = 0 }

    public var isIdle: Bool { state == .idle }

    public func update() {
        switch state {
        case .idle: break
        case .fadeOut:
            counter += 1; alpha = maxAlpha * Float(counter) / Float(frames)
            if counter >= frames { alpha = maxAlpha; state = .idle }
        case .fadeIn:
            counter += 1; alpha = maxAlpha * (1 - Float(counter) / Float(frames))
            if counter >= frames { alpha = 0; state = .idle }
        }
    }
}
