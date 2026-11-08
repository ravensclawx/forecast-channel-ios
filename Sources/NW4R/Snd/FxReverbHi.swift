import Foundation

/// AUX-bus reverb modelled on AXFX ReverbHi (nw4r::snd::FxReverbHi), driven by the channel's own parameter
/// block (main.dol 0x8018F798: preDelay 0.1 s, time 2.1 s, coloration 0.6, damping 0.4, crosstalk 0.1, outGain 0.2).
/// Structure follows AXFX's: per-channel pre-delay → early reflection taps → 3 damped feedback combs →
/// 2 allpasses, with left/right crosstalk. APPROXIMATION: AXFX's exact delay lengths/coefficients are not
/// yet decompiled from the DOL (decomp/notes/sound.md, open question).
final class FxReverbHi {
    struct Param { var preDelay: Float = 0.1, time: Float = 2.1, coloration: Float = 0.6, damping: Float = 0.4, crosstalk: Float = 0.1, outGain: Float = 0.2 }

    private final class Line {
        var buf: [Float]; var i = 0
        init(_ n: Int) { buf = [Float](repeating: 0, count: max(n, 1)) }
        @inline(__always) func read() -> Float { buf[i] }
        @inline(__always) func write(_ v: Float) { buf[i] = v; i += 1; if i == buf.count { i = 0 } }
    }
    private final class Comb {
        let line: Line; let g: Float; let damp: Float; var lp: Float = 0
        init(_ n: Int, g: Float, damp: Float) { line = Line(n); self.g = g; self.damp = damp }
        @inline(__always) func process(_ x: Float) -> Float {
            let y = line.read()
            lp = y + damp * (lp - y)
            line.write(x + lp * g)
            return y
        }
    }
    private final class AllPass {
        let line: Line; let g: Float
        init(_ n: Int, g: Float) { line = Line(n); self.g = g }
        @inline(__always) func process(_ x: Float) -> Float {
            let d = line.read(), v = x + g * d
            line.write(v)
            return d - g * v
        }
    }

    private let pre: [Line]
    private let combs: [[Comb]]
    private let aps: [[AllPass]]
    private let p: Param

    init(rate: Float, param: Param = Param()) {
        p = param
        func n(_ ms: Float) -> Int { Int(ms / 1000 * rate) }
        pre = [Line(n(param.preDelay * 1000)), Line(n(param.preDelay * 1000) + 7)]
        // Mutually prime comb lengths (ms), offset per channel for stereo decorrelation.
        let combMs: [[Float]] = [[35.3, 40.6, 44.9], [36.1, 41.3, 45.7]]
        combs = combMs.map { ms in ms.map { d in
            Comb(n(d), g: pow(10, -3 * d / 1000 / max(param.time, 0.01)), damp: param.damping) } }
        let apMs: [[Float]] = [[5.0, 1.7], [5.3, 1.9]]
        aps = apMs.map { ms in ms.map { AllPass(n($0), g: param.coloration) } }
    }

    /// In-place: AUX buffers in → wet signal out.
    func process(_ L: inout [Float], _ R: inout [Float]) {
        let x = p.crosstalk
        for i in 0..<L.count {
            let inL = L[i] * (1 - x) + R[i] * x, inR = R[i] * (1 - x) + L[i] * x
            var outs: [Float] = [0, 0]
            for c in 0..<2 {
                let d = pre[c].read(); pre[c].write(c == 0 ? inL : inR)
                var s: Float = 0
                for comb in combs[c] { s += comb.process(d) }
                s /= 3
                for ap in aps[c] { s = ap.process(s) }
                outs[c] = s * p.outGain
            }
            L[i] = outs[0]; R[i] = outs[1]
        }
    }
}
