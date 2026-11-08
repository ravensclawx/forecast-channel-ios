import Foundation
import RVL

/// Numeric tables used by nw4r::snd (envelope, LFO, pitch, volume, pan).
/// They are read at runtime from the channel's own main.dol (.rodata of HAFE v7), so the engine's
/// curves are exactly the console's. Addresses were located in the DOL (decomp/notes/sound.md).
public final class SndTables {
    public let attack: [Float]        // EnvGenerator attack multipliers [128]      @ 0x80195938
    public let decibelSquare: [Int16] // EnvGenerator sustain dB*10 [128]           @ 0x80195838
    public let lfoSin: [UInt8]        // Lfo quarter sine [33]                      @ 0x80195B50
    public let note: [Float]          // Util::NoteTable [12]                       @ 0x80195BA0
    public let pitch: [Float]         // Util::PitchTable [256]                     @ 0x80195BD0
    public let decibelToRatio: [Float] // Util::Decibel2RatioTable [965] (-90.4..+6.0 dB) @ 0x80195FD0
    public let panSqrt: [Float]       // Util::Pan2RatioTableSqrt [257]             @ 0x80196EE4
    /// sound_manager.cpp's FxReverbHi parameter block (lbl_8018F798): preDelay, time, coloration, damping, crosstalk, outGain.
    public let channelReverbParam: [Float]

    public static let volumeMinDB: Float = -90.4, volumeMaxDB: Float = 6.0

    public init(dol: [UInt8]) throws {
        let r = BEReader(dol)
        let offs = (0..<18).map { Int(r.u32($0 * 4)) }, addrs = (0..<18).map { Int(r.u32(72 + $0 * 4)) }
        let sizes = (0..<18).map { Int(r.u32(144 + $0 * 4)) }
        func fo(_ a: Int) throws -> Int {
            for i in 0..<18 where sizes[i] > 0 && a >= addrs[i] && a < addrs[i] + sizes[i] { return offs[i] + a - addrs[i] }
            throw RVLError.missing(String(format: "DOL address %08X", a))
        }
        func floats(_ a: Int, _ n: Int) throws -> [Float] { let o = try fo(a); return (0..<n).map { r.f32(o + $0 * 4) } }
        attack = try floats(0x8019_5938, 128)
        let ds = try fo(0x8019_5838)
        decibelSquare = (0..<128).map { r.s16(ds + $0 * 2) }
        let ls = try fo(0x8019_5B50)
        lfoSin = (0..<33).map { r.u8(ls + $0) }
        note = try floats(0x8019_5BA0, 12)
        pitch = try floats(0x8019_5BD0, 256)
        decibelToRatio = try floats(0x8019_5FD0, 965)
        panSqrt = try floats(0x8019_6EE4, 257)
        channelReverbParam = try floats(0x8018_F798, 6)
        // Sanity: these must be the nw4r tables (catches a different DOL revision).
        guard attack[0] > 0.999, attack[127] == 0, decibelSquare[127] == 0, note[0] == 1, decibelToRatio[904] == 1, panSqrt[0] == 1 else {
            throw RVLError.corrupt("nw4r::snd tables not found at the HAFE v7 addresses")
        }
    }

    /// Util::CalcPitchRatio — `pitch` in 1/256 semitones.
    public func pitchRatio(_ p: Int) -> Float {
        var pitch = p, octave = 0
        while pitch < 0 { octave -= 1; pitch += 12 * 256 }
        while pitch >= 12 * 256 { octave += 1; pitch -= 12 * 256 }
        var ratio: Float = 1
        while octave > 0 { ratio *= 2; octave -= 1 }
        while octave < 0 { ratio /= 2; octave += 1 }
        let n = pitch / 256, m = pitch % 256
        if n != 0 { ratio *= note[n] }
        if m != 0 { ratio *= self.pitch[m] }
        return ratio
    }

    /// Util::CalcVolumeRatio — dB → linear, 0.1 dB steps.
    public func volumeRatio(_ db: Float) -> Float {
        let d = min(max(db, SndTables.volumeMinDB), SndTables.volumeMaxDB)
        return decibelToRatio[904 + Int(10 * d)]
    }

    public enum PanCurve: Int { case sqrt = 0, sqrt0dB, sqrt0dBClamp, sinCos, sinCos0dB, sinCos0dBClamp, linear, linear0dB, linear0dBClamp }

    /// Util::CalcPanRatio with the curve flags Voice::CalcMixParam derives from PanCurve.
    public func panRatio(_ pan: Float, curve: PanCurve) -> Float {
        let p = (min(max(pan, -1), 1) + 1) / 2
        let idx = Int(p * 256 + 0.5)
        func tbl(_ i: Int) -> Float {
            switch curve {
            case .sqrt, .sqrt0dB, .sqrt0dBClamp: return panSqrt[i]
            // Only the sqrt table is linked into this DOL; the others are defined by formula (nw4r Util.h).
            case .sinCos, .sinCos0dB, .sinCos0dBClamp: return Float(cos(Double(i) * .pi / 512))
            default: return 1 - Float(i) / 256
            }
        }
        var ratio = tbl(idx)
        let centerZero = ![.sqrt, .sinCos, .linear].contains(curve)
        let zeroClamp = [.sqrt0dBClamp, .sinCos0dBClamp, .linear0dBClamp].contains(curve)
        if centerZero { ratio /= tbl(128) }
        return zeroClamp ? min(max(ratio, 0), 1) : min(max(ratio, 0), 2)
    }

    /// Util::CalcRandom (LCG).
    private var seed: UInt32 = 0x1234_5678
    public func random() -> UInt16 { seed = seed &* 0x19660D &+ 0x3C6E_F35F; return UInt16(seed >> 16) }
}
