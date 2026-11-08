import CoreGraphics
import Forecast
import Foundation
import ImageIO
import Metal
import UniformTypeIdentifiers

/// Offscreen WeatherScene run with scripted input.
/// Script commands: "wait:N" (frames), "ptr:x,y" (logical px), "a" / "b" / "up" / "down" / "plus" / "minus" (press one
/// frame), "holdb:N", "shot:name" (write <path>_<name>.png), "fresh" (use a temporary empty save file).
/// `path` is a prefix; screenshots go to "<path>_<name>.png".
public func renderScene(path: String, frames: Int, script: [String]) throws {
    let device = MTLCreateSystemDefaultDevice()!
    let assets = try Assets()
    // Never touch the user's real save: always run on a scratch copy ("fresh" = no save at all).
    let realSave = SaveData.url
    SaveData.url = URL(fileURLWithPath: path + "_savedata.dat")
    try? FileManager.default.removeItem(at: SaveData.url)
    if !script.contains("fresh") { try? FileManager.default.copyItem(at: realSave, to: SaveData.url) }
    let ctx = try SceneContext(assets: assets, device: device, colorFormat: .bgra8Unorm, depthFormat: .depth32Float, sound: nil)
    let scene = try WeatherScene(ctx: ctx)
    let w = 1216, h = 666
    let cd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
    cd.usage = [.renderTarget, .shaderRead]; cd.storageMode = .shared
    let target = device.makeTexture(descriptor: cd)!
    let queue = device.makeCommandQueue()!
    var pointer = SIMD2<Float>(416, 228)
    var held: WPAD = []
    var holdBFrames = 0
    var holdAFrames = 0
    var forceCursor: Cursor.State? = nil   // "cursor:<n>" overrides the scene's cursor variable
    var twist: Float = 0   // "twist:<deg>" — Wii Remote roll for the cursor

    // Same overlay path as ForecastMac: HOME Menu (scene paused) or the cursor, drawn after the scene.
    let cursor = try? Cursor(assets: assets, renderer: ctx.lyt)
    let hbm = try? HomeMenu(assets: assets, renderer: ctx.lyt, sound: nil, isWide: true)
    let dd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: w, height: h, mipmapped: false)
    dd.usage = .renderTarget; dd.storageMode = .private
    let overlayDepth = device.makeTexture(descriptor: dd)!

    func frame(_ press: WPAD = []) {
        var buttons = held.union(press)
        if holdBFrames > 0 { buttons.insert(.b); holdBFrames -= 1 }
        if holdAFrames > 0 { buttons.insert(.a); holdAFrames -= 1 }
        ctx.pad.update(PointerSample(position: pointer, valid: true, held: buttons))
        if let h = hbm, !h.isActive, ctx.pad.trig.contains(.home) { h.open() }
        if let h = hbm, h.isActive { if let e = h.update(pad: ctx.pad) { print("hbm event \(e)") } } else { scene.calc() }
        let cb = queue.makeCommandBuffer()!
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = target; rp.colorAttachments[0].loadAction = .clear; rp.colorAttachments[0].storeAction = .store
        rp.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        let vp = MTLViewport(originX: 0, originY: 0, width: Double(w), height: Double(h), znear: 0, zfar: 1)
        scene.render(commandBuffer: cb, pass: rp, viewport: vp)
        let ov = MTLRenderPassDescriptor()
        ov.colorAttachments[0].texture = target; ov.colorAttachments[0].loadAction = .load; ov.colorAttachments[0].storeAction = .store
        ov.depthAttachment.texture = overlayDepth; ov.depthAttachment.loadAction = .clear; ov.depthAttachment.storeAction = .dontCare
        if let enc = cb.makeRenderCommandEncoder(descriptor: ov) {
            enc.setViewport(vp)
            if let h = hbm, h.isActive { h.draw(enc, backgroundTexture: scene.frameTexture, pad: ctx.pad) }
            else if let c = cursor { c.state = forceCursor ?? scene.cursorState; c.draw(ctx.lyt, enc, pointer: ctx.pad.pointer, twist: twist, screenWidth: 832) }
            enc.endEncoding()
        }
        cb.commit(); cb.waitUntilCompleted()
    }
    func shot(_ name: String) {
        var px = [UInt8](repeating: 0, count: w * h * 4)
        target.getBytes(&px, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        let cgctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue)!
        let out = "\(path)_\(name).png"
        let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: out) as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, cgctx.makeImage()!, nil); CGImageDestinationFinalize(dest)
        print("shot \(out): state=\(scene.state.rawValue) request=\(ctx.request) location=\(ctx.locationID) units=\(ctx.tempUnit)/\(ctx.windUnit)")
    }
    var total = 0
    for cmd in script {
        let parts = cmd.split(separator: ":", maxSplits: 1).map(String.init)
        switch parts[0] {
        case "wait":
            let n = Int(parts.count > 1 ? parts[1] : "1") ?? 1
            for _ in 0..<n { frame(); total += 1 }
            // Boot waits on the async download: keep stepping (in real time) until it leaves the connect step.
        case "boot":
            var guardFrames = 0
            while ctx.data == nil && guardFrames < 60 * 240 { frame(); total += 1; guardFrames += 1; if guardFrames % 30 == 0 { usleep(16_000) } }
            for _ in 0..<60 { frame(); total += 1 }
        case "ptr":
            let xy = parts[1].split(separator: ",").compactMap { Float($0) }
            if xy.count == 2 { pointer = SIMD2(xy[0], xy[1]) }
            frame(); total += 1
        case "a": frame(.a); total += 1
        case "b": frame(.b); total += 1
        case "up": frame(.up); total += 1
        case "down": frame(.down); total += 1
        case "plus": frame(.plus); total += 1
        case "minus": frame(.minus); total += 1
        case "left": frame(.left); total += 1
        case "right": frame(.right); total += 1
        case "home": frame(.home); total += 1
        case "holdb": holdBFrames = Int(parts[1]) ?? 10
        case "holda": holdAFrames = Int(parts[1]) ?? 10
        case "cursor": forceCursor = Int(parts[1]).flatMap { Cursor.State(rawValue: $0) }
        case "twist": twist = Float(parts[1]) ?? 0
        case "dbg": print("dbg state=\(scene.state.rawValue) hovered=\(ctx.ui.hovered?.name ?? "-") req=\(ctx.request) ptr=\(ctx.pad.pointer)")
        case "req": ctx.request = Int(parts[1]) ?? 0; frame(); total += 1
        case "shot": shot(parts.count > 1 ? parts[1] : "\(total)")
        default: break
        }
    }
    while total < frames { frame(); total += 1 }
    if script.isEmpty { shot("final") }
}
