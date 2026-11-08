import Foundation

/// A bank with its wave data; waves are decoded from DSP-ADPCM on first use and cached.
final class LoadedBank {
    let file: BankFile
    let waveData: [UInt8]
    private var cache: [Int: PCMWave] = [:]
    init(file: BankFile, waveData: [UInt8]) { self.file = file; self.waveData = waveData }
    func wave(_ i: Int) -> PCMWave? {
        if let w = cache[i] { return w }
        guard i < file.waves.count else { return nil }
        let info = file.waves[i]
        let n = info.loopEndSample
        let chans: [[Float]] = (0..<info.channels).map { c in
            let off = info.channelDataOffsets[c]
            switch info.format {
            case 2: return DSPADPCM.decode(waveData, offset: off, samples: n, coefs: info.adpcm[c], hist: info.initialHistory[c])
            case 1: return (0..<n).map { k in
                let o = off + k * 2; guard o + 1 < waveData.count else { return 0 }
                return Float(Int16(bitPattern: UInt16(waveData[o]) << 8 | UInt16(waveData[o + 1]))) / 32768 }
            default: return (0..<n).map { k in off + k < waveData.count ? Float(Int8(bitPattern: waveData[off + k])) / 128 : 0 }
            }
        }
        let w = PCMWave(channels: chans, sampleRate: info.sampleRate, loop: info.loop, loopStart: info.loopStartSample, loopEnd: n)
        cache[i] = w
        return w
    }
}

/// nw4r BasicSound/SeqSound: owns a SeqPlayer plus handle-level volume/pitch/pan, fades and pause.
public final class SeqSound {
    public let soundID: Int
    let player: SeqPlayer
    let playerID: Int, priority: Int
    let startOrder: Int
    var initVolume: Float
    // MoveValue-style ramps, advanced once per game frame (BasicSound::Update)
    var userVolume: Float = 1, userVolumeTarget: Float = 1, userVolumeFrames = 0
    var fadeVolume: Float = 1, fadeTarget: Float = 1, fadeFrames = 0, stopAfterFade = false
    var pauseVolume: Float = 1, pauseTarget: Float = 1, pauseFrames = 0, pausing = false
    public var pitch: Float = 1, pan: Float = 0

    init(id: Int, player: SeqPlayer, playerID: Int, priority: Int, volume: Float, order: Int) {
        soundID = id; self.player = player; self.playerID = playerID; self.priority = priority; initVolume = volume; startOrder = order
    }
    var isFinished: Bool { player.finished && !hasSoundingChannels }
    var hasSoundingChannels: Bool { player.tracks.contains { $0.channels.contains { $0.active } } }

    private static func step(_ v: inout Float, _ t: Float, _ frames: inout Int) {
        if frames > 0 { v += (t - v) / Float(frames); frames -= 1 } else { v = t }
    }
    func gameFrameUpdate() {
        SeqSound.step(&userVolume, userVolumeTarget, &userVolumeFrames)
        SeqSound.step(&fadeVolume, fadeTarget, &fadeFrames)
        SeqSound.step(&pauseVolume, pauseTarget, &pauseFrames)
        if pausing && pauseFrames == 0 { player.paused = true }
        applyParams()
    }
    func applyParams() {
        player.volume = initVolume * userVolume * fadeVolume * pauseVolume
        player.pitch = pitch; player.pan = pan
    }
}

/// Handle (nw4r::snd::SoundHandle). Detaches automatically when the sound ends.
public final class SoundHandle {
    weak var system: SoundSystem?
    var sound: SeqSound?
    public init() {}
    public var isAttached: Bool { sound != nil }
    public var soundID: Int { sound?.soundID ?? -1 }

