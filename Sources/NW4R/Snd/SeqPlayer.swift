/// Sequence playback: SeqPlayer (tempo/ticks, variables) and SeqTrack (MML command interpreter).
/// Semantics follow nw4r::snd's MmlParser / SeqTrack / SeqPlayer (decomp/notes/sound.md).

final class SeqTrack {
    /// Dev diagnostic: command bytes the interpreter didn't recognize (should stay empty).
    nonisolated(unsafe) static var unknownCommands = Set<Int>()
    nonisolated(unsafe) static var fxSendSeen = Set<Int>()
    unowned let player: SeqPlayer
    let index: Int
    var open = false
    var pc = 0
    var wait = 0
    var noteFinishWait = false
    // Parser track params (defaults per SeqTrack::InitParam)
    var volume = 127, volume2 = 127, pan = 0, initPan = 0, surroundPan = 0
    var transpose = 0, pitchBend = 0, bendRange = 2, priority = 64, prgNo = 0, bankNo = 0
    var attack = 0xFF, decay = 0xFF, sustain = 0xFF, release = 0xFF
    var lfoDepth: Float = 0, lfoSpeed: Float = 6.25, lfoRange: Float = 1, lfoDelay = 0, lfoTarget = 0
    var sweepPitch: Float = 0, portaKey = 60, portaTime = 0, portaFlag = false
    var damper = false, mute = false, silence = false
    var lpfFreq = 64, mainSend = 127
    var fxSend = [0, 0, 0]
    // MML parser params
    var noteWait = true, tie = false, cmpFlag = true
    var callStack: [Int] = [], loopCounts: [Int] = []
    var vars = [Int16](repeating: -1, count: 16)
    var channels: [Channel] = []

    init(player: SeqPlayer, index: Int) { self.player = player; self.index = index }

    func start(at offset: Int) {
        pc = offset; open = true; wait = 0; noteFinishWait = false
        callStack = []; loopCounts = []
    }

    func close() { releaseAll(-1); freeAll(); open = false }
    func releaseAll(_ rel: Int) {
        updateChannelParams()
        for c in channels where c.active {
            if rel >= 0 { c.env.release = EnvGenerator.rate(rel) }
            c.release()
        }
    }
    func freeAll() { for c in channels { c.track = nil }; channels.removeAll() }

    /// SeqTrack::UpdateChannelLength (per tick).
    func updateChannelLength() {
        guard open else { return }
        channels.removeAll { !$0.active }
        for c in channels {
            if c.length > 0 { c.length -= 1 }
            if c.length == 0 && !c.isReleasing && !damper { c.release() }
            if !c.autoSweep { c.updateSweep(1) }
        }
    }

    /// SeqTrack::UpdateChannelParam.
    func updateChannelParams() {
        guard open else { return }
        var v = Float(volume) / 127; v *= v
        var v2 = Float(volume2) / 127; v2 *= v2
        var pv = Float(player.parserVolume) / 127; pv *= pv
        let vol = v * v2 * pv * player.volume
        let pitch = Float(pitchBend) / 128 * Float(bendRange)
        let p = min(max(Float(pan) / 63, -1), 1) + player.pan
        let send = Float(mainSend) / 127 - 1
        for c in channels {
            c.userVolume = vol; c.userPitch = pitch; c.userPitchRatio = player.pitch
            c.userPan = p; c.mainSend = send
            c.fxSendC = Float(fxSend[2]) / 127
            c.lfo.depth = lfoDepth; c.lfo.speed = lfoSpeed; c.lfo.range = lfoRange; c.lfo.delay = lfoDelay
            c.lfoTarget = Channel.LfoTarget(rawValue: lfoTarget) ?? .pitch
        }
    }

    /// SeqTrack::ParseNextTick → 1 continue, -1 finished.
    func parseNextTick(noteOn: Bool) -> Int {
        guard open else { return 0 }
        if noteFinishWait {
            channels.removeAll { !$0.active }
            if !channels.isEmpty { return 1 }
            noteFinishWait = false
        }
        if wait > 0 { wait -= 1; if wait > 0 { return 1 } }
        var guardCount = 0
        while wait == 0 && !noteFinishWait {
            if !step(noteOn: noteOn) { return -1 }
            guardCount += 1
            if guardCount > 100_000 { return -1 } // runaway loop protection
        }
        return 1
    }

    // MARK: MML interpreter

