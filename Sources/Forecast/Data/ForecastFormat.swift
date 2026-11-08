import Foundation
import RVL

// forecast.bin / short.bin — the Forecast Channel's WiiConnect24 weather data files.
// Layout and validation recovered from main.dol (decomp/notes/forecast_data.md):
//   fn_8000C734  ValidateWeatherFiles (forecast + short)       → ForecastValidator
//   fn_8001FB94  CWeatherData::SetForecast (table binding)     → ForecastFile
//   fn_800201DC  CWeatherData::SetShort                        → ShortFile
//   fn_8000D1EC / fn_8000D450  day / week entry validators
//   fn_80067D44  CRC-32 (reflected 0xEDB88320, init ~0, final ~)
//   fn_8000D4C8  current time as minutes since 2000-01-01 00:00
// All multi-byte values big-endian. Strings are UTF-16BE, NUL-terminated, at even offsets.

// MARK: - Shared primitives

public enum WC24Time {
    /// Minutes since 2000-01-01 00:00 (the channel's fn_8000D4C8 clock).
    public static func minutes(_ date: Date) -> UInt32 { UInt32(max(0, (date.timeIntervalSince1970 - 946_684_800) / 60)) }
    public static func date(_ minutes: UInt32) -> Date { Date(timeIntervalSince1970: 946_684_800 + Double(minutes) * 60) }
}

public enum CRC32 {
    static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }
    public static func checksum<C: Collection>(_ bytes: C) -> UInt32 where C.Element == UInt8 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in bytes { c = table[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return ~c
    }
}

/// 16-bit binary angle (s16) → degrees, as ConvLatLon16ToDeg (fn_8003DFB0): ×360/65536.
public enum BinaryAngle {
    public static func degrees(_ v: Int16) -> Float { Float(v) * 0.005493164 }
    public static func encode(_ deg: Double) -> Int16 { Int16(clamping: Int((deg * 65536 / 360).rounded())) }
}

/// Wii location code: [country u8][region u8][city u16]. 0xFE = "no region / no country list".
public struct LocationID: Hashable, Comparable, CustomStringConvertible, Sendable {
    public let raw: UInt32
    public init(raw: UInt32) { self.raw = raw }
    public init(country: UInt8, region: UInt8, city: UInt16) { raw = UInt32(country) << 24 | UInt32(region) << 16 | UInt32(city) }
    public var country: UInt8 { UInt8(raw >> 24) }
    public var region: UInt8 { UInt8((raw >> 16) & 0xFF) }
    public var city: UInt16 { UInt16(raw & 0xFFFF) }
    public var description: String { String(format: "%02X%02X%04X", country, region, city) }
    public static func < (a: LocationID, b: LocationID) -> Bool { a.raw < b.raw }
}

// MARK: - Records

/// 0x1C-byte day forecast (today / tomorrow), validated by fn_8000D1EC.
public struct DayForecast: Equatable, Sendable {
    public var weather: UInt16                    // 0x00 weather code (→ WeatherType)
    public var slots: [UInt16]                    // 0x02 4× quarter-day weather codes (0xFFFF = none)
    public var highC: Int8, highCDiff: Int8       // 0x0A, 0x0B  (diff vs. previous day)
    public var lowC: Int8, lowCDiff: Int8         // 0x0C, 0x0D
    public var highF: Int8, highFDiff: Int8       // 0x0E, 0x0F
    public var lowF: Int8, lowFDiff: Int8         // 0x10, 0x11
    public var precipitation: [UInt8]             // 0x12 4× % (≤100 or 0xFF)
    public var windDirection: UInt8               // 0x16 1..16 (16 = N, 1 = NNE …) or 0xFF
    public var windKmh: UInt8, windMph: UInt8     // 0x17, 0x18
    public var uvIndex: UInt8                     // 0x19 UV table id or 0xFF
    public var laundryIndex: UInt8                // 0x1A laundry table id or 0xFF (validated only in JP region)
    public var pollenIndex: UInt8                 // 0x1B pollen table id or 0xFF (validated only in JP region)
    public static let size = 0x1C

