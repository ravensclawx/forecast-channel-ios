import CoreGraphics
import Forecast
import Foundation
import ImageIO
import Metal
import UniformTypeIdentifiers

/// Offscreen: run GlobeScene for N frames with scripted presses, then write the frame as PNG.
func renderSnapshot(path: String, zoomOuts: Int, tiltUps: Int, frames: Int, lat: Float?, lon: Float?, width: Int = 1216, height: Int = 684) throws {
    let device = MTLCreateSystemDefaultDevice()!
    let scene = try GlobeScene(device: device, assets: try Assets(), colorFormat: .bgra8Unorm, depthFormat: .depth32Float)
    if let lat, let lon { scene.globe.camera.lat = lat; scene.globe.camera.lon = lon }
    var script: [WPAD] = []
    for _ in 0..<zoomOuts { script += [.minus, []] }
    for _ in 0..<tiltUps { script += [.up, []] }
    for f in 0..<max(frames, script.count + 1) {
        let held = f < script.count ? script[f] : []
        scene.step(PointerSample(position: SIMD2(416, 228), valid: true, held: held))
    }
    let cd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
    cd.usage = [.renderTarget, .shaderRead]; cd.storageMode = .shared
    let color = device.makeTexture(descriptor: cd)!
    let dd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: width, height: height, mipmapped: false)
    dd.usage = .renderTarget; dd.storageMode = .private
    let depth = device.makeTexture(descriptor: dd)!
    let rp = MTLRenderPassDescriptor()
    rp.colorAttachments[0].texture = color; rp.colorAttachments[0].loadAction = .clear; rp.colorAttachments[0].storeAction = .store
    rp.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
    rp.depthAttachment.texture = depth; rp.depthAttachment.loadAction = .clear; rp.depthAttachment.clearDepth = 1
    let q = device.makeCommandQueue()!, cb = q.makeCommandBuffer()!
    let enc = cb.makeRenderCommandEncoder(descriptor: rp)!
    enc.setViewport(MTLViewport(originX: 0, originY: 0, width: Double(width), height: Double(height), znear: 0, zfar: 1))
    scene.draw(enc); enc.endEncoding(); cb.commit(); cb.waitUntilCompleted()
    var px = [UInt8](repeating: 0, count: width * height * 4)
    color.getBytes(&px, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
    let ctx = CGContext(data: &px, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue)!
    let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil); CGImageDestinationFinalize(dest)
    let g = scene.globe
    print("rendered \(path): zoomIdx \(g.zoomIdx) dist \(g.dist) lat \(g.camera.lat) lon \(g.camera.lon) pitch \(g.camera.pitch)")
}

/// Offscreen: draw one layout (all panes as authored) to PNG.
func renderLayout(name: String, path: String, width: Int = 1216, height: Int = 912) throws {
    let device = MTLCreateSystemDefaultDevice()!
    let assets = try Assets()
    let layout = try assets.layout(name)
    let gx = GXMetal(device: device, colorFormat: .bgra8Unorm, depthFormat: .depth32Float)
    let lyt = LytRenderer(gx: gx)
    lyt.textureProvider = { assets.layoutTexture($0) }
    lyt.fontProvider = { assets.font($0) }
    gx.beginFrame()
    try writePNG(device: device, width: width, height: height, path: path) { enc in lyt.draw(layout, enc) }
    var counts: [String: Int] = [:]
    layout.root.forEach { counts[String(describing: type(of: $0)), default: 0] += 1 }
    print("rendered \(name): \(layout.width)x\(layout.height) panes \(counts) textures \(layout.textureNames.count) fonts \(layout.fontNames)")
}

func writePNG(device: MTLDevice, width: Int, height: Int, path: String, clear: MTLClearColor = MTLClearColor(red: 0.2, green: 0.2, blue: 0.25, alpha: 1), _ draw: (MTLRenderCommandEncoder) -> Void) throws {
    let cd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
    cd.usage = [.renderTarget, .shaderRead]; cd.storageMode = .shared
    let color = device.makeTexture(descriptor: cd)!
    let dd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: width, height: height, mipmapped: false)
    dd.usage = .renderTarget; dd.storageMode = .private
    let depth = device.makeTexture(descriptor: dd)!
    let rp = MTLRenderPassDescriptor()
    rp.colorAttachments[0].texture = color; rp.colorAttachments[0].loadAction = .clear; rp.colorAttachments[0].storeAction = .store
    rp.colorAttachments[0].clearColor = clear
    rp.depthAttachment.texture = depth; rp.depthAttachment.loadAction = .clear; rp.depthAttachment.clearDepth = 1
    let q = device.makeCommandQueue()!, cb = q.makeCommandBuffer()!
    let enc = cb.makeRenderCommandEncoder(descriptor: rp)!
    enc.setViewport(MTLViewport(originX: 0, originY: 0, width: Double(width), height: Double(height), znear: 0, zfar: 1))
    draw(enc); enc.endEncoding(); cb.commit(); cb.waitUntilCompleted()
    var px = [UInt8](repeating: 0, count: width * height * 4)
    color.getBytes(&px, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
    let ctx = CGContext(data: &px, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue)!
    let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil); CGImageDestinationFinalize(dest)
}

/// Offscreen: a layout through UILayout (CLayout/CPaneCtl: language variants, colour schemes), widescreen.
func renderUILayout(name: String, path: String, hover: String?) throws {
    let device = MTLCreateSystemDefaultDevice()!
    let assets = try Assets()
    let ui = try UILayout(assets: assets, name, lang: .us, isWide: true)
    let gx = GXMetal(device: device, colorFormat: .bgra8Unorm, depthFormat: .depth32Float)
    let lyt = LytRenderer(gx: gx)
    lyt.textureProvider = { assets.layoutTexture($0) }
    lyt.fontProvider = { assets.font($0) }
    for _ in 0..<12 { if let h = hover { ui.find(h)?.setHover() }; ui.update() }
    gx.beginFrame()
    try writePNG(device: device, width: 1216, height: 666, path: path) { enc in ui.draw(lyt, enc) }
    print("ui \(name): \(ui.panes.map { "\($0.name)\($0.disabled ? "(d)" : "")" })")
}
