import Foundation

/// Serializes forecast.bin / short.bin in the original layout (inverse of ForecastFile / ShortFile).
/// Table order follows the layout observed in served files: header, long, summary, weather types, UV, laundry,
/// pollen, places, then the UTF-16 text pool.
public enum ForecastWriter {
    public struct Common {
        public var issued: UInt32, expires: UInt32
        public var countryCode: UInt8 = 49       // USA
        public var language: UInt8 = 1           // English
        public var regionFlag: UInt8 = 1         // 0 JP, 1 US, 2 EU
        public init(issued: UInt32, expires: UInt32, countryCode: UInt8 = 49, language: UInt8 = 1, regionFlag: UInt8 = 1) {
            self.issued = issued; self.expires = expires; self.countryCode = countryCode; self.language = language; self.regionFlag = regionFlag
        }
    }

    static func header(_ w: inout BEWriter, _ c: Common, kind: UInt8) {
        w.u32(0); w.u32(0); w.u32(0)               // version, size, crc (patched)
        w.u32(c.issued); w.u32(c.expires)
        w.u8(c.countryCode); w.u32(UInt32(c.language)); w.u8(c.regionFlag); w.u8(kind); w.u8(0)
    }

    static func finish(_ w: inout BEWriter) -> [UInt8] {
        w.pad(to: 4)
        w.put32(UInt32(w.count), at: 4)
        w.put32(CRC32.checksum(w.bytes[0xC...]), at: 8)
        return w.bytes
    }

    public static func forecastBin(_ c: Common, long: [LongForecast], summaries: [SummaryForecast], weatherTypes: [WeatherType],
                                   uv: [IndexText], laundry: [IndexText], pollen: [IndexText], places: [Place], message: String? = nil) -> [UInt8] {
        var w = BEWriter()
        header(&w, c, kind: 1)                     // 0x00..0x1B
        let tablesAt = w.count                     // 0x1C: message off, then 7×(count, off)
        for _ in 0..<15 { w.u32(0) }               // → 0x58
        var counts: [(Int, Int)] = []              // (count field offset, table offset)

        let longOff = w.count
        for e in long {
            w.u32(e.location.raw); w.u32(e.time.localTime); w.u32(e.time.fileTime); w.u8(e.status); w.u8(0); w.u8(0); w.u8(0)
            e.today.write(&w); e.tomorrow.write(&w)
            for i in 0..<7 { (i < e.week.count ? e.week[i] : WeekForecast(weather: 0xFFFF, highC: 0, lowC: 0, highF: 0, lowF: 0, precipitation: 0xFF)).write(&w) }
        }
        counts.append((long.count, long.isEmpty ? 0 : longOff))
        let sumOff = w.count
        for e in summaries {
            w.u32(e.location.raw); w.u32(e.time.localTime); w.u32(e.time.fileTime); w.u8(e.status); w.u8(0); w.u8(0); w.u8(0)
            e.today.write(&w); e.tomorrow.write(&w)
        }
        counts.append((summaries.count, summaries.isEmpty ? 0 : sumOff))

        // id tables with text offsets patched after the pool is written
        var textRefs: [(at: Int, text: String)] = []
        let wtOff = w.count
        for t in weatherTypes { w.u16(t.code); w.u16(t.displayCode); textRefs.append((w.count, t.name)); w.u32(0) }
        counts.append((weatherTypes.count, wtOff))
        for table in [uv, laundry, pollen] {
            let off = w.count
            for t in table { w.u8(t.id); w.u8(0); w.u8(0); w.u8(0); textRefs.append((w.count, t.text)); w.u32(0) }
            counts.append((table.count, table.isEmpty ? 0 : off))
        }
        let plOff = w.count
        var placeRefs: [(at: Int, text: String?)] = []
        for p in places {
            w.u32(p.id.raw)
            placeRefs.append((w.count, p.city)); w.u32(0)
            placeRefs.append((w.count, p.region)); w.u32(0)
            placeRefs.append((w.count, p.country)); w.u32(0)
            w.s16(p.latitude); w.s16(p.longitude); w.u8(p.zoom1); w.u8(p.zoom2); w.u16(0)
        }
        counts.append((places.count, plOff))

        // text pool (UTF-16BE, even offsets; identical strings shared)
        var pool: [String: Int] = [:]
        func text(_ s: String) -> UInt32 {
            if let o = pool[s] { return UInt32(o) }
            let o = w.count; w.utf16(s); pool[s] = o; return UInt32(o)
        }
        var messageOff: UInt32 = 0
        if let m = message { messageOff = text(m) }
        for ref in textRefs { w.put32(text(ref.text), at: ref.at) }
        for ref in placeRefs { if let s = ref.text, !s.isEmpty { w.put32(text(s), at: ref.at) } }

        w.put32(messageOff, at: tablesAt)
        for (i, (n, off)) in counts.enumerated() {
            w.put32(UInt32(n), at: tablesAt + 4 + i * 8); w.put32(UInt32(off), at: tablesAt + 8 + i * 8)
        }
        return finish(&w)
    }

    public static func shortBin(_ c: Common, current: [CurrentWeather]) -> [UInt8] {
        var w = BEWriter()
        header(&w, c, kind: 0)
        w.u32(UInt32(current.count)); w.u32(0x24)
        for e in current {
            w.u32(e.location.raw); w.u32(e.time.localTime); w.u32(e.time.fileTime)
            w.u16(e.weather); w.u8(e.unknownE); w.s8(e.tempC); w.s8(e.tempF)
            w.u8(e.windDirection); w.u8(e.windKmh); w.u8(e.windMph); w.u16(0); w.u16(0xFFFF)
        }
        return finish(&w)
    }
}
