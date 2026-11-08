/// Weather-type table emitted by our generator, and the WMO (Open-Meteo `weather_code`) → channel mapping.
///
/// The channel does not hard-code data codes: forecast.bin carries a table {data code u16, display code u16,
/// name offset} and fn_800203F0 maps a forecast's data code to the display code that picks the icon
/// (fn_80020574: low 15 bits 0x00–0x7E, bit 15 = night). We therefore use data code == display code.
///
/// Display-code meanings for the international (≥0x64) icon set follow the codes the channel was served
/// historically (cross-checked against RiiConnect24 File-Maker's condition list, AGPL-3.0, used as a reference
/// only — no code or text copied). Names below are our own English strings.
public enum WeatherCodes {
    public struct Kind: Sendable { public let display: UInt16; public let name: String; public let hasNight: Bool }

    public static let sunny = Kind(display: 0x65, name: "Sunny", hasNight: true)
    public static let partlyCloudy = Kind(display: 0x66, name: "Partly Cloudy", hasNight: true)
    public static let partlySunnyShowers = Kind(display: 0x67, name: "Partly Sunny with Showers", hasNight: false)
    public static let partlySunnyFlurries = Kind(display: 0x68, name: "Partly Sunny with Flurries", hasNight: false)
    public static let cloudy = Kind(display: 0x6A, name: "Cloudy", hasNight: true)
    public static let mostlyCloudy = Kind(display: 0x6B, name: "Mostly Cloudy", hasNight: true)
    public static let cloudyShowers = Kind(display: 0x6C, name: "Mostly Cloudy with Showers", hasNight: true)
    public static let cloudySnow = Kind(display: 0x6D, name: "Mostly Cloudy with Snow", hasNight: true)
    public static let rain = Kind(display: 0x6F, name: "Rain", hasNight: false)
    public static let showers = Kind(display: 0x71, name: "Showers", hasNight: true)
    public static let rainSnow = Kind(display: 0x72, name: "Rain and Snow", hasNight: false)
    public static let freezingRain = Kind(display: 0x73, name: "Freezing Rain", hasNight: false)
    public static let snow = Kind(display: 0x74, name: "Snow", hasNight: false)
    public static let flurries = Kind(display: 0x76, name: "Flurries", hasNight: true)
    public static let sleet = Kind(display: 0x79, name: "Sleet", hasNight: false)
    public static let haze = Kind(display: 0x7A, name: "Haze", hasNight: true)
    public static let fog = Kind(display: 0x7C, name: "Fog", hasNight: false)
    public static let thunder = Kind(display: 0x7D, name: "Thunderstorms", hasNight: true)

    public static let all: [Kind] = [sunny, partlyCloudy, partlySunnyShowers, partlySunnyFlurries, cloudy, mostlyCloudy, cloudyShowers,
                                     cloudySnow, rain, showers, rainSnow, freezingRain, snow, flurries, sleet, haze, fog, thunder]

    /// Night-variant names (clear sky at night reads "Clear", not "Sunny").
    static func nightName(_ k: Kind) -> String {
        switch k.display {
        case 0x65: "Clear"
        case 0x66: "Partly Cloudy"
        default: k.name
        }
    }

    /// The weather-type table written into forecast.bin (day + night variants).
    public static var table: [WeatherType] {
        var t: [WeatherType] = []
        for k in all {
            t.append(WeatherType(code: k.display, displayCode: k.display, name: k.name))
            if k.hasNight { t.append(WeatherType(code: k.display | 0x8000, displayCode: k.display | 0x8000, name: nightName(k))) }
        }
        return t
    }

    /// WMO 4677 code (as returned by Open-Meteo) → channel kind.
    public static func kind(wmo: Int) -> Kind {
        switch wmo {
        case 0: sunny
        case 1: sunny                 // mainly clear
        case 2: partlyCloudy
        case 3: cloudy
        case 45, 48: fog
        case 51, 53, 55: showers      // drizzle
        case 56, 57, 66, 67: freezingRain
        case 61, 63, 65: rain
        case 71, 73, 75: snow
        case 77: flurries             // snow grains
        case 80: partlySunnyShowers
        case 81, 82: showers
        case 85: partlySunnyFlurries
        case 86: cloudySnow
        case 95, 96, 99: thunder
        default: cloudy
        }
    }

    /// Data code for a WMO code, using the night variant where one exists.
    public static func code(wmo: Int, night: Bool = false) -> UInt16 {
        let k = kind(wmo: wmo)
        return night && k.hasNight ? k.display | 0x8000 : k.display
    }

    /// UV index text table (WHO categories) — ids 0…12; days reference round(uv_index_max).
    public static var uvTable: [IndexText] {
        (0...12).map { i in
            let s: String
            switch i { case 0...2: s = "Low"; case 3...5: s = "Moderate"; case 6...7: s = "High"; case 8...10: s = "Very High"; default: s = "Extreme" }
            return IndexText(id: UInt8(i), text: s)
        }
    }

    /// Compass bucket used by the channel: 1 = NNE … 15 = NNW, 16 = N.
    public static func windDirection(degrees: Double?) -> UInt8 {
        guard let d = degrees, d.isFinite else { return 0xFF }
        let i = Int((d.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 22.5 + 0.5) % 16
        return i == 0 ? 16 : UInt8(i)
    }
}