    private var d: [UInt8] { player.seq.data }
    private func u8() -> Int { guard pc < d.count else { return 0xFF }; defer { pc += 1 }; return Int(d[pc]) }
    private func u16() -> Int { (u8() << 8) | u8() }
    private func u24() -> Int { (u8() << 16) | (u8() << 8) | u8() }
    private func vlq() -> Int { var v = 0, b = 0; repeat { b = u8(); v = (v << 7) | (b & 0x7F) } while b & 0x80 != 0; return v }

    private enum ArgKind { case u8, s16, vmidi, random, variable }
    private func arg(_ kind: ArgKind) -> Int {
        switch kind {
        case .u8: return u8()
        case .s16: return Int(Int16(truncatingIfNeeded: u16()))
        case .vmidi: return vlq()
        case .variable: return Int(player.variable(u8(), track: self) ?? 0)
        case .random:
            let lo = Int(Int16(truncatingIfNeeded: u16())), hi = Int(Int16(truncatingIfNeeded: u16()))
            return (Int(player.tables.random()) * (hi - lo + 1)) >> 16 + lo
        }
    }

    /// Execute one command. Returns false at FIN.
    private func step(noteOn: Bool) -> Bool {
        var cmd = u8()
        var exec = true
        var override: ArgKind?
        if cmd == 0xA2 { cmd = u8(); exec = cmpFlag }
        if cmd == 0xA0 { cmd = u8(); override = .random }
        if cmd == 0xA1 { cmd = u8(); override = .variable }

        if cmd < 0x80 { // note
            let velocity = u8()
            let length = arg(override ?? .vmidi)
            guard exec else { return true }
            let k = min(max(cmd + transpose, 0), 127)
            if !mute && noteOn { noteOnCommand(key: k, velocity: velocity, length: length > 0 ? length : -1) }
            if noteWait { wait = length; if length == 0 { noteFinishWait = true } }
            return true
        }
        switch cmd & 0xF0 {
        case 0x80:
            switch cmd {
            case 0x80: let t = arg(override ?? .vmidi); if exec { wait = t }
            case 0x81: let a = arg(override ?? .vmidi); if exec && a < 128 { prgNo = a & 0x7F }
            case 0x88:
                let tr = u8(), off = u24()
                if exec, let t = player.track(tr), t !== self { t.close(); t.start(at: off) }
            case 0x89: let off = u24(); if exec { pc = off }
            case 0x8A:
                let off = u24()
                if exec && callStack.count < 3 { callStack.append(pc); loopCounts.append(0); pc = off }
            default: SeqTrack.unknownCommands.insert(cmd)
            }
        case 0x90: break
        case 0xB0, 0xC0, 0xD0:
            let raw = arg(override ?? .u8)
            guard exec else { return true }
            let a = (cmd == 0xC3 || cmd == 0xC4) ? Int(Int8(truncatingIfNeeded: raw)) : (raw & 0xFF)
            command(cmd, a)
        case 0xE0:
            let a = arg(override ?? .s16)
            guard exec else { return true }
            switch cmd {
            case 0xE0: lfoDelay = a * 5
            case 0xE1: player.tempo = a
            case 0xE3: sweepPitch = Float(a) / 32
            default: SeqTrack.unknownCommands.insert(cmd)
            }
        case 0xF0:
            switch cmd {
            case 0xFE: _ = u16()                 // alloctrack (handled from the sound info)
            case 0xFF: return false               // FIN
            case 0xFC: // loop end
                if exec, !callStack.isEmpty {
                    var c = loopCounts[loopCounts.count - 1]
                    if c != 0 { c -= 1 }
                    if loopCounts[loopCounts.count - 1] != 0 && c == 0 { callStack.removeLast(); loopCounts.removeLast() }
                    else { loopCounts[loopCounts.count - 1] = c; pc = callStack[callStack.count - 1] }
                }
            case 0xFD: // return
                if exec, !callStack.isEmpty { pc = callStack.removeLast(); loopCounts.removeLast() }
            case 0xF0:
                let ex = u8()
                switch ex & 0xF0 {
                case 0xE0: _ = arg(override ?? .s16) // userproc
                case 0x80, 0x90:
                    let v = u8(), val = arg(override ?? .s16)
                    if exec { exCommand(ex, v, Int16(truncatingIfNeeded: val)) }
                default: SeqTrack.unknownCommands.insert(0xF000 | ex)
                }
            default: SeqTrack.unknownCommands.insert(cmd)
            }
        default: SeqTrack.unknownCommands.insert(cmd)
        }
        return true
    }

