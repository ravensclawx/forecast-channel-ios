import Foundation
import RVL

/// The channel's electronic manual ("Operations Guide") resources, kept in memory — nothing is extracted to disk.
///
///   - content 10 (0000000a): U8 holding `html-us.arc` (lbl_8019C1EC; JP/EU builds use html-jp/html-eu.arc), itself a
///     U8 with /html/... (frameset start pages, ukv/fra/esp pages, img/, channel.css).
///   - content 3 (00000003): WiiNTLG-Regular.ttc — the font the original registers with WWWSurfaceAddFont. The pages
///     ask for "Wii NTLG PGothic Regular" (face 1 of the collection); it is served as a standalone TrueType file.
///
/// Start URLs (CScene_ctor 0x8003B4D4: US table lbl_8019C1D0+0xB4 indexed by language):
///   EN arc:/html/startup.html · FR arc:/html/startup_fra.html · ES arc:/html/startup_esp.html · others: none
///   (no URL → CContentArc leaves the manual disabled).
public final class ManualArchive {
    public let html: ARCArchive
    public private(set) lazy var pGothic: Data? = ManualArchive.extractFace(from: fontCollection, named: "WiiNTLGPGothic-Regular")
    private let fontCollection: [UInt8]?

    public init(assets: Assets) throws {
        let outer = try assets.archive(.html)
        guard let inner = outer.find("html-us.arc") else { throw RVLError.missing("html-us.arc") }
        html = try ARCArchive(CX.uncompressIfNeeded(inner))
        fontCollection = (try? assets.archive(.operaRes))?.find("WiiNTLG-Regular.ttc")
    }

    /// Start page for a channel language (CScene_ctor table; nil = no manual for that language).
    public static func startPath(language: Int) -> String? {
        switch language {
        case 1: return "/html/startup.html"
        case 3: return "/html/startup_fra.html"
        case 4: return "/html/startup_esp.html"
        default: return nil
        }
    }

    /// A file by archive path ("/html/img/under_bar.png").
    public func file(_ path: String) -> [UInt8]? { html.file(path) }

    public static func mimeType(_ path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "html", "htm": return "text/html"
        case "css": return "text/css"
        case "png": return "image/png"
        case "gif": return "image/gif"
        case "jpg", "jpeg": return "image/jpeg"
        case "js": return "application/javascript"
        case "ttf": return "font/ttf"
        default: return "application/octet-stream"
        }
    }

    /// Pull one face out of a TrueType collection into a standalone sfnt (table directory + tables, offsets rewritten).
    static func extractFace(from ttc: [UInt8]?, named postScriptName: String) -> Data? {
        guard let d = ttc, d.count > 12, d[0..<4].elementsEqual("ttcf".utf8) else { return nil }
        func u16(_ o: Int) -> Int { Int(d[o]) << 8 | Int(d[o + 1]) }
        func u32(_ o: Int) -> Int { Int(d[o]) << 24 | Int(d[o + 1]) << 16 | Int(d[o + 2]) << 8 | Int(d[o + 3]) }
        let n = u32(8)
        for i in 0..<n {
            let o = u32(12 + 4 * i)
            let numTables = u16(o + 4)
            var tables: [(tag: [UInt8], check: Int, off: Int, len: Int)] = []
            for t in 0..<numTables {
                let e = o + 12 + 16 * t
                tables.append((Array(d[e..<e + 4]), u32(e + 4), u32(e + 8), u32(e + 12)))
            }
            // name table, nameID 6 (PostScript name), Windows platform (UTF-16BE)
            guard let name = tables.first(where: { $0.tag.elementsEqual("name".utf8) }) else { continue }
            let count = u16(name.off + 2), strOff = name.off + u16(name.off + 4)
            var ps: String?
            for r in 0..<count {
                let rec = name.off + 6 + 12 * r
                guard u16(rec) == 3, u16(rec + 6) == 6 else { continue }
                let len = u16(rec + 8), off = u16(rec + 10)
                ps = String(bytes: d[(strOff + off)..<(strOff + off + len)], encoding: .utf16BigEndian)
                break
            }
            guard ps == postScriptName else { continue }
            var out = [UInt8](d[o..<(o + 12)])
            var dir = [UInt8](), body = [UInt8]()
            var cursor = 12 + 16 * numTables
            func be32(_ v: Int) -> [UInt8] { [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
            for t in tables {
                dir += t.tag + be32(t.check) + be32(cursor) + be32(t.len)
                body += d[t.off..<(t.off + t.len)]
                let pad = (4 - t.len % 4) % 4
                body += [UInt8](repeating: 0, count: pad)
                cursor += t.len + pad
            }
            out += dir + body
            return Data(out)
        }
        return nil
    }
}
