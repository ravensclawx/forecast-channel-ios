import CoreLocation
import Forecast
import MetalKit
import UIKit

/// iPhone shell: one full-screen Metal view in portrait. The channel runs on a logical 608-wide screen whose height
/// follows the phone (see LogicalScreen / PortraitSlots); touches become the Wii Remote pointer + A via TouchInput,
/// two-finger gestures go to the globe, WPAD rumble becomes haptics. No cursor is drawn.
final class GameViewController: UIViewController, MTKViewDelegate, CLLocationManagerDelegate {
    private var mtkView: MTKView!
    private var queue: MTLCommandQueue!
    private var ctx: SceneContext?
    private var scene: WeatherScene?
    private var sound: SoundManager?
    private var assets: Assets?
    private let touch = TouchInput()
    private var touchIDs: [ObjectIdentifier: Int] = [:]
    private var nextTouchID = 1
    private let haptic = UIImpactFeedbackGenerator(style: .light)
    private var extraButtons: WPAD = []
    private var rebootOnForeground = false

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { .bottom }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .portrait }

    override func loadView() {
        let device = MTLCreateSystemDefaultDevice()!
        let v = MTKView(frame: UIScreen.main.bounds, device: device)
        v.colorPixelFormat = .bgra8Unorm
        v.depthStencilPixelFormat = .depth32Float
        v.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        v.preferredFramesPerSecond = 60
        v.isMultipleTouchEnabled = true
        v.delegate = self
        mtkView = v
        queue = device.makeCommandQueue()
        view = v
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard ctx == nil, view.bounds.width > 0 else { return }
        configureLogicalScreen()
        boot()
    }

    /// 608 logical units across; height and safe-area insets scale with the phone.
    private func configureLogicalScreen() {
        let b = view.bounds, k = Float(608 / b.width)
        LogicalScreen.isPortrait = true
        LogicalScreen.height = (Float(b.height) * k).rounded()
        LogicalScreen.safeTop = Float(view.safeAreaInsets.top) * k
        LogicalScreen.safeBottom = Float(view.safeAreaInsets.bottom) * k
    }

    private func boot() {
        guard let device = mtkView.device else { return }
        do {
            let dir = Bundle.main.resourceURL!.appendingPathComponent("Nintendo")
            clearStaleForecast()
            let assets = try Assets(directory: dir)
            self.assets = assets
            let sound = try? SoundManager(assets: assets)
            try? sound?.startOutput()
            self.sound = sound
            let ctx = try SceneContext(assets: assets, device: device, colorFormat: mtkView.colorPixelFormat,
                                       depthFormat: mtkView.depthStencilPixelFormat, sound: sound, isWide: false)
            ctx.pad.smoothPointer = false
            ctx.rumble = { [weak self] _, _ in self?.haptic.impactOccurred() }
            self.ctx = ctx
            scene = try WeatherScene(ctx: ctx)
            haptic.prepare()
        } catch {
            let a = UIAlertController(title: "Could not load the Forecast Channel", message: "\(error)", preferredStyle: .alert)
            present(a, animated: true)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(willEnterForeground),
                                               name: UIScene.willEnterForegroundNotification, object: nil)
        UserDefaults.standard.register(defaults: ["location": 0, "temp_unit": 1, "wind_unit": 0])
        // This build introduces "Current Location": switch to it once (earlier builds mirrored a fixed city).
        if !UserDefaults.standard.bool(forKey: "location_auto_v1") {
            UserDefaults.standard.set(0, forKey: "location"); UserDefaults.standard.set(true, forKey: "location_auto_v1")
        }
        locationManager.delegate = self
    }

    /// Returning after "Wii Menu" relaunches the channel, as the Wii would.
    @objc private func willEnterForeground() {
        settingsPending = true   // the user may have changed something in the Settings app
        if let ctx, FileManager.default.fileExists(atPath: ForecastService.cacheDirectory.path) {
            clearStaleForecast()
            if !FileManager.default.fileExists(atPath: ForecastService.cacheDirectory.path) {
                ctx.data = nil; _ = ctx.pendingData.take(); scene = try? WeatherScene(ctx: ctx); return
            }
        }
        if locationStarted { locationManager.requestLocation() }
        guard rebootOnForeground, let ctx else { return }
        rebootOnForeground = false
        if let scene, scene.wantsSuspend { scene.resumeFromSuspend() } else { scene = try? WeatherScene(ctx: ctx) }
    }

    /// "Wii Menu" — leave to the iPhone home screen (the app keeps running in the background).
    private func suspendToHomeScreen() {
        rebootOnForeground = true
        UIControl().sendAction(NSSelectorFromString("suspend"), to: UIApplication.shared, for: nil)
    }

    // MARK: - Touches → TouchInput (logical coordinates)

    private func logical(_ t: UITouch) -> SIMD2<Float> {
        let p = t.location(in: view), b = view.bounds
        return SIMD2(Float(p.x / b.width) * 608, Float(p.y / b.height) * LogicalScreen.height)
    }
    private func id(_ t: UITouch) -> Int {
        let k = ObjectIdentifier(t)
        if let i = touchIDs[k] { return i }
        let i = nextTouchID; nextTouchID += 1; touchIDs[k] = i; return i
    }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let scene else { return }
        for t in touches { touch.began(id: id(t), at: logical(t), modeAt: { scene.touchMode(at: $0) }) }
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches { touch.moved(id: id(t), to: logical(t)) }
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches { touch.ended(id: id(t)); touchIDs[ObjectIdentifier(t)] = nil }
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches { touch.ended(id: id(t), cancelled: true); touchIDs[ObjectIdentifier(t)] = nil }
    }

    // MARK: - Frame

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    /// Startup: forecasts older than the refresh interval (6 h), or "Reset Downloaded Data" switched on, are
    /// deleted, so the channel downloads fresh data behind "One moment, please." instead of showing old data.
    private func clearStaleForecast() {
        let d = UserDefaults.standard
        let dir = ForecastService.cacheDirectory
        var stale = d.bool(forKey: "reset_data")
        if let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]),
           let f = files.first(where: { $0.lastPathComponent.hasSuffix("_forecast.bin") }) {
            let m = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if Date().timeIntervalSince(m) >= 6 * 3600 { stale = true }
        }
        if stale {
            try? FileManager.default.removeItem(at: dir)
            d.set(false, forKey: "reset_data")
        }
    }

    // MARK: - Native Settings (Settings.bundle: location / temp_unit / wind_unit)

    private var settingsPending = true

    // MARK: - Current Location (Settings → Closest Location = "Current Location", the default)

    private let locationManager = CLLocationManager()
    private var locationStarted = false
    private var nearestCity: UInt32?, appliedNearest: UInt32?
    /// Home-country cities of the channel's catalog with their location IDs.
    private lazy var catalog: [(id: UInt32, lat: Double, lon: Double)] = {
        let g = ForecastGenerator()
        return zip(g.cities, g.locationIDs()).filter { $0.0.isHome }.map { ($0.1.raw, $0.0.latitude, $0.0.longitude) }
    }()

    private func startLocation() {
        guard !locationStarted else { return }
        locationStarted = true
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
        locationManager.requestWhenInUseAuthorization()
        locationManager.requestLocation()
    }
    func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        if m.authorizationStatus == .authorizedWhenInUse || m.authorizationStatus == .authorizedAlways { m.requestLocation() }
    }
    func locationManager(_ m: CLLocationManager, didUpdateLocations locs: [CLLocation]) {
        guard let p = locs.last?.coordinate else { return }
        // nearest catalog city by great-circle distance
        func d(_ a: Double, _ b: Double) -> Double {
            let la1 = p.latitude * .pi / 180, la2 = a * .pi / 180, dl = (b - p.longitude) * .pi / 180
            return acos(min(1, sin(la1) * sin(la2) + cos(la1) * cos(la2) * cos(dl)))
        }
        nearestCity = catalog.min { d($0.lat, $0.lon) < d($1.lat, $1.lon) }?.id
    }
    func locationManager(_ m: CLLocationManager, didFailWithError e: Error) {}
    private var mirrored: (UInt32?, Int, Int)?

    /// Settings-app changes → the channel (once it is up); the channel's own changes (first-run location pick) →
    /// the Settings app, so both always agree.
    private func syncSettings(_ scene: WeatherScene) {
        let d = UserDefaults.standard
        // "Reset Downloaded Data": mark the forecasts stale and reboot the channel — it shows what it has and
        // downloads fresh data in the background (never stuck on "One moment, please." if the service is down).
        if settingsPending && d.bool(forKey: "reset_data"), let ctx {
            d.set(false, forKey: "reset_data")
            try? FileManager.default.removeItem(at: ForecastService.cacheDirectory)   // fresh download
            ctx.data = nil
            _ = ctx.pendingData.take()
            self.scene = try? WeatherScene(ctx: ctx)
            return
        }
        guard scene.state == .normal || scene.state == .globe else { return }
        // First run of this build: the channel's save is the truth — publish it to Settings instead of applying
        // the Settings defaults over it.
        if !d.bool(forKey: "settings_synced") { settingsPending = false; mirrored = nil; d.set(true, forKey: "settings_synced") }
        let auto = d.integer(forKey: "location") == 0      // "Current Location"
        if auto { startLocation() }
        if settingsPending || (auto && nearestCity != nil && nearestCity != appliedNearest) {
            settingsPending = false
            var loc: UInt32? = UInt32(truncatingIfNeeded: d.integer(forKey: "location"))
            if auto { loc = nearestCity; appliedNearest = nearestCity }
            scene.applyExternalSettings(location: loc == 0 ? nil : loc, temp: d.integer(forKey: "temp_unit"),
                                        wind: d.integer(forKey: "wind_unit"))
        }
        let cur = scene.currentSettings
        if mirrored == nil || mirrored!.0 != cur.location || mirrored!.1 != cur.temp || mirrored!.2 != cur.wind {
            // Keep "Current Location" selected while automatic; otherwise show the channel's city.
            if !auto { d.set(Int(cur.location ?? 0), forKey: "location") }
            d.set(cur.temp, forKey: "temp_unit"); d.set(cur.wind, forKey: "wind_unit")
            mirrored = (cur.location, cur.temp, cur.wind)
        }
    }

    func draw(in view: MTKView) {
        guard let ctx, let scene else { return }
        var s = touch.sample()
        s.held.formUnion(extraButtons); extraButtons = []
        ctx.gestures = touch.gestures
        ctx.pad.update(s)
        // No HOME Menu / manual on the iPhone: the scene runs every frame.
        if scene.wantsSuspend {
            // No Wii Menu on the iPhone: the only way here is an error box's "Try Again" — reboot the channel
            // ("One moment, please." → a fresh download attempt).
            ctx.data = nil; _ = ctx.pendingData.take()
            self.scene = try? WeatherScene(ctx: ctx)
        } else {
            scene.calc()
            syncSettings(scene)
        }
        sound?.update()
        guard let rpd = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let cb = queue.makeCommandBuffer() else { return }
        let vp = MTLViewport(originX: 0, originY: 0, width: Double(view.drawableSize.width),
                             height: Double(view.drawableSize.height), znear: 0, zfar: 1)
        scene.render(commandBuffer: cb, pass: rpd, viewport: vp)
        cb.present(drawable)
        cb.commit()
    }
}
