import RVL

/// nw4r::snd SoundArchive (RSAR v1.x): SYMB names, INFO tables, FILE data (via groups).
public final class SoundArchive {
    public enum SoundType: UInt8 { case seq = 1, strm = 2, wave = 3 }
    public struct SoundInfo {
        public let name: String, fileID: Int, playerID: Int, volume: Int, playerPriority: Int, type: SoundType?
        public let panMode: Int, panCurve: Int
        // SEQ detail
        public let seqLabelOffset: Int, seqBankID: Int, seqAllocTrack: UInt32, seqChannelPriority: Int
    }
    public struct PlayerInfo { public let name: String, playableSoundCount: Int }
    public struct BankInfo { public let name: String, fileID: Int }
    struct FileLoc { let offset: Int, size: Int, waveOffset: Int, waveSize: Int }

    public let data: [UInt8]
    public private(set) var sounds: [SoundInfo] = []
    public private(set) var players: [PlayerInfo] = []
    public private(set) var banks: [BankInfo] = []
    private var files: [Int: FileLoc] = [:]

    public init(_ bytes: [UInt8]) throws {
        let r = BEReader(bytes)
        guard r.magic(0) == "RSAR" else { throw RVLError.badMagic(r.magic(0), expected: "RSAR") }
        data = bytes
        let symb = Int(r.u32(0x10)), info = Int(r.u32(0x18))
        var strings: [String] = []
        if symb != 0 {
            let sb = symb + 8, st = sb + Int(r.u32(sb))
            strings = (0..<Int(r.u32(st))).map { r.cString(sb + Int(r.u32(st + 4 + $0 * 4))) }
        }
        func name(_ id: UInt32) -> String { Int(id) < strings.count ? strings[Int(id)] : "#\(id)" }
        let ib = info + 8
        func table(_ refAt: Int) -> [Int] {
            let t = ib + Int(r.u32(refAt + 4))
            return (0..<Int(r.u32(t))).map { ib + Int(r.u32(t + 4 + $0 * 8 + 4)) }
        }
        for o in table(ib) {
            let det = ib + Int(r.u32(o + 0x1C))
            let type = SoundArchive.SoundType(rawValue: r.u8(o + 0x16))
            sounds.append(SoundInfo(name: name(r.u32(o)), fileID: Int(r.u32(o + 4)), playerID: Int(r.u32(o + 8)),
                                    volume: Int(r.u8(o + 0x14)), playerPriority: Int(r.u8(o + 0x15)), type: type,
                                    panMode: Int(r.u8(o + 0x2C)), panCurve: Int(r.u8(o + 0x2D)),
                                    seqLabelOffset: type == .seq ? Int(r.u32(det)) : 0, seqBankID: type == .seq ? Int(r.u32(det + 4)) : 0,
                                    seqAllocTrack: type == .seq ? r.u32(det + 8) : 0, seqChannelPriority: type == .seq ? Int(r.u8(det + 12)) : 64))
        }
        banks = table(ib + 8).map { BankInfo(name: name(r.u32($0)), fileID: Int(r.u32($0 + 4))) }
        players = table(ib + 16).map { PlayerInfo(name: name(r.u32($0)), playableSoundCount: Int(r.u8($0 + 4))) }
        // Groups locate file bodies and their wave data inside the archive.
        for g in table(ib + 32) {
            let base = Int(r.u32(g + 0x10)), wbase = Int(r.u32(g + 0x18))
            let items = ib + Int(r.u32(g + 0x24))
            for i in 0..<Int(r.u32(items)) {
                let it = ib + Int(r.u32(items + 4 + i * 8 + 4))
                let fid = Int(r.u32(it))
                if files[fid] == nil {
                    files[fid] = FileLoc(offset: base + Int(r.u32(it + 4)), size: Int(r.u32(it + 8)),
                                         waveOffset: wbase + Int(r.u32(it + 12)), waveSize: Int(r.u32(it + 16)))
                }
            }
        }
    }