    public init(weather: UInt16, slots: [UInt16], highC: Int8, highCDiff: Int8, lowC: Int8, lowCDiff: Int8,
                highF: Int8, highFDiff: Int8, lowF: Int8, lowFDiff: Int8, precipitation: [UInt8],
                windDirection: UInt8, windKmh: UInt8, windMph: UInt8, uvIndex: UInt8, laundryIndex: UInt8, pollenIndex: UInt8) {
        self.weather = weather; self.slots = slots; self.highC = highC; self.highCDiff = highCDiff; self.lowC = lowC
        self.lowCDiff = lowCDiff; self.highF = highF; self.highFDiff = highFDiff; self.lowF = lowF; self.lowFDiff = lowFDiff
        self.precipitation = precipitation; self.windDirection = windDirection; self.windKmh = windKmh; self.windMph = windMph
        self.uvIndex = uvIndex; self.laundryIndex = laundryIndex; self.pollenIndex = pollenIndex
    }

    init(_ r: BEReader, _ o: Int) {
        weather = r.u16(o); slots = (0..<4).map { r.u16(o + 2 + $0 * 2) }
        highC = r.s8(o + 0xA); highCDiff = r.s8(o + 0xB); lowC = r.s8(o + 0xC); lowCDiff = r.s8(o + 0xD)
        highF = r.s8(o + 0xE); highFDiff = r.s8(o + 0xF); lowF = r.s8(o + 0x10); lowFDiff = r.s8(o + 0x11)
        precipitation = (0..<4).map { r.u8(o + 0x12 + $0) }
        windDirection = r.u8(o + 0x16); windKmh = r.u8(o + 0x17); windMph = r.u8(o + 0x18)
        uvIndex = r.u8(o + 0x19); laundryIndex = r.u8(o + 0x1A); pollenIndex = r.u8(o + 0x1B)
    }

    func write(_ w: inout BEWriter) {
        w.u16(weather); for i in 0..<4 { w.u16(i < slots.count ? slots[i] : 0xFFFF) }
        for v in [highC, highCDiff, lowC, lowCDiff, highF, highFDiff, lowF, lowFDiff] { w.s8(v) }
        for i in 0..<4 { w.u8(i < precipitation.count ? precipitation[i] : 0xFF) }
        w.u8(windDirection); w.u8(windKmh); w.u8(windMph); w.u8(uvIndex); w.u8(laundryIndex); w.u8(pollenIndex)
    }
}

/// 8-byte extended-forecast day, validated by fn_8000D450.
public struct WeekForecast: Equatable, Sendable {
    public var weather: UInt16                    // 0x00
    public var highC: Int8, lowC: Int8            // 0x02, 0x03
    public var highF: Int8, lowF: Int8            // 0x04, 0x05
    public var precipitation: UInt8               // 0x06 (≤100 or 0xFF)
    public static let size = 8
    public init(weather: UInt16, highC: Int8, lowC: Int8, highF: Int8, lowF: Int8, precipitation: UInt8) {
        self.weather = weather; self.highC = highC; self.lowC = lowC; self.highF = highF; self.lowF = lowF; self.precipitation = precipitation
    }
    init(_ r: BEReader, _ o: Int) {
        weather = r.u16(o); highC = r.s8(o + 2); lowC = r.s8(o + 3); highF = r.s8(o + 4); lowF = r.s8(o + 5); precipitation = r.u8(o + 6)
    }
    func write(_ w: inout BEWriter) { w.u16(weather); w.s8(highC); w.s8(lowC); w.s8(highF); w.s8(lowF); w.u8(precipitation); w.u8(0) }
}

