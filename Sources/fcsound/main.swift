import Forecast
import Foundation
import NW4R

// Sound track dev tool.
//   fcsound list [--home]
//   fcsound play <name|id> [--home] [--seconds N] [--wav out.wav] [--volume v --pitch p]
let args = CommandLine.arguments
func opt(_ k: String) -> String? { args.firstIndex(of: k).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }

do {
    let sm = try SoundManager(assets: try Assets())
    let home = args.contains("--home")
    guard let ai = home ? sm.homeArchive : sm.weatherArchive else { print("no HOME archive"); exit(1) }
    let a = sm.system.archive(ai)
    let cmd = args.count > 1 ? args[1] : "list"
    if cmd == "list" {
        print("players:", a.players.enumerated().map { "\($0.offset):\($0.element.name)x\($0.element.playableSoundCount)" }.joined(separator: " "))
        for (i, s) in a.sounds.enumerated() {
            print(String(format: "%3d 0x%02X %-28@ %@ player %2d vol %3d prio %3d label %5d tracks %04X curve %d", i, i, s.name as NSString,
                         "\(s.type.map { "\($0)" } ?? "?")", s.playerID, s.volume, s.playerPriority, s.seqLabelOffset, s.seqAllocTrack, s.panCurve))
        }
        exit(0)
    }
    if cmd == "all" { // render every sound offline for N seconds, report stats + interpreter coverage
        let secs = Double(opt("--seconds") ?? "3") ?? 3
        for (id, snd) in a.sounds.enumerated() {
            let h = SoundHandle()
            guard sm.system.startSound(archive: ai, id: id, handle: h) else { print("\(id) \(snd.name): FAILED to start"); continue }
            let total = Int(secs * 32000)
            var L = [Float](repeating: 0, count: total), R = L, done = 0, next = 0.0
            while done < total {
                let c = min(96, total - done)
                L.withUnsafeMutableBufferPointer { lp in R.withUnsafeMutableBufferPointer { rp in
                    sm.system.render(count: c, left: lp.baseAddress! + done, right: rp.baseAddress! + done) } }
                done += c; if Double(done) >= next { sm.update(); next += 32000.0 / 60 }
            }
            let peak = zip(L, R).map { max(abs($0), abs($1)) }.max() ?? 0
            print(String(format: "%3d %-30@ peak %.3f %@", id, snd.name as NSString, peak, peak < 1e-4 ? "SILENT" : ""))
            h.stop(); for _ in 0..<200 { var l = [Float](repeating: 0, count: 96), r = l; sm.system.render(count: 96, left: &l, right: &r); sm.update() }
        }
        print("unknown seq commands:", SoundSystem.unknownSeqCommands.map { String(format: "0x%X", $0) }, "aux buses sent to:", SoundSystem.auxBusesUsed)
        exit(0)
    }
    guard cmd == "play", args.count > 2 else { print("usage: fcsound list | play <name|id>"); exit(1) }
    let key = args[2]
    guard let id = Int(key) ?? a.soundID(named: key) else { print("unknown sound \(key)"); exit(1) }
    let seconds = Double(opt("--seconds") ?? "8") ?? 8
    let h = SoundHandle()
    guard sm.system.startSound(archive: ai, id: id, handle: h) else { print("could not start \(id)"); exit(1) }
    if let v = opt("--volume").flatMap(Float.init) { h.setVolume(v) }
    if let p = opt("--pitch").flatMap(Float.init) { h.setPitch(p) }
    print("playing \(id) \(a.sounds[id].name)")

    if let wav = opt("--wav") {
        // Offline render at 32 kHz, game-frame updates every 1/60 s.
        let total = Int(seconds * 32000)
        var L = [Float](repeating: 0, count: total), R = L
        var done = 0, nextFrame = 0.0, endedAt: Int?
        while done < total {
            let chunk = min(96, total - done)
            L.withUnsafeMutableBufferPointer { lp in R.withUnsafeMutableBufferPointer { rp in
                sm.system.render(count: chunk, left: lp.baseAddress! + done, right: rp.baseAddress! + done) } }
            done += chunk
            if Double(done) >= nextFrame { sm.update(); nextFrame += 32000.0 / 60 }
            if endedAt == nil && !h.isAttached && sm.system.activeChannelCount == 0 { endedAt = done }
        }
        var peak: Float = 0, sum: Double = 0, lastNZ = 0, firstNZ = -1, clipped = 0
        for i in 0..<total {
            let m = max(abs(L[i]), abs(R[i]))
            peak = max(peak, m); sum += Double(L[i] * L[i] + R[i] * R[i]) / 2
            if m > 1e-4 { lastNZ = i; if firstNZ < 0 { firstNZ = i } }
            if m >= 0.999 { clipped += 1 }
        }
        print(String(format: "peak %.3f rms %.4f  sound from %.3fs to %.3fs  ended %@  clipped %d samples",
                     peak, sqrt(sum / Double(total)), Double(max(firstNZ, 0)) / 32000, Double(lastNZ) / 32000,
                     endedAt.map { String(format: "%.2fs", Double($0) / 32000) } ?? "no", clipped))
        // 16-bit stereo WAV
        var d = Data()
        func w32(_ v: UInt32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func w16(_ v: UInt16) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 2)) }
        d.append("RIFF".data(using: .ascii)!); w32(UInt32(36 + total * 4)); d.append("WAVEfmt ".data(using: .ascii)!)
        w32(16); w16(1); w16(2); w32(32000); w32(32000 * 4); w16(4); w16(16)
        d.append("data".data(using: .ascii)!); w32(UInt32(total * 4))
        for i in 0..<total { w16(UInt16(bitPattern: Int16(L[i] * 32767))); w16(UInt16(bitPattern: Int16(R[i] * 32767))) }
        try d.write(to: URL(fileURLWithPath: wav))
        print("wrote \(wav)")
    } else {
        try sm.startOutput()
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { sm.update(); Thread.sleep(forTimeInterval: 1.0 / 60) }
    }
} catch {
    print("error: \(error)"); exit(1)
}
