import CoreGraphics
import Forecast
import Foundation
import ImageIO
import Metal
import UniformTypeIdentifiers

/// iPhone app icon (1024×1024): the channel's own hub background gradient (base.brlyt "bg", plate1.tpl) with its
/// sunny weather icon on top, rendered from the user's WAD. Output stays out of the repo (iOS/Resources is ignored).
public func renderIcon(path: String, scale iconScale: Float) throws {
    LogicalScreen.isPortrait = false
    LogicalScreen.height = 608                      // a square 608×608 logical screen
    let device = MTLCreateSystemDefaultDevice()!
    let assets = try Assets()
    let ctx = try SceneContext(assets: assets, device: device, colorFormat: .bgra8Unorm, depthFormat: .depth32Float,
                               sound: nil, isWide: false)
    let base = try ctx.layout("base.brlyt")
    if let bg = base.find("bg") { bg.pane.scale.y = 608.0 / 456.0; base.relayout() }
    let sprites = try SpriteText(ctx: ctx)
    let n = 1024
    let cd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: n, height: n, mipmapped: false)
    cd.usage = [.renderTarget, .shaderRead]; cd.storageMode = .shared
    let target = device.makeTexture(descriptor: cd)!
    let dd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: n, height: n, mipmapped: false)
    dd.usage = .renderTarget; dd.storageMode = .private
    let depth = device.makeTexture(descriptor: dd)!
    let queue = device.makeCommandQueue()!
    let cb = queue.makeCommandBuffer()!
    let rp = MTLRenderPassDescriptor()
    rp.colorAttachments[0].texture = target; rp.colorAttachments[0].loadAction = .clear; rp.colorAttachments[0].storeAction = .store
    rp.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
    rp.depthAttachment.texture = depth; rp.depthAttachment.loadAction = .clear; rp.depthAttachment.storeAction = .dontCare
    ctx.gx.beginFrame()
    let enc = cb.makeRenderCommandEncoder(descriptor: rp)!
    enc.setViewport(MTLViewport(originX: 0, originY: 0, width: Double(n), height: Double(n), znear: 0, zfar: 1))
    base.draw(ctx.lyt, enc)
    sprites.drawWeatherIcon(code: 0x65, center: SIMD2(304, 304), scale: iconScale, enc)   // 0x65 = Sunny
    enc.endEncoding()
    cb.commit(); cb.waitUntilCompleted()
    var px = [UInt8](repeating: 0, count: n * n * 4)
    target.getBytes(&px, bytesPerRow: n * 4, from: MTLRegionMake2D(0, 0, n, n), mipmapLevel: 0)
    // Icons must be opaque.
    for i in stride(from: 3, to: px.count, by: 4) { px[i] = 255 }
    let cg = CGContext(data: &px, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue)!
    let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, cg.makeImage()!, nil); CGImageDestinationFinalize(dest)
    print("wrote \(path)")
}
