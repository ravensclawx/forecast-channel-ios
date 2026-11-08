import Foundation

/// Replacement for the channel's WiiConnect24 download path (CWiiConnect24::downloadWeatherForecast/Short,
/// NWC24 tasks 3 = forecast.bin, 4 = short.bin, retry margin 720 min). Instead of weather.wapp.wii.com it
/// generates the same files from Open-Meteo, caches them (as WC24 containers) and validates them with the
/// channel's own rules before handing them to the game.
public actor ForecastService {
    public static var cacheDirectory: URL {
        // Test hook: FC_CACHE_DIR redirects the cache (QA runs never touch the real one).
        if let d = ProcessInfo.processInfo.environment["FC_CACHE_DIR"] { return URL(fileURLWithPath: d, isDirectory: true) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ForecastChannel/wc24dl", isDirectory: true)
    }

    public var refreshInterval: TimeInterval = 6 * 3600   // Open-Meteo free tier: ~850 locations per refresh
    /// iPhone: a forecast snapshot bundled with the app (forecast.bin/short.bin containers), used when there is no
    /// cache yet — the channel always has something to show while a fresh download is attempted in the background.
    nonisolated(unsafe) public static var seedDirectory: URL?
    /// Mark the cache stale so the next boot refreshes it in the background (iPhone "Reset Downloaded Data").
    public static func invalidateCache() {
        try? FileManager.default.removeItem(at: cacheDirectory.appendingPathComponent("generator_version"))
    }
    /// Bump when the generator's output changes meaningfully (2: original marker ranks from the channel's city
    /// lists). A cache written by an older generator counts as stale, so the background refresh rebuilds it.
    public static let generatorVersion = 2
    var versionURL: URL { Self.cacheDirectory.appendingPathComponent("generator_version") }
    public let generator: ForecastGenerator
    public let language: UInt8, countryCode: UInt8
    private var inFlight: Task<WeatherData, Error>?

    public init(generator: ForecastGenerator = ForecastGenerator()) {
        self.generator = generator
        language = generator.options.language; countryCode = generator.options.countryCode
    }

    /// URL the original channel would have used (fn_8000AC44): /<language>/<country:03>/forecast.bin
    public nonisolated func originalURL(_ file: String) -> String {
        String(format: "http://weather.wapp.wii.com/%d/%03d/%@", language, countryCode, file)
    }

    var forecastURL: URL { Self.cacheDirectory.appendingPathComponent(String(format: "%d_%03d_forecast.bin", language, countryCode)) }
    var shortURL: URL { Self.cacheDirectory.appendingPathComponent(String(format: "%d_%03d_short.bin", language, countryCode)) }

    /// Cached data if present and parseable (expired data allowed — the caller decides via `isExpired`).
    public func cached() -> WeatherData? {
        guard let f = try? Data(contentsOf: forecastURL), let s = try? Data(contentsOf: shortURL),
              let fb = try? WC24Container.unwrap([UInt8](f)), let sb = try? WC24Container.unwrap([UInt8](s)) else { return nil }
        return try? WeatherData(forecast: fb, short: sb, language: language, regionType: Int(generator.options.regionFlag), allowExpired: true)
    }

    public func needsRefresh(now: Date = Date()) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: forecastURL.path),
              let m = attrs[.modificationDate] as? Date else { return true }
        let v = (try? String(contentsOf: versionURL, encoding: .utf8)).flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 1
        if v < Self.generatorVersion { return true }
        return now.timeIntervalSince(m) >= refreshInterval
    }

    /// Boot path: never blocks on the network when any cache exists. Returns the cached data (fresh or stale)
    /// immediately and, if it is stale, kicks off a background refresh whose result arrives via `refreshed`.
    /// With no cache at all it waits for a generation (first run only).
    public func loadForBoot(refreshed: @escaping @Sendable (WeatherData) -> Void) async throws -> WeatherData {
        if cached() == nil, let seed = Self.seedDirectory {
            try? FileManager.default.createDirectory(at: Self.cacheDirectory, withIntermediateDirectories: true)
            for u in [forecastURL, shortURL] {
                let src = seed.appendingPathComponent(u.lastPathComponent)
                try? FileManager.default.removeItem(at: u)
                try? FileManager.default.copyItem(at: src, to: u)
            }
            try? FileManager.default.removeItem(at: versionURL)   // stale: refresh in the background
        }
        if let c = cached() {
            if needsRefresh(), inFlight == nil {
                Task { if let d = try? await self.load(force: true) { refreshed(d) } }
            }
            return c
        }
        return try await load(force: true)
    }

    /// Current data: cached if fresh, otherwise regenerated (falls back to stale cache on network failure).
    public func load(force: Bool = false) async throws -> WeatherData {
        if !force, !needsRefresh(), let c = cached() { return c }
        if let t = inFlight { return try await t.value }
        let gen = generator, lang = language, region = Int(generator.options.regionFlag)
        let fURL = forecastURL, sURL = shortURL
        let task = Task<WeatherData, Error> {
            // Test hook: FC_OFFLINE simulates no network connection.
            if ProcessInfo.processInfo.environment["FC_OFFLINE"] != nil { throw URLError(.notConnectedToInternet) }
            let out = try await gen.fetchAndBuild()
            try FileManager.default.createDirectory(at: Self.cacheDirectory, withIntermediateDirectories: true)
            try Data(out.forecastContainer).write(to: fURL, options: .atomic)
            try Data(out.shortContainer).write(to: sURL, options: .atomic)
            try? "\(Self.generatorVersion)".write(to: Self.cacheDirectory.appendingPathComponent("generator_version"), atomically: true, encoding: .utf8)
            return try WeatherData(forecast: out.forecast, short: out.short, language: lang, regionType: region)
        }
        inFlight = task
        defer { inFlight = nil }
        do { return try await task.value } catch {
            if let c = cached() { return c }
            throw error
        }
    }
}