/// Timestamps on a per-city entry: `localTime` is the city's wall clock and `fileTime` the generation time
/// (both minutes since 2000). fn_8002054C uses (localTime − fileTime) as the city's UTC offset.
public struct EntryTime: Equatable, Sendable {
    public var localTime: UInt32, fileTime: UInt32
    public init(localTime: UInt32, fileTime: UInt32) { self.localTime = localTime; self.fileTime = fileTime }
    public var utcOffsetMinutes: Int { Int(Int64(localTime) - Int64(fileTime)) }
}

/// 0x80-byte "long" forecast (home-country cities): today, tomorrow, 7-day.
public struct LongForecast: Equatable, Sendable {
    public var location: LocationID               // 0x00
    public var time: EntryTime                    // 0x04, 0x08
    public var status: UInt8                      // 0x0C (≤5 or 0xFF; generators write 0)
    public var today: DayForecast                 // 0x10
    public var tomorrow: DayForecast              // 0x2C
    public var week: [WeekForecast]               // 0x48 7×8
    public static let size = 0x80
    public init(location: LocationID, time: EntryTime, status: UInt8 = 0, today: DayForecast, tomorrow: DayForecast, week: [WeekForecast]) {
        self.location = location; self.time = time; self.status = status; self.today = today; self.tomorrow = tomorrow; self.week = week
    }
}

/// 0x48-byte "summary" forecast (international cities): today + tomorrow.
public struct SummaryForecast: Equatable, Sendable {
    public var location: LocationID               // 0x00
    public var time: EntryTime                    // 0x04, 0x08
    public var status: UInt8                      // 0x0C
    public var today: DayForecast                 // 0x10
    public var tomorrow: DayForecast              // 0x2C
    public static let size = 0x48
    public init(location: LocationID, time: EntryTime, status: UInt8 = 0, today: DayForecast, tomorrow: DayForecast) {
        self.location = location; self.time = time; self.status = status; self.today = today; self.tomorrow = tomorrow
    }
}

/// Weather type: data code → display (icon) code + localized name.
/// Display code: low 15 bits select the icon (0x00–0x7E; <0x64 static path fn_80020AD4, ≥0x64 animated),
/// bit 15 = night variant. Looked up by fn_800203F0 (returns 0xFFFF when the code is unknown).
public struct WeatherType: Equatable, Sendable {
    public var code: UInt16, displayCode: UInt16, name: String
    public static let size = 8
    public init(code: UInt16, displayCode: UInt16, name: String) { self.code = code; self.displayCode = displayCode; self.name = name }
}

/// UV / laundry / pollen index text entries (u8 id, 3 pad, u32 text offset).
public struct IndexText: Equatable, Sendable {
    public var id: UInt8, text: String
    public static let size = 8
    public init(id: UInt8, text: String) { self.id = id; self.text = text }
}

/// 0x18-byte location.
public struct Place: Equatable, Sendable {
    public var id: LocationID                     // 0x00
    public var city: String                       // 0x04 (required)
    public var region: String?                    // 0x08 (state / province, optional)
    public var country: String?                   // 0x0C (optional)
    public var latitude: Int16, longitude: Int16  // 0x10, 0x12 binary angles
    public var zoom1: UInt8                       // 0x14 (≤9) globe marker rank: shown when rank ≥ zoom index
    public var zoom2: UInt8                       // 0x15 (≤3)
    public static let size = 0x18
    public init(id: LocationID, city: String, region: String?, country: String?, latitude: Int16, longitude: Int16, zoom1: UInt8, zoom2: UInt8) {
        self.id = id; self.city = city; self.region = region; self.country = country
        self.latitude = latitude; self.longitude = longitude; self.zoom1 = zoom1; self.zoom2 = zoom2
    }
    public var latitudeDegrees: Float { BinaryAngle.degrees(latitude) }
    public var longitudeDegrees: Float { BinaryAngle.degrees(longitude) }
}

