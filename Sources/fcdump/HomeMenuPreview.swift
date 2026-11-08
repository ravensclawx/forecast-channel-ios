import Forecast
import Foundation
import Metal

/// Offscreen HOME Menu preview: open the menu, run `frames` frames of scripted input, write a PNG.
/// script: comma-separated steps "frame:action" where action is one of
///   ptr=X/Y (move pointer, logical px), a (press A), b, plus, minus, home.
/// e.g. "0:ptr=304/420,60:a" opens the Wii Remote settings panel after the open animation.
public func renderHomeMenu(path: String, frames: Int, script: String, isWide: Bool = false) throws {
    let device = MTLCreateSystemDefaultDevice()!
    let assets = try Assets()
    let gx = GXMetal(device: device, colorFormat: .bgra8Unorm, depthFormat: .depth32Float)
    let lyt = LytRenderer(gx: gx)
    lyt.textureProvider = { assets.layoutTexture($0) }
    lyt.fontProvider = { assets.font($0) }
    let sound = try? SoundManager(assets: assets)
    let menu = try HomeMenu(assets: assets, renderer: lyt, sound: sound, isWide: isWide)
    let pad = KPad()
    var steps: [Int: [String]] = [:]
    for s in script.split(separator: ",") {
        let parts = s.split(separator: ":", maxSplits: 1)
        if parts.count == 2, let f = Int(parts[0]) { steps[f, default: []].append(String(parts[1])) }
    }
    var pointer = SIMD2<Float>(isWide ? 416 : 304, 228)
    menu.open()
    var lastEvent: HomeMenuEvent?
    for f in 0..<frames {
        var held: WPAD = []
        for act in steps[f] ?? [] {
            if act.hasPrefix("ptr=") {
                let v = act.dropFirst(4).split(separator: "/").compactMap { Float($0) }
                if v.count == 2 { pointer = SIMD2(v[0], v[1]) }
            } else {
                switch act { case "a": held.insert(.a); case "b": held.insert(.b); case "plus": held.insert(.plus)
                case "minus": held.insert(.minus); case "home": held.insert(.home); default: break }
            }
        }
        // Feed the pointer for several frames so the KPad smoothing converges.
        for _ in 0..<(held.isEmpty ? 1 : 1) { pad.update(PointerSample(position: pointer, valid: true, held: held)) }
        if let e = menu.update(pad: pad) { lastEvent = e }
        sound?.update()
    }
    gx.beginFrame()
    let w = isWide ? 1216 : 912
    try writePNG(device: device, width: w, height: 684, path: path, clear: MTLClearColor(red: 0.25, green: 0.45, blue: 0.7, alpha: 1)) { enc in
        menu.draw(enc, backgroundTexture: nil, pad: pad)
    }
    print("rendered \(path) active=\(menu.isActive) event=\(String(describing: lastEvent))")
}
