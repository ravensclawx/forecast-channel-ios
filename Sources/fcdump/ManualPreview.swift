import AppKit
import CoreGraphics
import Forecast
import Foundation
import ImageIO
import Metal
import UniformTypeIdentifiers

/// Offscreen run of the HOME Menu Operations Guide (ManualViewer) with scripted Wii Remote input.
/// Commands: wait:N, ptr:x,y (logical 832×456), a, up, down, holddown:N, holdup:N, plus, minus, home, shot:name, reopen.
public func renderManual(path: String, script: [String]) throws {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.prohibited)
    let device = MTLCreateSystemDefaultDevice()!
    let assets = try Assets()
    SaveData.url = URL(fileURLWithPath: path + "_savedata.dat")   // never touch the real save
    let ctx = try SceneContext(assets: assets, device: device, colorFormat: .bgra8Unorm, depthFormat: .depth32Float, sound: nil)
    let archive = try ManualArchive(assets: assets)
    print("manual: \(archive.html.files.count) files, PGothic face \(archive.pGothic?.count ?? 0) bytes")
    let manual = try ManualViewer(archive: archive, device: device)
    manual.playSE = { print(String(format: "  SE 0x%02X", $0)) }
    manual.cursor = try ManualCursor(assets: assets, device: device)
    var twist: Float = 0

    // WebKit renders only inside a window: park a borderless one off screen.
    let win = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: manual.browserSize.width, height: manual.browserSize.height),
                       styleMask: [.borderless], backing: .buffered, defer: false)
    win.contentView = manual.webView
    win.orderBack(nil)

    let w = 1216, h = 666
    let cd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
    cd.usage = [.renderTarget, .shaderRead]; cd.storageMode = .shared
    let target = device.makeTexture(descriptor: cd)!
    let dd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: w, height: h, mipmapped: false)
    dd.usage = .renderTarget; dd.storageMode = .private
    let depth = device.makeTexture(descriptor: dd)!
    let queue = device.makeCommandQueue()!
    var pointer = SIMD2<Float>(416, 228)
    var held: WPAD = []
    var holdFrames = 0

    func frame(_ press: WPAD = []) {
        var b = press
        if holdFrames > 0 { b.formUnion(held); holdFrames -= 1 } else { held = [] }
        ctx.pad.update(PointerSample(position: pointer, valid: true, held: b, twistDegrees: twist))
        if manual.update(pad: ctx.pad) { print("  closed at \(manual.resumeURL.path)") }
        RunLoop.main.run(until: Date().addingTimeInterval(1.0 / 60))
        let cb = queue.makeCommandBuffer()!
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = target; rp.colorAttachments[0].loadAction = .clear; rp.colorAttachments[0].storeAction = .store
        rp.colorAttachments[0].clearColor = MTLClearColor(red: 0.2, green: 0, blue: 0.2, alpha: 1)
        rp.depthAttachment.texture = depth; rp.depthAttachment.loadAction = .clear; rp.depthAttachment.storeAction = .dontCare
        let enc = cb.makeRenderCommandEncoder(descriptor: rp)!
        enc.setViewport(MTLViewport(originX: 0, originY: 0, width: Double(w), height: Double(h), znear: 0, zfar: 1))
        manual.draw(enc, pad: ctx.pad)
        enc.endEncoding()
        cb.commit(); cb.waitUntilCompleted()
    }
    func shot(_ name: String) {
        var px = [UInt8](repeating: 0, count: w * h * 4)
        target.getBytes(&px, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        let cg = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                           bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue)!
        let out = "\(path)_\(name).png"
        let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: out) as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, cg.makeImage()!, nil); CGImageDestinationFinalize(dest)
        print("shot \(out): page=\(manual.currentPath ?? "-") active=\(manual.isActive)")
    }

    manual.open()
    for cmd in script {
        let p = cmd.split(separator: ":", maxSplits: 1).map(String.init)
        switch p[0] {
        case "wait": for _ in 0..<(Int(p.count > 1 ? p[1] : "1") ?? 1) { frame() }
        case "ptr":
            let xy = p[1].split(separator: ",").compactMap { Float($0) }
            if xy.count == 2 { pointer = SIMD2(xy[0], xy[1]) }
            frame()
        case "a": frame(.a)
        case "up": frame(.up)
        case "down": frame(.down)
        case "plus": frame(.plus)
        case "minus": frame(.minus)
        case "home": frame(.home)
        case "holddown": held = .down; holdFrames = Int(p[1]) ?? 30; frame(.down)
        case "holdup": held = .up; holdFrames = Int(p[1]) ?? 30; frame(.up)
        case "js":
            var out: Any? = nil, done = false
            manual.debugEval(p[1]) { out = $0; done = true }
            while !done { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
            print("  js → \(out ?? "nil")")
        case "twist": twist = Float(p[1]) ?? 0; frame()
        case "reopen": manual.open(); frame()
        case "shot": shot(p.count > 1 ? p[1] : "x")
        default: break
        }
    }
}
