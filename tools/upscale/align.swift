// usage: swift align.swift a.png b.png  → for a grid of textured tiles, the (dx,dy) in ±4 px minimising SAD.
import AppKit
func load(_ p: String) -> (px: [UInt8], w: Int, h: Int) {
    let r = NSBitmapImageRep(data: try! Data(contentsOf: URL(fileURLWithPath: p)))!
    let w = r.pixelsWide, h = r.pixelsHigh
    var px = [UInt8](repeating: 0, count: w * h)
    for y in 0..<h { for x in 0..<w { let c = r.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
        px[y * w + x] = UInt8(255 * (0.3 * c.redComponent + 0.59 * c.greenComponent + 0.11 * c.blueComponent)) } }
    return (px, w, h)
}
let a = load(CommandLine.arguments[1]), b = load(CommandLine.arguments[2])
let T = 96, R = 4
var shifted = 0, tested = 0, maxDiff = 0
for ty in stride(from: R, to: a.h - T - R, by: T) { for tx in stride(from: R, to: a.w - T - R, by: T) {
    // only tiles with structure
    var mn = 255, mx = 0
    for y in ty..<(ty + T) { for x in tx..<(tx + T) { let v = Int(a.px[y * a.w + x]); mn = min(mn, v); mx = max(mx, v) } }
    if mx - mn < 60 { continue }
    var best = (Int.max, 0, 0)
    for dy in -R...R { for dx in -R...R {
        var sad = 0
        for y in ty..<(ty + T) { for x in tx..<(tx + T) { sad += abs(Int(a.px[y * a.w + x]) - Int(b.px[(y + dy) * b.w + x + dx])) } }
        if sad < best.0 { best = (sad, dx, dy) }
    } }
    tested += 1
    if best.1 != 0 || best.2 != 0 { shifted += 1; print("tile \(tx),\(ty): best offset \(best.1),\(best.2)") }
    maxDiff = max(maxDiff, best.0 / (T * T))
}}
print("tiles tested \(tested), shifted \(shifted), worst mean abs diff at best offset \(maxDiff)")