/// 0x18-byte current conditions (short.bin) — used by the globe's "now" markers.
public struct CurrentWeather: Equatable, Sendable {
    public var location: LocationID               // 0x00
    public var time: EntryTime                    // 0x04, 0x08
    public var weather: UInt16                    // 0x0C (0xFFFF = none)
    public var unknownE: UInt8                    // 0x0E (≤99 or 0xFF; generators write 0)
    public var tempC: Int8, tempF: Int8           // 0x0F, 0x10
    public var windDirection: UInt8               // 0x11 (≤16)
    public var windKmh: UInt8, windMph: UInt8     // 0x12, 0x13
    public static let size = 0x18
    public init(location: LocationID, time: EntryTime, weather: UInt16, unknownE: UInt8 = 0, tempC: Int8, tempF: Int8,
                windDirection: UInt8, windKmh: UInt8, windMph: UInt8) {
        self.location = location; self.time = time; self.weather = weather; self.unknownE = unknownE
        self.tempC = tempC; self.tempF = tempF; self.windDirection = windDirection; self.windKmh = windKmh; self.windMph = windMph
    }
}

/// Common 0x20-byte header prefix.
public struct WeatherFileHeader: Equatable, Sendable {
    public var version: UInt32                    // 0x00 (upper 16 bits must be 0 → else -3)
    public var size: UInt32                       // 0x04 total size
    public var crc: UInt32                        // 0x08 CRC-32 of [0x0C, size)
    public var issued: UInt32                     // 0x0C generation time (min since 2000)
    public var expires: UInt32                    // 0x10 data older than now → -2
    public var countryCode: UInt8                 // 0x14 Wii country code (049 = USA)
    public var language: UInt8                    // 0x18 low byte of u32 at 0x15; must equal the console language (lbl_80330B36)
    public var regionFlag: UInt8                  // 0x19 (≤2) 0 JP, 1 US, 2 EU (matches lbl_80330B3C)
    public var kind: UInt8                        // 0x1A (≤1) forecast=1, short=0
}

// MARK: - Validation (fn_8000C734)

/// Result of fn_8000C734 for each file: 0 ok, -1 corrupt, -2 expired, -3 unsupported version.
public struct ValidationResult: Equatable, CustomStringConvertible, Sendable {
    public var forecast: Int32, short: Int32
    /// forecast.bin carried a message (header 0x1C ≠ 0) — channel shows it instead of data (returns 1 early).
    public var hasMessage: Bool
    public var ok: Bool { (forecast == 0 && short == 0) || (hasMessage && forecast == 0) }
    public var description: String { "forecast=\(forecast) short=\(short)\(hasMessage ? " (message)" : "")" }
}

