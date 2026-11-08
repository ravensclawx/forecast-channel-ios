import Forecast
import Foundation
import Metal

/// Offscreen hub preview: SceneContext + NormalScreen with the cached forecast data (ForecastService cache);
/// `page` 0..4 (UV, Current, Today, Tomorrow, 5-Day); `page` 5 = Today with the 6-hour strip open.
func renderHub(path: String, page: Int) throws {
    let device = MTLCreateSystemDefaultDevice()!
    let assets = try Assets()
    let ctx = try SceneContext(assets: assets, device: device, colorFormat: .bgra8Unorm, depthFormat: .depth32Float, sound: nil)
    let sem = DispatchSemaphore(value: 0)
    var data: WeatherData?
    Task { data = await ForecastService().cached(); sem.signal() }
    sem.wait()
    ctx.data = data
    if let id = ProcessInfo.processInfo.environment["HUB_CITY"].flatMap({ name in data?.forecast.places.first { $0.city == name }?.id }) {
        ctx.locationID = id
    } else if let first = data?.forecast.places.first(where: { $0.region != nil }) { ctx.locationID = first.id }
    ctx.tempUnit = ProcessInfo.processInfo.environment["HUB_C"] != nil ? 0 : 1
    let hub = try NormalScreen(ctx: ctx)
    ctx.startPage = page == 5 ? 2 : min(page, 4)
    hub.enter(fromGlobe: false)
    for f in 0..<60 {
        var held: WPAD = []
        if page == 5 && f == 2 { held = .a }
        ctx.pad.update(PointerSample(position: SIMD2(416, 228), valid: true, held: held))
        hub.calc()
    }
    ctx.gx.beginFrame()
    try writePNG(device: device, width: 1216, height: 666, path: path, clear: MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)) { enc in hub.draw(enc) }
    print("hub page \(page) rendered: data \(data != nil), places \(data?.forecast.places.count ?? 0), location \(ctx.locationID)")
}
