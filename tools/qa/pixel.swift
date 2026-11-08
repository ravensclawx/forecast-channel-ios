// usage: swift pixel.swift img.png x y [x y ...]  → prints RGBA at each point
import AppKit
let a = CommandLine.arguments
let rep = NSBitmapImageRep(data: try! Data(contentsOf: URL(fileURLWithPath: a[1])))!
var i = 2
while i + 1 < a.count {
    let x = Int(a[i])!, y = Int(a[i + 1])!
    let c = rep.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
    print("\(x),\(y): \(Int(c.redComponent * 255)) \(Int(c.greenComponent * 255)) \(Int(c.blueComponent * 255))")
    i += 2
}