    private func command(_ cmd: Int, _ a: Int) {
        switch cmd {
        case 0xB0: player.timebase = a
        case 0xC0: pan = a - 64
        case 0xC1: volume = a
        case 0xC2: player.parserVolume = a
        case 0xC3: transpose = a
        case 0xC4: pitchBend = a
        case 0xC5: bendRange = a
        case 0xC6: priority = a
        case 0xC7: noteWait = a != 0
        case 0xC8: tie = a != 0; releaseAll(-1); freeAll()
        case 0xC9: portaKey = a + transpose; portaFlag = true
        case 0xCA: lfoDepth = Float(UInt8(truncatingIfNeeded: a)) / 128
        case 0xCB: lfoSpeed = Float(UInt8(truncatingIfNeeded: a)) * (100.0 / 256.0)
        case 0xCC: lfoTarget = a
        case 0xCD: lfoRange = Float(a)
        case 0xCE: portaFlag = a != 0
        case 0xCF: portaTime = a
        case 0xD0: attack = a
        case 0xD1: decay = a
        case 0xD2: sustain = a
        case 0xD3: release = a
        case 0xD4: if callStack.count < 3 { callStack.append(pc); loopCounts.append(a) }
        case 0xD5: volume2 = a
        case 0xD7: surroundPan = a
        case 0xD8: lpfFreq = a
        case 0xD9: fxSend[0] = a; if a > 0 { SeqTrack.fxSendSeen.insert(0) }
        case 0xDA: fxSend[1] = a; if a > 0 { SeqTrack.fxSendSeen.insert(1) }
        case 0xDB: mainSend = a
        case 0xDC: initPan = a - 64
        case 0xDD: mute = a != 0
        case 0xDE: fxSend[2] = a; if a > 0 { SeqTrack.fxSendSeen.insert(2) }
        case 0xDF: damper = UInt8(truncatingIfNeeded: a) >= 64
        case 0xD6: break // printvar
        default: SeqTrack.unknownCommands.insert(cmd)
        }
    }

    private func exCommand(_ ex: Int, _ v: Int, _ val: Int16) {
        guard var x = player.variable(v, track: self) else { return }
        switch ex {
        case 0x80: x = val
        case 0x81: x = x &+ val
        case 0x82: x = x &- val
        case 0x83: x = x &* val
        case 0x84: if val != 0 { x /= val }
        case 0x85: x = val >= 0 ? x << val : x >> -val
        case 0x86:
            let neg = val < 0, m = Int(neg ? -Int(val) : Int(val))
            var r = (Int(player.tables.random()) * (m + 1)) >> 16
            if neg { r = -r }
            x = Int16(truncatingIfNeeded: r)
        case 0x87: x &= val
        case 0x88: x |= val
        case 0x89: x ^= val
        case 0x8A: x = Int16(truncatingIfNeeded: ~UInt16(bitPattern: val))
        case 0x8B: if val != 0 { x %= val }
        case 0x90: cmpFlag = x == val; return
        case 0x91: cmpFlag = x >= val; return
        case 0x92: cmpFlag = x > val; return
        case 0x93: cmpFlag = x <= val; return
        case 0x94: cmpFlag = x < val; return
        case 0x95: cmpFlag = x != val; return
        default: return
        }
        player.setVariable(v, track: self, x)
    }

    /// SeqTrack::NoteOn → SeqPlayer/Bank::NoteOn.
    private func noteOnCommand(key: Int, velocity: Int, length: Int) {
        var ch: Channel?
        if tie, let last = channels.last(where: { $0.active }) {
            last.key = key
            let iv = Float(velocity) / 127; last.initVolume = iv * iv
            ch = last
        }
        if ch == nil {
            guard let c = player.bankNoteOn(program: prgNo, key: key, velocity: velocity, length: tie ? -1 : length, initPan: initPan) else { return }
            c.track = self
            channels.append(c)
            ch = c
        }
        guard let c = ch else { return }
        if attack != 0xFF { c.env.attack = player.tables.attack[min(attack, 127)] }
        if decay != 0xFF { c.env.decay = EnvGenerator.rate(decay) }
        if sustain != 0xFF { c.env.sustain = min(sustain, 127) }
        if release != 0xFF { c.env.release = EnvGenerator.rate(release) }
        var sweep = sweepPitch
        if portaFlag { sweep += Float(portaKey - key) }
        if portaTime == 0 {
            c.setSweep(sweep, time: length, auto: false)
        } else {
            var time = portaTime * portaTime
            time = Int(Float(time) * abs(sweep))
            time = (time >> 5) << 2 + (time >> 5)
            c.setSweep(sweep, time: time, auto: true)
        }
        portaKey = key
    }
}

