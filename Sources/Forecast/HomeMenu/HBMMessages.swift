import Foundation
import RVL

/// The HBM message file (the channel's home_nosave.csv.LZ in content 9): UTF-16 text containing quoted strings,
/// 4 rows × 7 languages (JP, EN, DE, FR, ES, IT, NL), row-major. The library copies each string up to its closing quote.
public struct HBMMessages {
    public enum Language: Int { case japanese = 0, english, german, french, spanish, italian, dutch }
    let strings: [String]

    init(_ bytes: [UInt8]) {
        var units: [UInt16] = []
        var i = 0
        let bigEndian = !(bytes.count >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE)
        while i + 1 < bytes.count {
            units.append(bigEndian ? UInt16(bytes[i]) << 8 | UInt16(bytes[i + 1]) : UInt16(bytes[i + 1]) << 8 | UInt16(bytes[i]))
            i += 2
        }
        var out: [String] = [], cur: [UInt16] = [], inQuote = false
        for u in units where u != 0xFEFF {
            if u == 0x22 { // '"'
                if inQuote { out.append(String(utf16CodeUnits: cur, count: cur.count)); cur = [] }
                inQuote.toggle()
            } else if inQuote, u != 0x0D {
                cur.append(u)
            }
        }
        strings = out
    }

    static func load(_ assets: Assets) -> HBMMessages? {
        guard let d = try? assets.archive(.weather).find("home_nosave.csv.LZ"), let raw = try? CX.uncompressIfNeeded(d) else { return nil }
        return HBMMessages(raw)
    }

    func message(row: Int, language: Language) -> String {
        let i = row * 7 + language.rawValue
        return i < strings.count ? strings[i] : ""
    }
}
