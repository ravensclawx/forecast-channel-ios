// usage: swift montage.swift out.png cols cellWidth in1.png in2.png ...
import AppKit
let a = CommandLine.arguments
let out = a[1], cols = Int(a[2])!, cw = CGFloat(Double(a[3])!)
let files = Array(a[4...])
let imgs = files.compactMap { NSImage(contentsOfFile: $0) }
// Cell aspect follows the first image (landscape 1216×666 captures or tall iPhone-portrait ones).
let aspect = imgs.first.map { $0.size.height / max($0.size.width, 1) } ?? (666.0 / 1216.0)
let ch = cw * aspect + 18
let rows = (imgs.count + cols - 1) / cols
let W = CGFloat(cols) * cw, H = CGFloat(rows) * ch
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W), pixelsHigh: Int(H), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSColor.white.setFill(); NSRect(x: 0, y: 0, width: W, height: H).fill()
for (i, img) in imgs.enumerated() {
    let c = CGFloat(i % cols), r = CGFloat(rows - 1 - i / cols)
    img.draw(in: NSRect(x: c * cw, y: r * ch, width: cw, height: ch - 18))
    let name = (files[i] as NSString).lastPathComponent
    (name as NSString).draw(at: NSPoint(x: c * cw + 4, y: r * ch + ch - 16), withAttributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.black])
}
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
