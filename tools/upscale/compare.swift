// usage: swift compare.swift out.png crop(x,y,w,h in ORIGINAL texels) zoom original.png labelA=a.png labelB=b.png ...
// Composites each image over mid-grey (alpha visible), crops the same region (scaled to each image's size) and
// shows them side by side at `zoom` screen px per original texel. The original is drawn nearest-neighbour.
import AppKit
let a = CommandLine.arguments
let out = a[1]; let c = a[2].split(separator: ",").map { CGFloat(Double($0)!) }; let zoom = CGFloat(Double(a[3])!)
let orig = NSImage(contentsOfFile: a[4])!
var items: [(String, NSImage)] = [("original (nearest)", orig)]
for s in a[5...] { let p = s.split(separator: "=", maxSplits: 1); items.append((String(p[0]), NSImage(contentsOfFile: String(p[1]))!)) }
let ow = orig.representations[0].pixelsWide
let cw = c[2] * zoom, ch = c[3] * zoom
let W = cw * CGFloat(items.count) + CGFloat(items.count - 1) * 8, H = ch + 20
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W), pixelsHigh: Int(H), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
let g = NSGraphicsContext(bitmapImageRep: rep)!; NSGraphicsContext.current = g
NSColor.white.setFill(); NSRect(x: 0, y: 0, width: W, height: H).fill()
for (i, (label, img)) in items.enumerated() {
    let x = CGFloat(i) * (cw + 8)
    NSColor(white: 0.45, alpha: 1).setFill(); NSRect(x: x, y: 0, width: cw, height: ch).fill()
    let px = img.representations[0].pixelsWide, ph = img.representations[0].pixelsHigh
    let k = CGFloat(px) / CGFloat(ow)
    g.imageInterpolation = i == 0 ? .none : .high
    // NSImage coords are bottom-up; crop given top-down.
    let src = NSRect(x: c[0] * k * img.size.width / CGFloat(px), y: (CGFloat(ph) - (c[1] + c[3]) * k) * img.size.height / CGFloat(ph),
                     width: c[2] * k * img.size.width / CGFloat(px), height: c[3] * k * img.size.height / CGFloat(ph))
    img.draw(in: NSRect(x: x, y: 0, width: cw, height: ch), from: src, operation: .sourceOver, fraction: 1)
    (label as NSString).draw(at: NSPoint(x: x + 2, y: ch + 3), withAttributes: [.font: NSFont.systemFont(ofSize: 12)])
}
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
