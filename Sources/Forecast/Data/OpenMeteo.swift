import Foundation

/// Open-Meteo forecast client (https://open-meteo.com — free, no API key, open source; data CC-BY 4.0).
/// Batches many coordinates per request (comma-separated latitude/longitude lists).
public enum OpenMeteo {
    public struct Location: Sendable { public let latitude: Double, longitude: Double }

    public struct Current: Sendable {
        public var temperature: Double?
        public var weatherCode: Int?
        public var windSpeed: Double?
        public var windDirection: Double?
        public var isDay: Bool
        public init(temperature: Double?, weatherCode: Int?, windSpeed: Double?, windDirection: Double?, isDay: Bool) {
            self.temperature = temperature; self.weatherCode = weatherCode; self.windSpeed = windSpeed
            self.windDirection = windDirection; self.isDay = isDay
        }
    }
    public struct Daily: Sendable {
        public var date: String
        public var weatherCode: Int?, tempMax: Double?, tempMin: Double?, precipMax: Double?
        public var windSpeedMax: Double?, windDirection: Double?, uvMax: Double?
    }
    public struct Hourly: Sendable { public var time: String; public var weatherCode: Int?; public var precip: Double? }

    public struct Forecast: Sendable {
        public var utcOffsetSeconds: Int
        public var current: Current
        public var daily: [Daily]        // index 0 = yesterday (past_days=1), 1 = today, 2 = tomorrow, …
        public var hourly: [Hourly]      // local time, from yesterday 00:00
    }

    static let dailyVars = "weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max,wind_speed_10m_max,wind_direction_10m_dominant,uv_index_max"
    static let hourlyVars = "weather_code,precipitation_probability"
    static let currentVars = "temperature_2m,weather_code,wind_speed_10m,wind_direction_10m,is_day"

    public static func url(for locs: [Location]) -> URL {
        var c = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        func f(_ v: Double) -> String { String(format: "%.4f", v) }
        c.queryItems = [
            .init(name: "latitude", value: locs.map { f($0.latitude) }.joined(separator: ",")),
            .init(name: "longitude", value: locs.map { f($0.longitude) }.joined(separator: ",")),
            .init(name: "current", value: currentVars),
            .init(name: "hourly", value: hourlyVars),
            .init(name: "daily", value: dailyVars),
            .init(name: "timezone", value: "auto"),
            .init(name: "past_days", value: "1"),
            .init(name: "forecast_days", value: "9"),
            .init(name: "wind_speed_unit", value: "kmh"),
        ]
        return c.url!
    }

    /// Open-Meteo counts a multi-location request as `locations × weight`; 14 variables over ≤14 days ⇒ 1.4.
    /// Free tier: 600 calls/minute, 5,000/hour, 10,000/day. We stay under `maxWeightPerMinute`.
    public static let weightPerLocation = 1.4
    public static var maxWeightPerMinute = 480.0

    /// Fetch forecasts for `locs` in batches (paced for the free tier); results align with input order.
    /// Session with bounded timeouts so a stalled connection can never hang the boot screen.
    public static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 20; c.timeoutIntervalForResource = 60
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()

    public static func fetch(_ locs: [Location], batch: Int = 60, session: URLSession = OpenMeteo.session,
                             progress: ((Int, Int) -> Void)? = nil) async throws -> [Forecast] {
        var out: [Forecast] = []
        var sent: [(Date, Double)] = []
        var i = 0
        while i < locs.count {
            let chunk = Array(locs[i..<min(i + batch, locs.count)])
            let w = Double(chunk.count) * weightPerLocation
            // rolling one-minute budget
            while true {
                let now = Date()
                sent.removeAll { now.timeIntervalSince($0.0) >= 60 }
                if sent.reduce(0, { $0 + $1.1 }) + w <= maxWeightPerMinute { break }
                let wait = 60 - now.timeIntervalSince(sent[0].0) + 0.5
                try await Task.sleep(nanoseconds: UInt64(max(wait, 0.5) * 1e9))
            }
            var req = URLRequest(url: url(for: chunk))
            req.setValue("ForecastChannel-port/1.0 (personal, non-commercial)", forHTTPHeaderField: "User-Agent")
            var attempt = 0
            while true {
                let (data, resp) = try await session.data(for: req)
                let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
                if status == 200 { out += try parse(data, expected: chunk.count); break }
                attempt += 1
                // 429 = rate limited (minute/hour/day budget). One minute-window retry at most; then fail so the
                // caller falls back to the cache instead of sitting on the boot screen.
                if attempt >= 4 || status == 400 || (status == 429 && attempt >= 2) {
                    throw NSError(domain: "OpenMeteo", code: status, userInfo: [NSLocalizedDescriptionKey: String(decoding: data.prefix(300), as: UTF8.self)])
                }
                // 429 = rate limited: wait out the minute window; otherwise short backoff
                try await Task.sleep(nanoseconds: status == 429 ? 61_000_000_000 : UInt64(attempt) * 2_000_000_000)
            }
            sent.append((Date(), w))
            i += chunk.count
            progress?(i, locs.count)
        }
        return out
    }

    static func parse(_ data: Data, expected: Int) throws -> [Forecast] {
        let json = try JSONSerialization.jsonObject(with: data)
        let items: [[String: Any]] = (json as? [[String: Any]]) ?? ((json as? [String: Any]).map { [$0] } ?? [])
        guard items.count == expected else { throw NSError(domain: "OpenMeteo", code: -1, userInfo: [NSLocalizedDescriptionKey: "expected \(expected) results, got \(items.count)"]) }
        return items.map { o in
            func arr(_ section: String, _ key: String) -> [Any] { ((o[section] as? [String: Any])?[key] as? [Any]) ?? [] }
            func d(_ v: Any?) -> Double? { (v as? NSNumber)?.doubleValue }
            func n(_ v: Any?) -> Int? { (v as? NSNumber)?.intValue }
            let cur = (o["current"] as? [String: Any]) ?? [:]
            let current = Current(temperature: d(cur["temperature_2m"]), weatherCode: n(cur["weather_code"]),
                                  windSpeed: d(cur["wind_speed_10m"]), windDirection: d(cur["wind_direction_10m"]),
                                  isDay: (n(cur["is_day"]) ?? 1) == 1)
            let dt = arr("daily", "time")
            let daily = dt.indices.map { i -> Daily in
                func a(_ k: String) -> Any? { let x = arr("daily", k); return i < x.count ? x[i] : nil }
                return Daily(date: dt[i] as? String ?? "", weatherCode: n(a("weather_code")), tempMax: d(a("temperature_2m_max")),
                             tempMin: d(a("temperature_2m_min")), precipMax: d(a("precipitation_probability_max")),
                             windSpeedMax: d(a("wind_speed_10m_max")), windDirection: d(a("wind_direction_10m_dominant")), uvMax: d(a("uv_index_max")))
            }
            let ht = arr("hourly", "time"), hc = arr("hourly", "weather_code"), hp = arr("hourly", "precipitation_probability")
            let hourly = ht.indices.map { i in Hourly(time: ht[i] as? String ?? "", weatherCode: i < hc.count ? n(hc[i]) : nil, precip: i < hp.count ? d(hp[i]) : nil) }
            return Forecast(utcOffsetSeconds: n(o["utc_offset_seconds"]) ?? 0, current: current, daily: daily, hourly: hourly)
        }
    }
}