public enum ForecastValidator {
    /// `now`: minutes since 2000 (fn_8000D4C8). `language`: console language (header 0x18 must match).
    /// `regionType`: lbl_80330B3C (0 JP, 1 US, 2 EU) — laundry/pollen ids are only checked for JP.
    public static func validate(forecast f: [UInt8], short s: [UInt8], now: UInt32, language: UInt8, regionType: Int) -> ValidationResult {
        var e: Int32 = 0, es: Int32 = 0
        guard f.count >= 0x58, s.count >= 0x24 else { return ValidationResult(forecast: -1, short: -1, hasMessage: false) }
        let r = BEReader(f), rs = BEReader(s)
        let size = r.u32(4)
        func u(_ o: Int) -> Int { Int(r.u32(o)) }
        // table offsets must be 4-aligned
        for o in [0x24, 0x2C, 0x34, 0x3C, 0x44, 0x4C, 0x54] where u(o) & 3 != 0 { e = -1 }
        if Int(rs.u32(0x20)) & 3 != 0 { es = -1 }
        if e != 0 || es != 0 { return ValidationResult(forecast: e, short: es, hasMessage: false) }

        if r.u32(0) & 0xFFFF_0000 != 0 { e = -3 }
        if size != UInt32(f.count) { e = -1 }
        if r.u32(8) != CRC32.checksum(f[0xC..<min(Int(size), f.count)]) { e = -1 }
        if e == -1 { return ValidationResult(forecast: e, short: es, hasMessage: false) }
        if r.u32(0x10) < now && e == 0 { e = -2 }
        if r.u8(0x18) != language { e = -1 }
        let msg = r.u32(0x1C)
        if msg >= size || msg & 1 != 0 { e = -1 }
        if msg != 0 && e == 0 { return ValidationResult(forecast: 0, short: 0, hasMessage: true) }
        if r.u8(0x19) > 2 { e = -1 }
        if r.u8(0x1A) > 1 { e = -1 }
        let tables: [(count: Int, off: Int, stride: Int)] = [
            (0x20, 0x24, 0x80), (0x28, 0x2C, 0x48), (0x30, 0x34, 8), (0x38, 0x3C, 8), (0x40, 0x44, 8), (0x48, 0x4C, 8), (0x50, 0x54, 0x18)]
        for t in tables where UInt64(u(t.off)) + UInt64(u(t.count) * t.stride) > UInt64(size) { e = -1 }
        if e != 0 { return ValidationResult(forecast: e, short: es, hasMessage: false) }

        let nLong = u(0x20), longOff = u(0x24), nSum = u(0x28), sumOff = u(0x2C)
        let nWT = u(0x30), wtOff = u(0x34), nUV = u(0x38), uvOff = u(0x3C)
        let nLa = u(0x40), laOff = u(0x44), nPo = u(0x48), poOff = u(0x4C), nPl = u(0x50), plOff = u(0x54)
        let placeIDs = (0..<nPl).map { r.u32(plOff + $0 * 0x18) }
        let wtCodes = Set((0..<nWT).map { r.u16(wtOff + $0 * 8) })
        let uvIDs = Set((0..<nUV).map { r.u8(uvOff + $0 * 8) })
        let laIDs = Set((0..<nLa).map { r.u8(laOff + $0 * 8) })
        let poIDs = Set((0..<nPo).map { r.u8(poOff + $0 * 8) })
        func okCode(_ c: UInt16) -> Bool { c == 0xFFFF || wtCodes.contains(c) }
        func pct(_ v: UInt8, _ max: UInt8) -> Bool { v <= max || v == 0xFF }

        func day(_ o: Int) -> Int32 {                          // fn_8000D1EC
            var res: Int32 = 0
            if !okCode(r.u16(o)) { res = -1 }
            for i in 0..<4 where !okCode(r.u16(o + 2 + i * 2)) { res = -1 }
            for i in 0..<4 where !pct(r.u8(o + 0x12 + i), 100) { res = -1 }
            if !pct(r.u8(o + 0x16), 16) { res = -1 }
            if r.u8(o + 0x19) != 0xFF && !uvIDs.contains(r.u8(o + 0x19)) { res = -1 }
            if regionType == 0 {
                if r.u8(o + 0x1A) != 0xFF && !laIDs.contains(r.u8(o + 0x1A)) { res = -1 }
                if r.u8(o + 0x1B) != 0xFF && !poIDs.contains(r.u8(o + 0x1B)) { res = -1 }
            }
            return res
        }
        func week(_ o: Int) -> Int32 {                         // fn_8000D450
            (okCode(r.u16(o)) && pct(r.u8(o + 6), 100)) ? 0 : -1
        }
        func first(_ v: Int32) { if e == 0 { e = v } }
        for i in 0..<nLong {
            let o = longOff + i * 0x80
            if placeIDs.filter({ $0 == r.u32(o) }).count != 1 { e = -1 }
            if !pct(r.u8(o + 0xC), 5) { e = -1 }
            for d in 0..<2 { first(day(o + 0x10 + d * 0x1C)) }
            for w in 0..<7 { first(week(o + 0x48 + w * 8)) }
        }
        for i in 0..<nSum {
            let o = sumOff + i * 0x48
            if placeIDs.filter({ $0 == r.u32(o) }).count != 1 { e = -1 }
            if !pct(r.u8(o + 0xC), 5) { e = -1 }
            for d in 0..<2 { first(day(o + 0x10 + d * 0x1C)) }
        }
        // id tables: unique ids, even in-bounds text offsets
        for (n, off, key) in [(nWT, wtOff, 2), (nUV, uvOff, 1), (nLa, laOff, 1), (nPo, poOff, 1)] {
            for i in 0..<n {
                let o = off + i * 8
                let k = key == 2 ? UInt32(r.u16(o)) : UInt32(r.u8(o))
                for j in 0..<n where j != i && (key == 2 ? UInt32(r.u16(off + j * 8)) : UInt32(r.u8(off + j * 8))) == k { e = -1 }
                let t = r.u32(o + 4); if t >= size || t & 1 != 0 { e = -1 }
            }
        }
        let longIDs = Set((0..<nLong).map { r.u32(longOff + $0 * 0x80) }), sumIDs = Set((0..<nSum).map { r.u32(sumOff + $0 * 0x48) })
        let nShort = Int(rs.u32(0x1C)), shortOff = Int(rs.u32(0x20))
        let shortIDs = Set((0..<nShort).map { rs.u32(shortOff + $0 * 0x18) })
        for i in 0..<nPl {
            let o = plOff + i * 0x18, id = r.u32(o)
            if placeIDs.filter({ $0 == id }).count != 1 { e = -1 }
            if !(longIDs.contains(id) || sumIDs.contains(id) || shortIDs.contains(id)) { e = -1 }
            for t in [r.u32(o + 4), r.u32(o + 8), r.u32(o + 0xC)] where t >= size || t & 1 != 0 { e = -1 }
            if r.u8(o + 0x14) > 9 || r.u8(o + 0x15) > 3 { e = -1 }
        }

        // short.bin
        if rs.u32(0) & 0xFFFF_0000 != 0 { es = -3 }
        if rs.u32(4) != UInt32(s.count) { es = -1 }
        if rs.u32(8) != CRC32.checksum(s[0xC...]) { es = -1 }
        if rs.u32(0x10) < now && es == 0 { es = -2 }
        if rs.u8(0x18) != language { es = -1 }
        if UInt64(shortOff) + UInt64(nShort * 0x18) > UInt64(rs.u32(4)) { es = -1 }
        if es != 0 { return ValidationResult(forecast: e, short: es, hasMessage: false) }
        for i in 0..<nShort {
            let o = shortOff + i * 0x18
            if placeIDs.filter({ $0 == rs.u32(o) }).count != 1 { es = -1 }
            let c = rs.u16(o + 0xC)
            if c != 0xFFFF && !wtCodes.contains(c) { es = -1 }
            if !pct(rs.u8(o + 0xE), 0x63) { es = -1 }
            if !pct(rs.u8(o + 0x11), 0x10) { es = -1 }
        }
        return ValidationResult(forecast: e, short: es, hasMessage: false)
    }
}

