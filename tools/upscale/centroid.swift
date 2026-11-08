// usage: swift centroid.swift srcDir upDir → alpha-weighted centroid shift (original texels) per texture.
import AppKit
func alpha(_ url: URL) -> (a: [Double], w: Int, h: Int)? {
    guard let d = try? Data(contentsOf: url), let r = NSBitmapImageRep(data: d) else { return nil }
    let w = r.pixelsWide, h = r.pixelsHigh
    var a = [Double](repeating: 0, count: w * h)
    for y in 0..<h { for x in 0..<w { a[y * w + x] = Double(r.colorAt(x: x, y: y)!.alphaComponent) } }
    return (a, w, h)
}
let src = URL(fileURLWithPath: CommandLine.arguments[1]), up = URL(fileURLWithPath: CommandLine.arguments[2])
var sx = 0.0, sy = 0.0, n = 0, worst = 0.0
for f in try! FileManager.default.contentsOfDirectory(atPath: up.path) where f.hasSuffix(".png") {
    guard let o = alpha(src.appendingPathComponent(f)), let u = alpha(up.appendingPathComponent(f)) else { continue }
    func c(_ v: (a: [Double], w: Int, h: Int), _ k: Double) -> (Double, Double, Double) {
        var m = 0.0, x = 0.0, y = 0.0
        for j in 0..<v.h { for i in 0..<v.w { let a = v.a[j * v.w + i]; m += a; x += a * ((Double(i) + 0.5) / k); y += a * ((Double(j) + 0.5) / k) } }
        return (x / max(m, 1e-9), y / max(m, 1e-9), m)
    }
    let k = Double(u.w) / Double(o.w)
    let a = c(o, 1), b = c(u, k)
    if a.2 < 4 || a.2 > Double(o.w * o.h) * 0.98 { continue }   // skip empty / fully opaque
    let dx = b.0 - a.0, dy = b.1 - a.1
    sx += dx; sy += dy; n += 1; worst = max(worst, hypot(dx, dy))
}
print(String(format: "%d textures with alpha: mean centroid shift (%.3f, %.3f) texels, worst %.3f", n, sx / Double(n), sy / Double(n), worst))