    public func fileData(_ id: Int) -> [UInt8]? { files[id].map { Array(data[$0.offset..<($0.offset + $0.size)]) } }
    public func waveData(_ id: Int) -> [UInt8]? { files[id].map { Array(data[$0.waveOffset..<($0.waveOffset + $0.waveSize)]) } }
    public func soundID(named n: String) -> Int? { sounds.firstIndex { $0.name == n } }
}

/// RSEQ: sequence data + labels.
public struct SeqFile {
    public let data: [UInt8]       // the DATA block's sequence stream
    public let labels: [String: Int]
    public init(_ bytes: [UInt8]) throws {
        let r = BEReader(bytes)
        guard r.magic(0) == "RSEQ" else { throw RVLError.badMagic(r.magic(0), expected: "RSEQ") }
        let dataBlk = Int(r.u32(0x10)), lablBlk = Int(r.u32(0x18))
        let start = dataBlk + Int(r.u32(dataBlk + 8))
        data = Array(bytes[start..<(dataBlk + Int(r.u32(dataBlk + 4)))])
        var l: [String: Int] = [:]
        if lablBlk != 0 {
            let lb = lablBlk + 8
            for i in 0..<Int(r.u32(lb)) {
                let e = lb + Int(r.u32(lb + 4 + i * 4))
                l[String(decoding: r.bytes(e + 8, Int(r.u32(e + 4))), as: UTF8.self)] = Int(r.u32(e))
            }
        }
        labels = l
    }
}

/// RBNK: instruments (InstParam via key/velocity region tables) + wave infos.
public final class BankFile {
    public struct InstInfo { public let waveIndex: Int, attack: Int, decay: Int, sustain: Int, release: Int, originalKey: Int, volume: Int, pan: Int, tune: Float }
    public struct WaveInfo {
        public let format: Int, loop: Bool, channels: Int, sampleRate: Int
        public let loopStartSample: Int, loopEndSample: Int  // loopEnd exclusive
        public let channelDataOffsets: [Int]                  // relative to the bank's wave data
        public let adpcm: [[Int16]]                          // per channel: coef[16]
        public let initialHistory: [(Int16, Int16)]
    }

    let r: BEReader
    let instBase: Int
    let instCount: Int
    public private(set) var waves: [WaveInfo] = []

    public init(_ bytes: [UInt8]) throws {
        r = BEReader(bytes)
        guard r.magic(0) == "RBNK" else { throw RVLError.badMagic(r.magic(0), expected: "RBNK") }
        let dataBlk = Int(r.u32(0x10)), waveBlk = Int(r.u32(0x18))
        instBase = dataBlk + 8
        instCount = Int(r.u32(instBase))
        let wb = waveBlk + 8
        for i in 0..<Int(r.u32(wb)) {
            let w = wb + Int(r.u32(wb + 4 + i * 8 + 4))
            waves.append(BankFile.waveInfo(r, w))
        }
    }

    /// RWAV-style WaveInfo. Loop addresses are DSP nibble addresses → converted to samples
    /// (AxVoice::GetSampleByDspAddress: 14 samples per 16-nibble frame, minus the 2 header nibbles).
    static func waveInfo(_ r: BEReader, _ w: Int) -> WaveInfo {
        let format = Int(r.u8(w)), loop = r.u8(w + 1) != 0, ch = Int(r.u8(w + 2))
        let rate = Int(r.u8(w + 3)) << 16 | Int(r.u16(w + 4))
        func toSample(_ a: UInt32) -> Int {
            switch format {
            case 2: let n = Int(a); return n % 16 + n / 16 * 14 - 2
            case 1: return Int(a) / 2
            default: return Int(a)
            }
        }
        let ls = toSample(r.u32(w + 8)), le = toSample(r.u32(w + 12)) + 1
        let cit = w + Int(r.u32(w + 16))
        let dataLoc = Int(r.u32(w + 20))
        var offs: [Int] = [], coefs: [[Int16]] = [], hist: [(Int16, Int16)] = []
        for c in 0..<ch {
            let ci = w + Int(r.u32(cit + c * 4))
            offs.append(dataLoc + Int(r.u32(ci)))
            let ai = w + Int(r.u32(ci + 4))
            coefs.append((0..<16).map { r.s16(ai + $0 * 2) })
            hist.append((r.s16(ai + 0x24), r.s16(ai + 0x26)))
        }
        return WaveInfo(format: format, loop: loop, channels: ch, sampleRate: rate, loopStartSample: ls, loopEndSample: le,
                        channelDataOffsets: offs, adpcm: coefs, initialHistory: hist)
    }

