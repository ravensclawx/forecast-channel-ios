/// nw4r::snd::detail EnvGenerator / Lfo / Channel + an AX-style voice.
/// Timing follows the console: channels update every AX frame (3 ms); envelopes/LFOs advance 3 ms per update;
/// voice volume ramps linearly across the frame from the previous to the new envelope value.

struct EnvGenerator {
    enum Status { case attack, decay, sustain, release }
    var value: Float = -904            // 0.1 dB units
    var status: Status = .attack
    var attack: Float = 0, decay: Float = 0, release: Float = 0
    var sustain = 127

    mutating func setup(_ t: SndTables, attack a: Int, decay d: Int, sustain s: Int, release r: Int) {
        attack = t.attack[min(max(a, 0), 127)]; decay = EnvGenerator.rate(d); sustain = min(max(s, 0), 127); release = EnvGenerator.rate(r)
    }
    mutating func reset() { value = SndTables.volumeMinDB * 10; status = .attack }

    /// EnvGenerator::CalcRelease — 0.1 dB per msec.
    static func rate(_ r: Int) -> Float {
        if r >= 127 { return 65535 }
        if r == 126 { return 24 }
        if r < 50 { return Float(r * 2 + 1) / 128 / 5 }
        return 60 / Float(126 - r) / 5
    }

    /// dB value (0 = full).
    var db: Float { (status == .attack && attack == 0) ? 0 : value / 10 }

    mutating func update(_ t: SndTables, msec: Int) {
        var ms = msec
        if status == .attack {
            while ms > 0 {
                value *= attack; ms -= 1
                if value > -1.0 / 32.0 { value = 0; status = .decay; break }
            }
            if status != .decay { return }   // falls through into decay with the remaining msec
        }
        switch status {
        case .decay:
            let target = Float(t.decibelSquare[sustain])
            value -= decay * Float(ms)
            if value <= target { value = target; status = .sustain }
        case .release:
            value -= release * Float(ms)
        default: break
        }
    }
}

struct Lfo {
    var depth: Float = 0, range: Float = 1, speed: Float = 6.25, delay = 0
    var counter: Float = 0, delayCounter = 0
    mutating func reset() { counter = 0; delayCounter = 0 }
    mutating func update(msec: Int) {
        var ms = msec
        if delayCounter < delay {
            if delayCounter + ms <= delay { delayCounter += ms; return }
            ms -= delay - delayCounter; delayCounter = delay
        }
        counter += speed * Float(ms) / 1000
        counter -= Float(Int(counter))
    }
    func value(_ t: SndTables) -> Float {
        if depth == 0 || delayCounter < delay { return 0 }
        let idx = Int(4 * (32 * counter))
        let s: Int
        switch idx {
        case ..<32: s = Int(t.lfoSin[idx])
        case ..<64: s = Int(t.lfoSin[32 - (idx - 32)])
        case ..<96: s = -Int(t.lfoSin[idx - 64])
        default: s = -Int(t.lfoSin[32 - (idx - 96)])
        }
        return Float(s) / 127 * depth * range
    }
}

/// Decoded wave shared by voices.
final class PCMWave {
    let channels: [[Float]]
    let sampleRate: Float
    let loop: Bool, loopStart: Int, loopEnd: Int
    init(channels: [[Float]], sampleRate: Int, loop: Bool, loopStart: Int, loopEnd: Int) {
        self.channels = channels; self.sampleRate = Float(sampleRate); self.loop = loop
        self.loopStart = loopStart; self.loopEnd = min(loopEnd, channels.first?.count ?? 0)
    }
}

final class Channel {
    enum LfoTarget: Int { case pitch = 0, volume = 1, pan = 2 }

    var active = true
    var key = 60, originalKey = 60
    var initVolume: Float = 1, userVolume: Float = 1, tune: Float = 1
    var initPan: Float = 0, userPan: Float = 0
    var userPitch: Float = 0, userPitchRatio: Float = 1
    var mainSend: Float = 0
    var fxSendC: Float = 0                 // AUX C send (0..1); the channel's reverb bus
    var panCurve: SndTables.PanCurve = .sqrt
    var env = EnvGenerator()
    var lfo = Lfo(), lfoTarget = LfoTarget.pitch
    var length = -1                       // ticks until release; -1 = until released
    var sweepPitch: Float = 0, sweepLength = 0, sweepCounter = 0, autoSweep = true
    weak var track: SeqTrack?            // nil once freed from its track (still releasing)

