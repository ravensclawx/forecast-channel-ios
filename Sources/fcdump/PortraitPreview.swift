import AppKit
import CoreGraphics
import Forecast
import Foundation
import ImageIO
import Metal
import UniformTypeIdentifiers

/// Offscreen iPhone-portrait WeatherScene run, driven by touches. Device: iPhone 16 Pro (402×874 pt, safe area
/// 62/34 pt) → logical 608 × 1322, rendered at 2× (1216 × 2644).
/// Script (logical px, y down; 0..608 × 0..1322):
///   wait:N  boot  shot:name  fresh
///   tap:x,y            finger down, 4 frames, up (press-on-release / globe click)
///   down:x,y  move:x,y  up         a single finger
///   drag:x0,y0,x1,y1,N one finger dragged over N frames, then lifted
///   pinch:scale,N      two fingers around the centre, spread by `scale` over N frames
///   tilt:dy,N          two fingers moved vertically by dy over N frames
///   rotate:deg,N       two fingers rotated
///   home               HOME (opens the HOME Menu)
public func renderPortrait(path: String, script: [String]) throws {
    let ptW: Float = 402, ptH: Float = 874
    let k = 608 / ptW
    LogicalScreen.isPortrait = true
    LogicalScreen.height = (ptH * k).rounded()
    LogicalScreen.safeTop = 62 * k
    LogicalScreen.safeBottom = 34 * k
    let H = LogicalScreen.height

    let device = MTLCreateSystemDefaultDevice()!
    let assets = try Assets()
    let realSave = SaveData.url
    SaveData.url = URL(fileURLWithPath: path + "_savedata.dat")
    try? FileManager.default.removeItem(at: SaveData.url)
    if !script.contains("fresh") { try? FileManager.default.copyItem(at: realSave, to: SaveData.url) }
    let ctx = try SceneContext(assets: assets, device: device, colorFormat: .bgra8Unorm, depthFormat: .depth32Float,
                               sound: nil, isWide: false)
    ctx.pad.smoothPointer = false
    let scene = try WeatherScene(ctx: ctx)
    let hbm = try? HomeMenu(assets: assets, renderer: ctx.lyt, sound: nil, isWide: false)
    let touch = TouchInput()
    let w = 1216, h = Int(H * 2)
    let cd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
    cd.usage = [.renderTarget, .shaderRead]; cd.storageMode = .shared
    let target = device.makeTexture(descriptor: cd)!
    let dd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: w, height: h, mipmapped: false)
    dd.usage = .renderTarget; dd.storageMode = .private
    let overlayDepth = device.makeTexture(descriptor: dd)!
    let queue = device.makeCommandQueue()!
    var extra: WPAD = []
    var iconPressed = false
    var manual: ManualViewer?
    var manualWindow: NSWindow?
    func openManual() {
        if manual == nil {
            _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited)
            guard let arc = try? ManualArchive(assets: assets), let m = try? ManualViewer(archive: arc, device: device, isWide: false) else { return }
            m.playSE = { print(String(format: "manual SE 0x%02X", $0)) }
            let win = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: m.browserSize.width, height: m.browserSize.height),
                               styleMask: [.borderless], backing: .buffered, defer: false)
            win.contentView = m.webView; win.orderBack(nil)
            manual = m; manualWindow = win
        }
        manual?.open()
    }

    func frame() {
        var s = touch.sample()
        s.held.formUnion(extra); extra = []
        ctx.gestures = touch.gestures
        ctx.pad.update(s)
        if let mv = manual, mv.isActive {
            mv.ctxGestures = touch.gestures
            if mv.update(pad: ctx.pad) { print("manual closed at \(mv.resumeURL.path)") }
            RunLoop.main.run(until: Date().addingTimeInterval(1.0 / 60))
        } else {
            if let m = hbm, !m.isActive, ctx.pad.trig.contains(.home) { m.open() }
            if let m = hbm, m.isActive {
                if let e = m.update(pad: ctx.pad) {
                    print("hbm event \(e)")
                    if e == .manual { openManual() }
                }
            } else { scene.calc() }
        }
        let cb = queue.makeCommandBuffer()!
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = target; rp.colorAttachments[0].loadAction = .clear; rp.colorAttachments[0].storeAction = .store
        rp.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        let vp = MTLViewport(originX: 0, originY: 0, width: Double(w), height: Double(h), znear: 0, zfar: 1)
        scene.render(commandBuffer: cb, pass: rp, viewport: vp)
        if let m = hbm {
            let ov = MTLRenderPassDescriptor()
            ov.colorAttachments[0].texture = target; ov.colorAttachments[0].loadAction = .load; ov.colorAttachments[0].storeAction = .store
            ov.depthAttachment.texture = overlayDepth; ov.depthAttachment.loadAction = .clear; ov.depthAttachment.storeAction = .dontCare
            if let enc = cb.makeRenderCommandEncoder(descriptor: ov) {
                enc.setViewport(vp)
                if let mv = manual, mv.isActive { mv.draw(enc, pad: ctx.pad); m.drawHomeIcon(enc, pressed: iconPressed) }
                else if m.isActive { m.draw(enc, backgroundTexture: scene.frameTexture, pad: ctx.pad) }
                else if ProcessInfo.processInfo.environment["FC_NO_HOMEICON"] == nil { m.drawHomeIcon(enc, pressed: iconPressed) }
                enc.endEncoding()
            }
        }
        cb.commit(); cb.waitUntilCompleted()
    }
    /// The shell's HOME icon: a tap on it opens the HOME Menu (or closes the manual) instead of reaching the scene.
    func iconTap(_ p: SIMD2<Float>) -> Bool {
        guard let m = hbm, !m.isActive, m.homeIconHit(p) else { return false }
        iconPressed = true; frame(); frame(); iconPressed = false
        if let mv = manual, mv.isActive { mv.requestClose() } else { m.open() }
        frame()
        return true
    }
    func shot(_ name: String) {
        var px = [UInt8](repeating: 0, count: w * h * 4)
        target.getBytes(&px, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        let cg = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                           bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue)!
        let out = "\(path)_\(name).png"
        let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: out) as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, cg.makeImage()!, nil); CGImageDestinationFinalize(dest)
        print("shot \(out): state=\(scene.state.rawValue) request=\(ctx.request) location=\(ctx.locationID) units=\(ctx.tempUnit)/\(ctx.windUnit)"
              + (manual?.isActive == true ? " manual=\(manual?.currentPath ?? "-")" : "") + (hbm?.isActive == true ? " hbm" : ""))
    }
    func pt(_ s: String) -> [Float] { s.split(separator: ",").compactMap { Float($0) } }
    let mode: (SIMD2<Float>) -> TouchInput.Mode = { scene.touchMode(at: $0) }
    let centre = SIMD2<Float>(304, H / 2)

    for cmd in script {
        let parts = cmd.split(separator: ":", maxSplits: 1).map(String.init)
        let a = parts.count > 1 ? parts[1] : ""
        switch parts[0] {
        case "wait": for _ in 0..<(Int(a) ?? 1) { frame() }
        case "boot":
            var g = 0
            while ctx.data == nil && g < 60 * 240 { frame(); g += 1; if g % 30 == 0 { usleep(16_000) } }
            for _ in 0..<60 { frame() }
        case "tap":
            let v = pt(a)
            if iconTap(SIMD2(v[0], v[1])) { break }
            touch.began(id: 1, at: SIMD2(v[0], v[1]), modeAt: mode)
            for _ in 0..<4 { frame() }
            touch.ended(id: 1); frame()
        case "down": let v = pt(a); touch.began(id: 1, at: SIMD2(v[0], v[1]), modeAt: mode); frame()
        case "move": let v = pt(a); touch.moved(id: 1, to: SIMD2(v[0], v[1])); frame()
        case "up": touch.ended(id: 1); frame()
        case "drag":
            let v = pt(a); let n = max(1, Int(v[4]))
            let p0 = SIMD2(v[0], v[1]), p1 = SIMD2(v[2], v[3])
            touch.began(id: 1, at: p0, modeAt: mode); frame()
            for i in 1...n { touch.moved(id: 1, to: p0 + (p1 - p0) * Float(i) / Float(n)); frame() }
            touch.ended(id: 1); frame()
        case "pinch", "tilt", "rotate":
            let v = pt(a); let n = max(1, Int(v[1]))
            var a0 = centre - SIMD2(60, 0), b0 = centre + SIMD2(60, 0)
            touch.began(id: 1, at: a0, modeAt: mode); touch.began(id: 2, at: b0, modeAt: mode); frame()
            for i in 1...n {
                let t = Float(i) / Float(n)
                var a1 = a0, b1 = b0
                switch parts[0] {
                case "pinch": let r = 60 * (1 + (v[0] - 1) * t); a1 = centre - SIMD2(r, 0); b1 = centre + SIMD2(r, 0)
                case "tilt": a1.y += v[0] * t; b1.y += v[0] * t
                default:
                    let ang = v[0] * t * .pi / 180
                    let d = SIMD2(cos(ang), sin(ang)) * 60
                    a1 = centre - d; b1 = centre + d
                }
                touch.moved(id: 1, to: a1); touch.moved(id: 2, to: b1); frame()
                if i == n { a0 = a1; b0 = b1 }
            }
            touch.ended(id: 2); touch.ended(id: 1); frame()
        case "home": extra.insert(.home); frame()
        case "dbg": print("dbg state=\(scene.state.rawValue) hovered=\(ctx.ui.hovered?.name ?? "-") ptr=\(ctx.pad.pointer) valid=\(ctx.pad.pointerValid)")
        case "homeicon":   // tap the shell's HOME icon
            if let r = hbm?.homeIconRect { _ = iconTap(SIMD2((r.x + r.z) / 2, (r.y + r.w) / 2)) }
        case "shot": shot(a.isEmpty ? "x" : a)
        default: break
        }
    }
}