    /// BankFileReader::ReadInstInfo — program → key region → velocity region → InstParam.
    public func instInfo(program: Int, key: Int, velocity: Int) -> InstInfo? {
        guard program >= 0, program < instCount else { return nil }
        var ref = instBase + 4 + program * 8
        for split in [key, velocity] {
            let t = Int(r.u8(ref + 1))
            if t == 0 { return nil }
            if t == 1 { break }
            guard let sub = subRegion(ref, split) else { return nil }
            ref = sub
        }
        guard r.u8(ref + 1) == 1 else { return nil }
        let p = instBase + Int(r.u32(ref + 4))
        let wave = Int(r.s32(p))
        guard wave >= 0 else { return nil }
        return InstInfo(waveIndex: wave, attack: Int(r.u8(p + 4)), decay: Int(r.u8(p + 5)), sustain: Int(r.u8(p + 6)),
                        release: Int(r.u8(p + 7)), originalKey: Int(r.u8(p + 0xC)), volume: Int(r.u8(p + 0xD)),
                        pan: Int(r.u8(p + 0xE)), tune: r.f32(p + 0x10))
    }

    private func subRegion(_ ref: Int, _ split: Int) -> Int? {
        let t = Int(r.u8(ref + 1))
        let tbl = instBase + Int(r.u32(ref + 4))
        switch t {
        case 2: // RangeTable: u8 count, u8 key[count], refs (4-aligned) follow
            let n = Int(r.u8(tbl))
            var i = 0
            while i < n && split > Int(r.u8(tbl + 1 + i)) { i += 1 }
            guard i < n else { return nil }
            return tbl + ((1 + n + 3) & ~3) + i * 8
        case 3: // IndexTable: u8 min, u8 max, u16 pad, refs
            let lo = Int(r.u8(tbl)), hi = Int(r.u8(tbl + 1))
            guard split >= lo, split <= hi else { return nil }
            return tbl + 4 + (split - lo) * 8
        default: return nil
        }
    }
}

/// DSP-ADPCM (GC/Wii DSP "4-bit ADPCM") → PCM. 8-byte frames: ps header + 14 nibbles.
public enum DSPADPCM {
    public static func decode(_ src: [UInt8], offset: Int, samples: Int, coefs: [Int16], hist: (Int16, Int16)) -> [Float] {
        var out = [Float](repeating: 0, count: samples)
        var h1 = Int32(hist.0), h2 = Int32(hist.1)
        var p = offset, n = 0
        while n < samples, p < src.count {
            let ps = Int(src[p]); p += 1
            let scale = Int32(1) << Int32(ps & 0xF), ci = (ps >> 4) * 2
            let c1 = Int32(coefs[ci]), c2 = Int32(coefs[ci + 1])
            for i in 0..<14 where n < samples {
                guard p < src.count else { break }
                let byte = src[p]
                var nib = Int32(i & 1 == 0 ? byte >> 4 : byte & 0xF)
                if nib >= 8 { nib -= 16 }
                if i & 1 == 1 { p += 1 }
                var s = ((nib * scale) << 11) + 1024 + (c1 * h1 + c2 * h2)
                s >>= 11
                s = min(max(s, -32768), 32767)
                h2 = h1; h1 = s
                out[n] = Float(s) / 32768; n += 1
            }
        }
        return out
    }
}