    // Voice
    let wave: PCMWave
    var pos: Double = 0
    var pitchRatio: Float = 1
    var gainL: Float = 0, gainR: Float = 0     // gains at frame start (ramp from)
    var auxScale: Float = 0                    // aux gain relative to main (send / main-send)
    var nextL: Float = 0, nextR: Float = 0     // gains at frame end

    init(wave: PCMWave) { self.wave = wave }

    var isReleasing: Bool { env.status == .release }
    func release() { if env.status != .release { env.status = .release } }
    func stop() { active = false }

    func setSweep(_ pitch: Float, time: Int, auto: Bool) { sweepPitch = pitch; sweepLength = time; sweepCounter = 0; autoSweep = auto }
    func updateSweep(_ count: Int) { sweepCounter = min(sweepCounter + count, sweepLength) }
    var sweepValue: Float {
        if sweepPitch == 0 || sweepCounter >= sweepLength { return 0 }
        return sweepPitch * Float(sweepLength - sweepCounter) / Float(sweepLength)
    }

    /// Channel::Update (+ Voice::CalcMixParam), once per AX frame.
    func update(_ t: SndTables, periodic: Bool) {
        guard active else { return }
        let lfoValue = lfo.value(t)
        let volume = initVolume * userVolume
        var veInit = t.volumeRatio(env.db)
        if lfoTarget == .volume { veInit *= t.volumeRatio(SndTables.volumeMaxDB * lfoValue) }
        if env.status == .release && volume * veInit == 0 { stop(); return }

        var cent = Float(key - originalKey) + sweepValue + userPitch
        if lfoTarget == .pitch { cent += lfoValue }
        pitchRatio = t.pitchRatio(Int(256 * cent)) * tune * userPitchRatio

        var pan = initPan + userPan
        if lfoTarget == .pan { pan += lfoValue }

        if periodic {
            if autoSweep { updateSweep(3) }
            lfo.update(msec: 3)
            env.update(t, msec: 3)
        }
        var veTarget = t.volumeRatio(env.db)
        if lfoTarget == .volume { veTarget *= t.volumeRatio(SndTables.volumeMaxDB * lfo.value(t)) }

        let main = min(max(1 + mainSend, 0), 1)
        let l = t.panRatio(pan, curve: panCurve), r = t.panRatio(-pan, curve: panCurve)
        auxScale = main > 0 ? min(max(fxSendC, 0), 1) / main : 0
        gainL = volume * veInit * main * l; gainR = volume * veInit * main * r
        nextL = volume * veTarget * main * l; nextR = volume * veTarget * main * r
    }

    /// Mix `n` output samples at `outRate` into the stereo buffers (linear gain ramp, 4-point interpolation).
    func mix(into L: inout [Float], _ R: inout [Float], aux AL: inout [Float], _ AR: inout [Float], n: Int, outRate: Float) {
        guard active else { return }
        let step = Double(pitchRatio * wave.sampleRate / outRate)
        let ch0 = wave.channels[0], ch1 = wave.channels.count > 1 ? wave.channels[1] : ch0
        let end = wave.loopEnd
        let stereo = wave.channels.count > 1
        for i in 0..<n {
            if Int(pos) >= end {
                if wave.loop && end > wave.loopStart { pos -= Double(end - wave.loopStart) } else { stop(); return }
            }
            let f = Float(i) / Float(n)
            let gl = gainL + (nextL - gainL) * f, gr = gainR + (nextR - gainR) * f
            let ip = Int(pos), fr = Float(pos - Double(ip))
            func s(_ c: [Float], _ k: Int) -> Float {
                var j = k
                if j >= end { j = wave.loop ? wave.loopStart + (j - end) : end - 1 }
                return c[max(0, min(j, c.count - 1))]
            }
            func interp(_ c: [Float]) -> Float {
                let a = s(c, ip - 1), b = s(c, ip), cc = s(c, ip + 1), d = s(c, ip + 2)
                // Catmull-Rom (AX uses a 4-tap polyphase SRC; this is the closest simple equivalent)
                return b + 0.5 * fr * (cc - a + fr * (2 * a - 5 * b + 4 * cc - d + fr * (3 * (b - cc) + d - a)))
            }
            let vl = interp(ch0), vr = stereo ? interp(ch1) : vl
            L[i] += vl * gl; R[i] += vr * gr
            if auxScale > 0 { AL[i] += vl * gl * auxScale; AR[i] += vr * gr * auxScale }
            pos += step
        }
    }
}