    public func setVolume(_ v: Float, frames: Int = 0) { system?.locked { if let s = sound { s.userVolumeTarget = v; s.userVolumeFrames = frames; if frames == 0 { s.userVolume = v }; s.applyParams() } } }
    public func setPitch(_ p: Float) { system?.locked { sound?.pitch = p; sound?.applyParams() } }
    public func setPan(_ p: Float) { system?.locked { sound?.pan = p; sound?.applyParams() } }
    /// BasicSound::Stop(fadeFrames)
    public func stop(fadeFrames: Int = 0) { system?.locked { system?.stopSound(self, fadeFrames: fadeFrames) } }
    /// BasicSound::Pause(flag, fadeFrames)
    public func pause(_ flag: Bool, fadeFrames: Int = 0) {
        system?.locked {
            guard let s = sound else { return }
            if flag { s.pausing = true; s.pauseTarget = 0; s.pauseFrames = fadeFrames; if fadeFrames == 0 { s.pauseVolume = 0; s.player.paused = true } }
            else { s.pausing = false; s.player.paused = false; s.pauseTarget = 1; s.pauseFrames = fadeFrames; if fadeFrames == 0 { s.pauseVolume = 1 } }
            s.applyParams()
        }
    }
    public func detach() { sound = nil }
}

/// The audio engine core: SoundArchivePlayer + AX-style 32 kHz mixer in 3 ms frames.
public final class SoundSystem {
    public static let outputRate: Float = 32000          // AX mixer rate
    public static let samplesPerFrame = 96               // 3 ms at 32 kHz

    public let tables: SndTables
    var globalVars = [Int16](repeating: -1, count: 16)
    private var archives: [SoundArchive] = []
    private var seqCache: [String: SeqFile] = [:]
    private var bankCache: [String: LoadedBank] = [:]
    private var channels: [Channel] = []
    private var sounds: [SeqSound] = []
    private var handles: [(SoundHandle, SeqSound)] = []
    private var order = 0
    private let lock = NSRecursiveLock()
    public var masterVolume: Float = 1

    private let reverb: FxReverbHi
    public init(tables: SndTables, reverbParam: [Float]? = nil) {
        self.tables = tables
        var p = FxReverbHi.Param()
        if let r = reverbParam, r.count >= 6 {
            p = .init(preDelay: r[0], time: r[1], coloration: r[2], damping: r[3], crosstalk: r[4], outGain: r[5])
        }
        reverb = FxReverbHi(rate: SoundSystem.outputRate, param: p)
    }

    func locked<T>(_ f: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return f() }

    /// Register an archive; returns its index.
    @discardableResult public func addArchive(_ a: SoundArchive) -> Int { locked { archives.append(a); return archives.count - 1 } }
    public func archive(_ i: Int) -> SoundArchive { archives[i] }

    func addChannel(_ c: Channel) { channels.append(c) }

    /// SoundArchivePlayer::StartSound. Returns false if the sound could not start.
    @discardableResult
    public func startSound(archive ai: Int, id: Int, handle: SoundHandle? = nil) -> Bool {
        locked {
            let a = archives[ai]
            guard id >= 0, id < a.sounds.count else { return false }
            let info = a.sounds[id]
            guard info.type == .seq else { return false }
            let key = "\(ai):"
            guard let seq = cachedSeq(key + "f\(info.fileID)", a, info.fileID),
                  let bank = cachedBank(key + "b\(info.seqBankID)", a, info.seqBankID) else { return false }
            if let h = handle { stopSound(h, fadeFrames: 0) }
            // Player capacity (PlayerInfo.playableSoundCount): evict lowest priority, then oldest.
            let cap = info.playerID < a.players.count ? max(a.players[info.playerID].playableSoundCount, 1) : 1
            let same = sounds.filter { $0.playerID == info.playerID && !$0.player.finished && $0.startOrder >= 0 && $0.player.system === self && archiveTag($0) == ai }
            if same.count >= cap, let victim = same.min(by: { ($0.priority, $0.startOrder) < ($1.priority, $1.startOrder) }) {
                if victim.priority > info.playerPriority { return false }
                kill(victim)
            }
            let player = SeqPlayer(system: self, seq: seq, bank: bank, startOffset: info.seqLabelOffset,
                                   allocTrack: info.seqAllocTrack, panCurve: SndTables.PanCurve(rawValue: info.panCurve) ?? .sqrt)
            order += 1
            let s = SeqSound(id: id, player: player, playerID: info.playerID, priority: info.playerPriority,
                             volume: Float(info.volume) / 127, order: order)
            soundArchiveTag[ObjectIdentifier(s)] = ai
            s.applyParams()
            sounds.append(s)
            if let h = handle { h.system = self; h.sound = s; handles.append((h, s)) }
            return true
        }
    }
    private var soundArchiveTag: [ObjectIdentifier: Int] = [:]
    private func archiveTag(_ s: SeqSound) -> Int { soundArchiveTag[ObjectIdentifier(s)] ?? 0 }

