import GX
import RVL

/// nw4r::ut::ResFont — RFNT bitmap font (FINF / TGLP / CWDH / CMAP).
public final class ResFont {
    public struct CharWidths: Sendable { public let left: Int8; public let glyphWidth: UInt8; public let charWidth: Int8 }
    public struct Glyph {
        public let sheet: Int
        public let widths: CharWidths
        public let cellX: Int, cellY: Int   // pixel origin of the cell in its sheet
    }

    public let fontType: UInt8, encoding: UInt8
    public let lineFeed: Int, height: Int, width: Int, ascent: Int
    public let defaultWidths: CharWidths
    public let alterCharIndex: Int
    public let cellWidth: Int, cellHeight: Int, baselinePos: Int, maxCharWidth: Int
    public let sheetFormat: GXTexFmt, sheetRow: Int, sheetLine: Int, sheetWidth: Int, sheetHeight: Int
    /// Decoded sheets (RGBA8), uploaded lazily by the renderer.
    public let sheets: [[UInt8]]

    private var widthTable: [(begin: Int, end: Int, entries: [CharWidths])] = []
    private var cmap: [UInt16: Int] = [:]
    private var directRanges: [(begin: UInt16, end: UInt16, offset: Int)] = []

    public init(_ bytes: [UInt8]) throws {
        let r = BEReader(bytes)
        guard r.magic(0) == "RFNT" || r.magic(0) == "RFNA" else { throw RVLError.badMagic(r.magic(0), expected: "RFNT") }
        // RFNT starts with FINF; RFNA (nw4r::ut::ArchiveFont) has a GLGR block first — walk the blocks.
        var finf = Int(r.u16(0xC))
        while finf + 8 <= bytes.count && r.magic(finf) != "FINF" { finf += Int(r.u32(finf + 4)) }
        fontType = r.u8(finf + 8)
        lineFeed = Int(r.s8(finf + 9))
        alterCharIndex = Int(r.u16(finf + 0xA))
        defaultWidths = CharWidths(left: r.s8(finf + 0xC), glyphWidth: r.u8(finf + 0xD), charWidth: r.s8(finf + 0xE))
        encoding = r.u8(finf + 0xF)
        let tglp = Int(r.u32(finf + 0x10)) - 8, cwdh = Int(r.u32(finf + 0x14)) - 8, cmapOff = Int(r.u32(finf + 0x18)) - 8
        height = Int(r.u8(finf + 0x1C)); width = Int(r.u8(finf + 0x1D)); ascent = Int(r.u8(finf + 0x1E))

        cellWidth = Int(r.u8(tglp + 8)); cellHeight = Int(r.u8(tglp + 9))
        baselinePos = Int(r.s8(tglp + 10)); maxCharWidth = Int(r.u8(tglp + 11))
        let sheetSize = Int(r.u32(tglp + 12)), sheetNum = Int(r.u16(tglp + 16))
        sheetFormat = GXTexFmt(rawValue: UInt32(r.u16(tglp + 18) & 0x7FFF)) ?? .i4
        let compressed = r.u16(tglp + 18) & 0x8000 != 0
        sheetRow = Int(r.u16(tglp + 20)); sheetLine = Int(r.u16(tglp + 22))
        sheetWidth = Int(r.u16(tglp + 24)); sheetHeight = Int(r.u16(tglp + 26))
        let image = Int(r.u32(tglp + 28))
        let sw = Int(r.u16(tglp + 24)), sh = Int(r.u16(tglp + 26))
        let fmt = GXTexFmt(rawValue: UInt32(r.u16(tglp + 18) & 0x7FFF)) ?? .i4
        if compressed {
            // ArchiveFont: each sheet = u32 compressed size + CX stream (Huffman 0x2x / LZ 0x1x).
            var out: [[UInt8]] = [], p = image
            for _ in 0..<sheetNum {
                let n = Int(r.u32(p)); let stream = Array(bytes[(p + 4)..<min(p + 4 + n, bytes.count)])
                let raw: [UInt8]
                switch stream.first ?? 0 {
                case 0x20...0x2F: raw = (try? CXHuffman.uncompress(stream)) ?? []
                case 0x10, 0x11: raw = (try? CX.uncompressLZ(stream)) ?? []
                default: raw = stream
                }
                out.append(GXTextureDecoder.decode(raw.count >= sheetSize ? raw : raw + [UInt8](repeating: 0, count: sheetSize - raw.count),
                                                   width: sw, height: sh, format: fmt))
                p += 4 + n
            }
            sheets = out
        } else {
            sheets = (0..<sheetNum).map { GXTextureDecoder.decode(bytes, offset: image + $0 * sheetSize, width: sw, height: sh, format: fmt) }
        }

        var w = cwdh
        while w > 0 {
            let begin = Int(r.u16(w + 8)), end = Int(r.u16(w + 10)), next = Int(r.u32(w + 12))
            let entries = (0...max(end - begin, 0)).map { i in
                CharWidths(left: r.s8(w + 16 + i * 3), glyphWidth: r.u8(w + 17 + i * 3), charWidth: r.s8(w + 18 + i * 3))
            }
            widthTable.append((begin, end, entries))
            w = next == 0 ? 0 : next - 8
        }
        var c = cmapOff
        while c > 0 {
            let begin = r.u16(c + 8), end = r.u16(c + 10), method = r.u16(c + 12), next = Int(r.u32(c + 16))
            let data = c + 20
            switch method {
            case 0: directRanges.append((begin, end, Int(r.u16(data))))
            case 1:
                for code in begin...end { let idx = r.u16(data + Int(code - begin) * 2); if idx != 0xFFFF { cmap[code] = Int(idx) } }
            default:
                let n = Int(r.u16(data))
                for i in 0..<n { cmap[r.u16(data + 2 + i * 4)] = Int(r.u16(data + 4 + i * 4)) }
            }
            c = next == 0 ? 0 : next - 8
        }
    }

    /// ResFontBase::GetGlyphIndex (falls back to the alternate character).
    public func glyphIndex(_ code: UInt16) -> Int {
        if let i = cmap[code] { return i }
        for d in directRanges where code >= d.begin && code <= d.end { return Int(code - d.begin) + d.offset }
        return alterCharIndex
    }

    public func widths(index: Int) -> CharWidths {
        for t in widthTable where index >= t.begin && index <= t.end { return t.entries[index - t.begin] }
        return defaultWidths
    }

    /// ResFontBase::GetGlyphFromIndex — cells are laid out with a 1-pixel gutter.
    public func glyph(_ code: UInt16) -> Glyph {
        let index = glyphIndex(code)
        let perSheet = sheetRow * sheetLine
        let sheet = index / perSheet, cell = index % perSheet
        return Glyph(sheet: sheet, widths: widths(index: index),
                     cellX: (cell % sheetRow) * (cellWidth + 1), cellY: (cell / sheetRow) * (cellHeight + 1))
    }

    public func hasGlyph(_ code: UInt16) -> Bool { glyphIndex(code) != alterCharIndex || cmap[code] != nil }
}