// MARK: - Parsed files (fn_8001FB94 / fn_800201DC)

public enum WeatherDataError: Error, Equatable, CustomStringConvertible {
    /// Error codes returned by fn_8001FB94 / fn_800201DC (0x18 = success); names from main.dol's error strings.
    case code(Int, String)
    case invalid(ValidationResult)
    case container(String)
    public var description: String {
        switch self {
        case let .code(c, n): String(format: "0x%02X %@", c, n)
        case let .invalid(v): "validation failed: \(v)"
        case let .container(s): "container: \(s)"
        }
    }
    static func e(_ c: Int) -> WeatherDataError {
        let names: [Int: String] = [
            0x2: "MEM_ERROR_WeatherForecasts_e", 0x3: "MEM_ERROR_WeatherSummary_e", 0x4: "MEM_ERROR_WeatherType_e",
            0x5: "MEM_ERROR_Places_e", 0x7: "MEM_ERROR_UVIndex_e", 0x8: "MEM_ERROR_LaundryIndex_e", 0x9: "MEM_ERROR_PollenIndex_e",
            0xA: "ERROR_MESSAGE_e", 0xB: "ERROR_NumForecasts_e", 0xC: "ERROR_NumWeatherTypes_e", 0xD: "ERROR_NumPlaces_e",
            0xE: "ERROR_ShortNumNowWeathers_e", 0xF: "ERROR_ForecastArrayAddr_e", 0x10: "ERROR_SummaryForecastArrayAddr_e",
            0x11: "ERROR_WeatherTypesArrayAddr_e", 0x12: "ERROR_PlaceArrayAddr_e", 0x13: "ERROR_WeatherTypeNameAddr_e",
            0x14: "ERROR_ShortNowWeatherArrayAddr_e", 0x15: "UVIndex text", 0x16: "LaundryIndex text", 0x17: "PollenIndex text"]
        return .code(c, names[c] ?? "?")
    }
}

