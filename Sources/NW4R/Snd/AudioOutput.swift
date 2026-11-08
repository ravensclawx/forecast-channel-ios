import AVFoundation

/// Streams SoundSystem output through AVAudioEngine (macOS + iOS). Rendered at the AX rate (32 kHz);
/// AVAudioEngine resamples to the hardware rate.
public final class AudioOutput {
    let engine = AVAudioEngine()
    let system: SoundSystem
    private var node: AVAudioSourceNode!

    public init(system: SoundSystem) { self.system = system }

    public func start() throws {
        let fmt = AVAudioFormat(standardFormatWithSampleRate: Double(SoundSystem.outputRate), channels: 2)!
        let sys = system
        node = AVAudioSourceNode(format: fmt) { _, _, frameCount, abl -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(abl)
            guard buffers.count >= 2, let l = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                  let r = buffers[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            sys.render(count: Int(frameCount), left: l, right: r)
            return noErr
        }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: fmt)
        #if os(iOS)
        try AVAudioSession.sharedInstance().setCategory(.ambient)
        try AVAudioSession.sharedInstance().setActive(true)
        #endif
        try engine.start()
    }

    public func stop() { engine.stop() }
}