    private func cachedSeq(_ k: String, _ a: SoundArchive, _ f: Int) -> SeqFile? {
        if let s = seqCache[k] { return s }
        guard let d = a.fileData(f), let s = try? SeqFile(d) else { return nil }
        seqCache[k] = s; return s
    }
    private func cachedBank(_ k: String, _ a: SoundArchive, _ b: Int) -> LoadedBank? {
        if let s = bankCache[k] { return s }
        guard b < a.banks.count, let d = a.fileData(a.banks[b].fileID), let w = a.waveData(a.banks[b].fileID),
              let f = try? BankFile(d) else { return nil }
        let lb = LoadedBank(file: f, waveData: w)
        bankCache[k] = lb; return lb
    }

    func stopSound(_ h: SoundHandle, fadeFrames: Int) {
        guard let s = h.sound else { return }
        if fadeFrames > 0 { s.fadeTarget = 0; s.fadeFrames = fadeFrames; s.stopAfterFade = true }
        else { kill(s) }
    }
    private func kill(_ s: SeqSound) {
        // nw4r stop: tracks release with the fastest release (127) → near-instant fade, no click
        for t in s.player.tracks where t.open { t.releaseAll(127); t.freeAll(); t.open = false }
        s.player.finished = true
        sounds.removeAll { $0 === s }
        handles.removeAll { if $0.1 === s { $0.0.sound = nil; return true }; return false }
    }

    /// BasicSound/SoundArchivePlayer::Update — call once per game frame (60 Hz).
    public func gameFrameUpdate() {
        locked {
            for s in sounds {
                s.gameFrameUpdate()
                if s.stopAfterFade && s.fadeFrames == 0 && s.fadeVolume == 0 { kill(s) }
            }
            for s in sounds where s.isFinished { kill(s) }
        }
    }

    /// Render one AX frame (96 samples) into L/R.
    private func renderFrame(_ L: inout [Float], _ R: inout [Float]) {
        for s in sounds { s.player.update() }
        for c in channels { c.update(tables, periodic: true) }
        let n = SoundSystem.samplesPerFrame
        var AL = [Float](repeating: 0, count: n), AR = AL
        for c in channels { c.mix(into: &L, &R, aux: &AL, &AR, n: n, outRate: SoundSystem.outputRate) }
        channels.removeAll { !$0.active }
        // AUX C → FxReverbHi (installed by sound_manager Init via AxManager::AppendEffect(AUX_C, ...))
        reverb.process(&AL, &AR)
        for i in 0..<n { L[i] += AL[i]; R[i] += AR[i] }
    }

    private var pendL: [Float] = [], pendR: [Float] = []
    /// Pull `count` stereo samples at 32 kHz (audio thread or offline).
    public func render(count: Int, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>) {
        locked {
            var written = 0
            while written < count {
                if pendL.isEmpty {
                    var L = [Float](repeating: 0, count: SoundSystem.samplesPerFrame), R = L
                    renderFrame(&L, &R)
                    pendL = L; pendR = R
                }
                let k = min(count - written, pendL.count)
                for i in 0..<k {
                    left[written + i] = max(-1, min(1, pendL[i] * masterVolume))
                    right[written + i] = max(-1, min(1, pendR[i] * masterVolume))
                }
                pendL.removeFirst(k); pendR.removeFirst(k)
                written += k
            }
        }
    }

    public static var unknownSeqCommands: [Int] { SeqTrack.unknownCommands.sorted() }
    public static var auxBusesUsed: [Int] { SeqTrack.fxSendSeen.sorted() }
    public var activeChannelCount: Int { locked { channels.count } }
    public var activeSoundCount: Int { locked { sounds.count } }
}