func utf16String(_ r: BEReader, _ o: Int) -> String {
    var units: [UInt16] = [], p = o
    while p + 1 < r.data.count { let u = r.u16(p); if u == 0 { break }; units.append(u); p += 2 }
    return String(decoding: units, as: UTF16.self)
}

public struct ForecastFile: Sendable {
    public let header: WeatherFileHeader
    public let message: String?
    public let longForecasts: [LongForecast]
    public let summaries: [SummaryForecast]
    public let weatherTypes: [WeatherType]
    public let uvIndex: [IndexText], laundryIndex: [IndexText], pollenIndex: [IndexText]
    public let places: [Place]

    /// fn_8001FB94. Throws the same error codes the channel would report.
    public init(_ bytes: [UInt8]) throws {
        let r = BEReader(bytes)
        func u(_ o: Int) -> Int { Int(r.u32(o)) }
        header = WeatherFileHeader(version: r.u32(0), size: r.u32(4), crc: r.u32(8), issued: r.u32(0xC), expires: r.u32(0x10),
                                   countryCode: r.u8(0x14), language: r.u8(0x18), regionFlag: r.u8(0x19), kind: r.u8(0x1A))
        if u(0x1C) != 0 {
            message = utf16String(r, u(0x1C))
            longForecasts = []; summaries = []; weatherTypes = []; uvIndex = []; laundryIndex = []; pollenIndex = []; places = []
            return
        }
        message = nil
        if u(0x20) == 0 && u(0x28) == 0 { throw WeatherDataError.e(0xB) }
        if u(0x20) != 0 && u(0x24) == 0 { throw WeatherDataError.e(0xF) }
        if u(0x28) != 0 && u(0x2C) == 0 { throw WeatherDataError.e(0x10) }
        if u(0x30) == 0 { throw WeatherDataError.e(0xC) }
        if u(0x34) == 0 { throw WeatherDataError.e(0x11) }
        if u(0x50) == 0 { throw WeatherDataError.e(0xD) }
        if u(0x54) == 0 { throw WeatherDataError.e(0x12) }

        func entryTime(_ o: Int) -> EntryTime { EntryTime(localTime: r.u32(o + 4), fileTime: r.u32(o + 8)) }
        longForecasts = (0..<u(0x20)).map { i in
            let o = u(0x24) + i * 0x80
            return LongForecast(location: LocationID(raw: r.u32(o)), time: entryTime(o), status: r.u8(o + 0xC),
                                today: DayForecast(r, o + 0x10), tomorrow: DayForecast(r, o + 0x2C),
                                week: (0..<7).map { WeekForecast(r, o + 0x48 + $0 * 8) })
        }
        summaries = (0..<u(0x28)).map { i in
            let o = u(0x2C) + i * 0x48
            return SummaryForecast(location: LocationID(raw: r.u32(o)), time: entryTime(o), status: r.u8(o + 0xC),
                                   today: DayForecast(r, o + 0x10), tomorrow: DayForecast(r, o + 0x2C))
        }
        var wts: [WeatherType] = []
        for i in 0..<u(0x30) {                                       // fn_80028A50
            let o = u(0x34) + i * 8
            guard r.u32(o + 4) != 0 else { throw WeatherDataError.e(0x13) }
            wts.append(WeatherType(code: r.u16(o), displayCode: r.u16(o + 2), name: utf16String(r, u(o + 4))))
        }
        weatherTypes = wts
        func indexTable(_ n: Int, _ off: Int, _ err: Int) throws -> [IndexText] {
            try (0..<u(n)).map { i in
                let o = u(off) + i * 8
                guard r.u32(o + 4) != 0 else { throw WeatherDataError.e(err) }
                return IndexText(id: r.u8(o), text: utf16String(r, u(o + 4)))
            }
        }
        uvIndex = try indexTable(0x38, 0x3C, 0x15)                 // fn_80028A78
        laundryIndex = try indexTable(0x40, 0x44, 0x16)            // fn_80020F74
        pollenIndex = try indexTable(0x48, 0x4C, 0x17)             // fn_80027D80
        places = (0..<u(0x50)).map { i in                          // fn_80027D3C
            let o = u(0x54) + i * 0x18
            let reg = u(o + 8), cty = u(o + 0xC)
            return Place(id: LocationID(raw: r.u32(o)), city: utf16String(r, u(o + 4)),
                         region: reg != 0 ? utf16String(r, reg) : nil, country: cty != 0 ? utf16String(r, cty) : nil,
                         latitude: r.s16(o + 0x10), longitude: r.s16(o + 0x12), zoom1: r.u8(o + 0x14), zoom2: r.u8(o + 0x15))
        }
    }

