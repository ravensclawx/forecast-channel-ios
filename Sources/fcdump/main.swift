import Forecast
import Foundation
import GX
import Metal
import NW4R

// Developer tool: verifies asset parsing and that every generated GX shader compiles.
//   swift run fcdump [--shader <material>]
let args = CommandLine.arguments
func arg(_ k: String) -> String? { args.firstIndex(of: k).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
if let page = arg("--hub"), let out = arg("--out") {
    do { try renderHub(path: out, page: Int(page) ?? 1) } catch { print("error: \(error)"); exit(1) }
    exit(0)
}
if let prefix = arg("--scene") {
    let i = args.firstIndex(of: "--scene")! + 2
    do { try renderScene(path: prefix, frames: 0, script: Array(args[i...])) } catch { print("error: \(error)"); exit(1) }
    exit(0)
}
if let out = arg("--icon") {
    do { try renderIcon(path: out, scale: Float(arg("--scale") ?? "3") ?? 3) } catch { print("error: \(error)"); exit(1) }
    exit(0)
}
if let prefix = arg("--portrait") {
    let i = args.firstIndex(of: "--portrait")! + 2
    do { try renderPortrait(path: prefix, script: Array(args[i...])) } catch { print("error: \(error)"); exit(1) }
    exit(0)
}
if let prefix = arg("--manual") {
    let i = args.firstIndex(of: "--manual")! + 2
    do { try renderManual(path: prefix, script: Array(args[i...])) } catch { print("error: \(error)"); exit(1) }
    exit(0)
}
if let out = arg("--hbm") {
    do { try renderHomeMenu(path: out, frames: Int(arg("--frames") ?? "60") ?? 60, script: arg("--script") ?? "", isWide: true) }
    catch { print("error: \(error)"); exit(1) }
    exit(0)
}
if let name = arg("--ui"), let out = arg("--out") {
    do { try renderUILayout(name: name, path: out, hover: arg("--hover")) } catch { print("error: \(error)"); exit(1) }
    exit(0)
}
if let name = arg("--layout"), let out = arg("--out") {
    do { try renderLayout(name: name, path: out) } catch { print("error: \(error)"); exit(1) }
    exit(0)
}
if let out = arg("--render") {
    do {
        try renderSnapshot(path: out, zoomOuts: Int(arg("--zoom") ?? "0") ?? 0, tiltUps: Int(arg("--tilt") ?? "0") ?? 0,
                           frames: Int(arg("--frames") ?? "240") ?? 240, lat: arg("--lat").flatMap(Float.init), lon: arg("--lon").flatMap(Float.init))
    } catch { print("error: \(error)"); exit(1) }
    exit(0)
}
do {
    let assets = try Assets()
    print(String(format: "title %016llx v%d, %d contents", assets.title.titleID, assets.title.titleVersion, assets.title.contents.count))
    let t0 = Date()
    let earth = try assets.earthBRRES()
    print(String(format: "earth.brres parsed in %.2fs", Date().timeIntervalSince(t0)))
    for (name, mdl) in earth.models {
        print("model \(name): \(mdl.bones.count) bones, \(mdl.materials.count) mats, \(mdl.shapes.count) shapes, opa \(mdl.drawOpa.count) xlu \(mdl.drawXlu.count)")
        for b in mdl.bones { print("  bone \(b.name) flags=\(String(b.flags, radix: 16)) billboard=\(b.billboard) S\(b.scale) T\(b.translation) parent=\(b.parent.map(String.init) ?? "-")") }
        for s in mdl.shapes.prefix(3) { print("  shape \(s.name) verts=\(s.vertices.count / 26) tris=\(s.indices.count / 3)") }
        let device = MTLCreateSystemDefaultDevice()!
        var unique: [GXState: String] = [:]
        for m in mdl.materials { unique[m.gx] = m.name }
        print("  \(unique.count) unique GX states across \(mdl.materials.count) materials")
        for (state, matName) in unique {
            let src = GXShaderGen.generate(state)
            do { _ = try device.makeLibrary(source: src, options: nil); print("  ✓ shader for \(matName) compiles") }
            catch { print("  ✗ \(matName): \(error)"); print(src); exit(1) }
        }
        if let i = args.firstIndex(of: "--shader"), i + 1 < args.count, let m = mdl.materials.first(where: { $0.name == args[i + 1] }) {
            print(m.layers.map { "\($0.texMap):\($0.texture) wrap \($0.wrapS)/\($0.wrapT)" })
            print("srt mode \(m.texMtxMode) flags \(String(m.srtFlags, radix: 16))", m.srt.prefix(4), m.effects.prefix(4).map { ($0.camera, $0.light, $0.mapMode) })
            print(GXShaderGen.generate(m.gx))
        }
    }
    let tex = earth.textures.values.sorted { $0.name < $1.name }
    print("\(tex.count) textures, e.g. \(tex[0].name) \(tex[0].width)x\(tex[0].height) \(tex[0].format)")
} catch {
    print("error: \(error)"); exit(1)
}
