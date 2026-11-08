import Metal
import NW4R
import simd

/// Shared state that the original keeps in globals / the CScene base (d_scene.cpp, d_s_weather.cpp).
/// Every screen gets the same context object.
public final class SceneContext {
    public let assets: Assets
    public let device: MTLDevice
    public let gx: GXMetal
    public let lyt: LytRenderer
    public let sound: SoundManager?
    public let pad: KPad
    public let ui: UIInput
    public let isWide: Bool
    public var screenWidth: Float { isWide ? 832 : 608 }

    // Language / region (lbl_80330B36, lbl_80330B3C, lbl_80330B38). US build: English, region US.
    public var lang: Lang = .us
    public var region = 1
    public var countryCode: UInt8 = 49          // SYSCONF country (USA = 49)

    // Settings (save data fields) — lbl_803309F0 temp unit (0 °C, 1 °F), lbl_803309F4 wind unit (0 mph, 1 km/h),
    // lbl_80330A00 location ID.
    public var tempUnit = 1
    public var windUnit = 0
    public var locationID = LocationID(raw: 0)
    /// City whose pages the hub shows when entered from a globe marker (non-top-level hub); nil = locationID.
    public var displayLocation: LocationID?
    /// lbl_803309D0: screen point (SetOrtho2D px) of the globe marker that opened the city — the zoom centre.
    public var markerPoint = SIMD2<Float>(0, 0)
    public var isDaytime = true                 // lbl_803309EC (local hour 5..17)
    public var startPage = 1                    // lbl_803309E0
    public var pageCount = 5                    // lbl_803309E4 (4 JP, 5 otherwise)
    public var globeMode = 0                    // lbl_803309E8 (around display mode 0..5)
    public var isTopLevel = true                // lbl_8032FD00 (hub back = "Wii Menu")
    public var request = 0                      // lbl_8032FCF0 request codes (1 change city … 5 open globe)
    public var returnToWiiMenu = false          // lbl_80330BB9

    /// Parsed forecast data (lbl_803309B4).
    public var data: WeatherData?
    /// Background refresh result (stale cache shown at boot); applied by WeatherScene when the hub is entered.
    public let pendingData = PendingData()

    /// Fades: m_pFade (opaque black), m_pFade2 (dim 0xA0 behind dialogs).
    public let fade = Fade(maxAlpha: 255, startOpaque: true)
    public let fade2 = Fade(maxAlpha: 0xA0, startOpaque: false)

    /// The globe (g_pSimpleGlobe + earth model renderer), shared by the hub's globe button, CAround and CAddress.
    public let globeScene: GlobeScene

    public init(assets: Assets, device: MTLDevice, colorFormat: MTLPixelFormat, depthFormat: MTLPixelFormat,
                sound: SoundManager?, isWide: Bool = true) throws {
        self.assets = assets; self.device = device; self.sound = sound; self.isWide = isWide
        if TextureOverrides.directory == nil { TextureOverrides.directory = assets.directory.appendingPathComponent("upscaled") }
        gx = GXMetal(device: device, colorFormat: colorFormat, depthFormat: depthFormat)
        lyt = LytRenderer(gx: gx)
        lyt.textureProvider = { assets.layoutTexture($0) }
        lyt.fontProvider = { assets.font($0) }
        pad = KPad()
        ui = UIInput(isWide: isWide)
        ui.playSE = { [weak sound] in sound?.playSE($0) }
        globeScene = try GlobeScene(device: device, assets: assets, colorFormat: colorFormat, depthFormat: depthFormat,
                                    isWide: isWide, sound: sound, pad: pad)
        let hour = Calendar.current.component(.hour, from: Date())
        isDaytime = (5...17).contains(hour)
    }

    /// iPhone: this frame's touch gestures (pinch / two-finger pan / rotation / one-finger drag). Neutral on the Mac.
    public var gestures = TouchInput.Gestures()
    /// iPhone portrait presentation (LogicalScreen.isPortrait): screens use their portrait arrangements.
    public var isPortrait: Bool { LogicalScreen.isPortrait }
    public var screenHeight: Float { LogicalScreen.height }
    /// WPAD_RumblePattern → haptics on the iPhone.
    public var rumble: (Int, Int) -> Void = { _, _ in } {
        didSet { ui.rumble = rumble }
    }

    // MARK: - Prewarm (everything uploaded ahead of first use, a few items per frame from boot)

    private var prewarmJobs: [() -> Void] = []
    private var prewarmQueued = false
    /// Queue every layout texture, font sheet and sprite image (`sprites` supplies TPLCommon/TPLWeather).
    public func queuePrewarm(sprites: SpriteText?) {
        guard !prewarmQueued else { return }
        prewarmQueued = true
        var jobs: [() -> Void] = []
        if let arc = try? assets.weatherLayoutArchive() {
            for path in arc.files.keys.sorted() {
                if path.hasPrefix("/arc/timg/") {
                    let name = String(path.dropFirst("/arc/timg/".count))
                    jobs.append { [weak self] in self?.lyt.prewarmTexture(name) }
                } else if path.hasPrefix("/arc/font/") {
                    let name = String(path.dropFirst("/arc/font/".count))
                    jobs.append { [weak self] in if let s = self, let f = s.assets.font(name) { s.lyt.prewarmFont(f) } }
                }
            }
        }
        for name in ["font_weather_city.brfnt", "font_weather_time.brfnt", "font_weather_timeWW.brfnt"] {
            jobs.append { [weak self] in if let s = self, let f = s.assets.font(name) { s.lyt.prewarmFont(f) } }
        }
        jobs.append { [weak self] in if let s = self, let f = s.assets.systemFont() { s.lyt.prewarmFont(f) } }
        if let sp = sprites { jobs += sp.prewarmJobs() }
        prewarmJobs = jobs
    }
    /// Run up to `budget` prewarm items (called once per frame).
    public func stepPrewarm(_ budget: Int = 6) {
        var n = 0
        while n < budget, !prewarmJobs.isEmpty { prewarmJobs.removeFirst()(); n += 1 }
    }

    /// Snd_StartSoundHandle(id)
    public func playSE(_ id: Int) { sound?.playSE(id) }

    /// Load a UILayout from weather_layout.arc with the current language.
    public func layout(_ name: String, colorScheme: Int = 0) throws -> UILayout {
        try UILayout(assets: assets, name, lang: lang, colorScheme: colorScheme, isWide: isWide)
    }
}

/// Thread-safe slot for data produced off the main thread.
public final class PendingData: @unchecked Sendable {
    private let lock = NSLock()
    private var value: WeatherData?
    public init() {}
    public func set(_ v: WeatherData) { lock.lock(); value = v; lock.unlock() }
    public func take() -> WeatherData? { lock.lock(); defer { value = nil; lock.unlock() }; return value }
}

/// A screen module (CNormal, CAround, CAddress, CSetting, CMessage…), driven by CWeatherScene.
public protocol Screen: AnyObject {
    /// Per-frame logic (input already updated in ctx.pad).
    func calc()
    /// Draw (2D layouts / globe).
    func draw(_ enc: MTLRenderCommandEncoder)
}

import Foundation