    /// fn_800203F0: data weather code → display code (0xFFFF if unknown).
    public func displayCode(for code: UInt16) -> UInt16 { weatherTypes.first { $0.code == code }?.displayCode ?? 0xFFFF }
    public func weatherName(for code: UInt16) -> String? { weatherTypes.first { $0.code == code }?.name }
    public func place(_ id: LocationID) -> Place? { places.first { $0.id == id } }
}

public struct ShortFile: Sendable {
    public let header: WeatherFileHeader
    public let current: [CurrentWeather]

    /// fn_800201DC
    public init(_ bytes: [UInt8]) throws {
        let r = BEReader(bytes)
        header = WeatherFileHeader(version: r.u32(0), size: r.u32(4), crc: r.u32(8), issued: r.u32(0xC), expires: r.u32(0x10),
                                   countryCode: r.u8(0x14), language: r.u8(0x18), regionFlag: r.u8(0x19), kind: r.u8(0x1A))
        let n = Int(r.u32(0x1C)), off = Int(r.u32(0x20))
        if n == 0 { throw WeatherDataError.e(0xE) }
        if off == 0 { throw WeatherDataError.e(0x14) }
        current = (0..<n).map { i in
            let o = off + i * 0x18
            return CurrentWeather(location: LocationID(raw: r.u32(o)), time: EntryTime(localTime: r.u32(o + 4), fileTime: r.u32(o + 8)),
                                  weather: r.u16(o + 0xC), unknownE: r.u8(o + 0xE), tempC: r.s8(o + 0xF), tempF: r.s8(o + 0x10),
                                  windDirection: r.u8(o + 0x11), windKmh: r.u8(o + 0x12), windMph: r.u8(o + 0x13))
        }
    }
}

/// Validated pair, as the channel holds them after a successful download (CWeatherData).
public struct WeatherData: Sendable {
    public let forecast: ForecastFile
    public let short: ShortFile
    public let validation: ValidationResult

    /// Load raw (decompressed) forecast/short bytes exactly as the channel does: validate (fn_8000C734), then bind.
    public init(forecast f: [UInt8], short s: [UInt8], now: Date = Date(), language: UInt8 = 1, regionType: Int = 1, allowExpired: Bool = false) throws {
        var v = ForecastValidator.validate(forecast: f, short: s, now: WC24Time.minutes(now), language: language, regionType: regionType)
        if allowExpired { if v.forecast == -2 { v.forecast = 0 }; if v.short == -2 { v.short = 0 } }
        guard v.ok else { throw WeatherDataError.invalid(v) }
        validation = v
        forecast = try ForecastFile(f)
        short = try ShortFile(s)
    }
}