final class SeqPlayer {
    unowned let system: SoundSystem
    let tables: SndTables
    let seq: SeqFile
    let bank: LoadedBank
    var tracks: [SeqTrack] = []
    var tempo = 120, timebase = 48, parserVolume = 127
    var localVars = [Int16](repeating: -1, count: 16)
    var tickFraction: Float = 0
    var tempoRatio: Float = 1
    // External params (from the BasicSound / handle)
    var volume: Float = 1, pitch: Float = 1, pan: Float = 0
    var paused = false
    var finished = false
    let panCurve: SndTables.PanCurve

    init(system: SoundSystem, seq: SeqFile, bank: LoadedBank, startOffset: Int, allocTrack: UInt32, panCurve: SndTables.PanCurve) {
        self.system = system; tables = system.tables; self.seq = seq; self.bank = bank; self.panCurve = panCurve
        for i in 0..<16 where allocTrack & (1 << UInt32(i)) != 0 || i == 0 {
            tracks.append(SeqTrack(player: self, index: i))
        }
        tracks[0].start(at: startOffset)
    }

    func track(_ n: Int) -> SeqTrack? { tracks.first { $0.index == n } }

    func variable(_ i: Int, track: SeqTrack) -> Int16? {
        switch i {
        case 0..<16: return localVars[i]
        case 16..<32: return system.globalVars[i - 16]
        case 32..<48: return track.vars[i - 32]
        default: return nil
        }
    }
    func setVariable(_ i: Int, track: SeqTrack, _ v: Int16) {
        switch i {
        case 0..<16: localVars[i] = v
        case 16..<32: system.globalVars[i - 16] = v
        case 32..<48: track.vars[i - 32] = v
        default: break
        }
    }

    var baseTempo: Float { tempoRatio * Float(timebase * tempo) / 60000 }  // ticks per msec

    /// SeqPlayer::Update (one AX frame = 3 ms).
    func update() {
        guard !finished else { return }
        if !paused { updateTick(msec: 3) }
        for t in tracks { t.updateChannelParams() }
    }

    private func updateTick(msec: Int) {
        var tpm = baseTempo
        guard tpm > 0 else { return }
        var rest = Float(msec)
        var next = tickFraction / tpm
        while next < rest {
            rest -= next
            if parseNextTick() != 0 { finish(); return }
            tpm = baseTempo
            guard tpm > 0 else { return }
            next = 1 / tpm
        }
        next -= rest
        tickFraction = next * tpm
    }

    /// SeqPlayer::ParseNextTick: lengths first, then every track parses; finish when all tracks are closed.
    private func parseNextTick() -> Int {
        var active = false
        for t in tracks where t.open { t.updateChannelLength() }
        for t in tracks where t.open {
            if t.parseNextTick(noteOn: true) < 0 { t.close() } else { active = true }
        }
        return active ? 0 : 1
    }

    func finish() { finished = true; for t in tracks where t.open { t.close() } }
    func stopNow() { for t in tracks { for c in t.channels { c.stop() }; t.freeAll(); t.open = false }; finished = true }

    /// Bank::NoteOn — instrument lookup, wave, channel init.
    func bankNoteOn(program: Int, key: Int, velocity: Int, length: Int, initPan: Int) -> Channel? {
        guard let inst = bank.file.instInfo(program: program, key: key, velocity: velocity),
              let wave = bank.wave(inst.waveIndex) else { return nil }
        let c = Channel(wave: wave)
        c.key = key; c.originalKey = inst.originalKey
        var iv = Float(velocity) / 127; iv *= iv
        c.initVolume = iv * Float(inst.volume) / 127
        c.tune = inst.tune
        c.env.setup(tables, attack: inst.attack, decay: inst.decay, sustain: inst.sustain, release: inst.release)
        c.env.reset()
        c.initPan = Float(inst.pan - 64) / 63 + Float(initPan) / 63
        c.length = length
        c.panCurve = panCurve
        system.addChannel(c)
        return c
    }
}
