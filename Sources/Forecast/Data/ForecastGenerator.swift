import Foundation

/// Builds forecast.bin + short.bin (original binary formats) from Open-Meteo data for a city catalog,
/// standing in for Nintendo's weather.wapp.wii.com server.
public struct ForecastGenerator {
    public struct Options: Sendable {
        public var countryCode: UInt8 = 49          // USA
        public var language: UInt8 = 1              // English
        public var regionFlag: UInt8 = 1            // US
        /// How long the generated files stay valid (header 0x10). Nintendo's files expired ~63 min after issue;
        /// we refresh less often (free-API budget), so validity = refresh interval + 63 min.
        public var validityMinutes: UInt32 = 3 * 60 + 63
        public init() {}
    }

    public var options = Options()
    public var cities: [CatalogCity]
    public init(cities: [CatalogCity] = CityList.all, options: Options = Options()) { self.cities = cities; self.options = options }

    public struct Output: Sendable {
        public let forecast: [UInt8], short: [UInt8]          // decompressed files
        public var forecastContainer: [UInt8] { WC24Container.wrap(forecast) }
        public var shortContainer: [UInt8] { WC24Container.wrap(short) }
    }

    /// Assign Wii location codes: home cities [country][state#][city#], others [wii country|FE][FE][global#].
    public func locationIDs() -> [LocationID] {
        let states = Array(Set(cities.compactMap { $0.isHome ? $0.region : nil })).sorted()
        var perState: [String: UInt16] = [:]
        var intl: UInt16 = 0
        return cities.map { c in
            if c.isHome, let st = c.region, let si = states.firstIndex(of: st) {
                perState[st, default: 0] += 1
                return LocationID(country: options.countryCode, region: UInt8(si + 1), city: perState[st]!)
            }
            intl += 1
            return LocationID(country: WiiCountry.code(c.iso2), region: 0xFE, city: intl)
        }
    }

    public func fetchAndBuild(now: Date = Date(), progress: ((Int, Int) -> Void)? = nil) async throws -> Output {
        let data = try await OpenMeteo.fetch(cities.map { .init(latitude: $0.latitude, longitude: $0.longitude) }, progress: progress)
        return build(data, now: now)
    }

    // MARK: - Assembly

    static func s8(_ v: Double?) -> Int8 { guard let v, v.isFinite else { return 0 }; return Int8(clamping: Int(v.rounded())) }
    static func f(_ c: Double?) -> Double? { c.map { $0 * 9 / 5 + 32 } }
    static func pct(_ v: Double?) -> UInt8 { guard let v, v.isFinite else { return 0xFF }; return UInt8(clamping: Int(v.rounded())) }
    static func u8(_ v: Double?) -> UInt8 { guard let v, v.isFinite else { return 0 }; return UInt8(clamping: Int(v.rounded())) }

    /// Quarter-day slots 00–06, 06–12, 12–18, 18–24 local: most significant WMO code (highest number) and max precip.
    static func slots(_ fc: OpenMeteo.Forecast, dayIndex: Int) -> (codes: [UInt16], precip: [UInt8]) {
        guard dayIndex < fc.daily.count else { return ([0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF], [0xFF, 0xFF, 0xFF, 0xFF]) }
        let date = fc.daily[dayIndex].date
        let hours = fc.hourly.filter { $0.time.hasPrefix(date) }
        var codes: [UInt16] = [], precip: [UInt8] = []
        for q in 0..<4 {
            let h = hours.filter { Int($0.time.dropFirst(11).prefix(2)).map { $0 / 6 == q } ?? false }
            if let wmo = h.compactMap(\.weatherCode).max() { codes.append(WeatherCodes.code(wmo: wmo, night: q == 0 || q == 3)) } else { codes.append(0xFFFF) }
            precip.append(h.compactMap(\.precip).max().map { pct($0) } ?? 0xFF)
        }
        return (codes, precip)
    }

    static func day(_ fc: OpenMeteo.Forecast, _ i: Int) -> DayForecast {
        let d = i < fc.daily.count ? fc.daily[i] : nil, prev = i - 1 >= 0 && i - 1 < fc.daily.count ? fc.daily[i - 1] : nil
        let sl = slots(fc, dayIndex: i)
        func diff(_ a: Double?, _ b: Double?) -> Int8 { guard let a, let b else { return 0 }; return s8(a.rounded() - b.rounded()) }
        let uv: UInt8 = d?.uvMax.map { UInt8(clamping: Int($0.rounded())) }.map { min($0, 12) } ?? 0xFF
        let kmh = d?.windSpeedMax
        return DayForecast(weather: d?.weatherCode.map { WeatherCodes.code(wmo: $0) } ?? 0xFFFF, slots: sl.codes,
                           highC: s8(d?.tempMax), highCDiff: diff(d?.tempMax, prev?.tempMax),
                           lowC: s8(d?.tempMin), lowCDiff: diff(d?.tempMin, prev?.tempMin),
                           highF: s8(f(d?.tempMax)), highFDiff: diff(f(d?.tempMax), f(prev?.tempMax)),
                           lowF: s8(f(d?.tempMin)), lowFDiff: diff(f(d?.tempMin), f(prev?.tempMin)),
                           precipitation: sl.precip, windDirection: WeatherCodes.windDirection(degrees: d?.windDirection),
                           windKmh: u8(kmh), windMph: u8(kmh.map { $0 * 0.621371 }), uvIndex: uv, laundryIndex: 0xFF, pollenIndex: 0xFF)
    }

    /// Globe marker rank (Place.zoom1 ≤9, zoom2 ≤3): CityMarker_Calc shows a marker when zoom1 ≥ the zoom index
    /// (CAround +302 = SimpleGlobe +9C), so most cities must be rank 0 (only fully zoomed in). Ranks come from the
    /// original channel's city lists (MarkerRanks, via RiiConnect24 File-Maker); cities missing there get a rank
    /// from the same sparse distribution (US list: 57% rank 0, 14% 1, 17% 3, 4% 6, a handful 7/9).
    public static func rank(_ c: CatalogCity) -> (UInt8, UInt8) {
        func norm(_ s: String) -> String {
            s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
        }
        let place = norm(c.region ?? c.country)
        var names = [norm(c.name)]
        if names[0].hasSuffix(" city") { names.append(String(names[0].dropLast(5))) }
        for n in names { if let r = MarkerRanks.table[n + "|" + place] ?? MarkerRanks.table[n + "|" + norm(c.country)] { return r } }
        switch c.population {
        case 8_000_000...: return (9, 3)
        case 3_000_000...: return (7, 3)
        case 1_000_000...: return (6, 3)
        case 400_000...: return (3, 3)
        case 200_000...: return (1, 3)
        default: return (0, 3)
        }
    }

    public func build(_ data: [OpenMeteo.Forecast], now: Date = Date()) -> Output {
        let nowMin = WC24Time.minutes(now)
        let ids = locationIDs()
        var long: [LongForecast] = [], sums: [SummaryForecast] = [], cur: [CurrentWeather] = [], places: [Place] = []
        for (i, c) in cities.enumerated() {
            let fc = data[i], id = ids[i]
            let t = EntryTime(localTime: UInt32(Int(nowMin) + fc.utcOffsetSeconds / 60), fileTime: nowMin)
            let today = Self.day(fc, 1), tomorrow = Self.day(fc, 2)
            if c.isHome {
                let week = (3..<10).map { j -> WeekForecast in
                    let d = j < fc.daily.count ? fc.daily[j] : nil
                    return WeekForecast(weather: d?.weatherCode.map { WeatherCodes.code(wmo: $0) } ?? 0xFFFF,
                                        highC: Self.s8(d?.tempMax), lowC: Self.s8(d?.tempMin),
                                        highF: Self.s8(Self.f(d?.tempMax)), lowF: Self.s8(Self.f(d?.tempMin)), precipitation: Self.pct(d?.precipMax))
                }
                long.append(LongForecast(location: id, time: t, today: today, tomorrow: tomorrow, week: week))
            } else {
                sums.append(SummaryForecast(location: id, time: t, today: today, tomorrow: tomorrow))
            }
            let cc = fc.current
            let kmh = cc.windSpeed
            cur.append(CurrentWeather(location: id, time: t, weather: cc.weatherCode.map { WeatherCodes.code(wmo: $0, night: !cc.isDay) } ?? 0xFFFF,
                                      tempC: Self.s8(cc.temperature), tempF: Self.s8(Self.f(cc.temperature)),
                                      windDirection: WeatherCodes.windDirection(degrees: cc.windDirection) == 0xFF ? 0 : WeatherCodes.windDirection(degrees: cc.windDirection),
                                      windKmh: Self.u8(kmh), windMph: Self.u8(kmh.map { $0 * 0.621371 })))
            let (z1, z2) = Self.rank(c)
            places.append(Place(id: id, city: c.name, region: c.region, country: c.country,
                                latitude: BinaryAngle.encode(c.latitude), longitude: BinaryAngle.encode(c.longitude), zoom1: z1, zoom2: z2))
        }
        // The channel binary-searches these tables by location ID (verified in Dolphin: unsorted data resolves the
        // wrong city), so every table is written in ascending ID order.
        long.sort { $0.location.raw < $1.location.raw }; sums.sort { $0.location.raw < $1.location.raw }
        cur.sort { $0.location.raw < $1.location.raw }; places.sort { $0.id.raw < $1.id.raw }
        let common = ForecastWriter.Common(issued: nowMin, expires: nowMin + options.validityMinutes,
                                           countryCode: options.countryCode, language: options.language, regionFlag: options.regionFlag)
        let forecast = ForecastWriter.forecastBin(common, long: long, summaries: sums, weatherTypes: WeatherCodes.table,
                                                  uv: WeatherCodes.uvTable, laundry: [], pollen: [], places: places)
        let short = ForecastWriter.shortBin(common, current: cur)
        return Output(forecast: forecast, short: short)
    }
}
