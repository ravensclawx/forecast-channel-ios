import GX
import simd

/// nw4r::ut::CharWriter / TextWriter — GX setup (port of fn_800D3C7C / fn_800D5180) and text layout.
public enum CharWriter {
    /// CharWriter::SetupGX. `minColor`/`maxColor` = color mapping (black / white); default (0,0,0,0)/(255,255,255,255).
    public static func setupGX(sheetFormat: GXTexFmt, minColor: SIMD4<Int32>, maxColor: SIMD4<Int32>) -> GXState {
        var gx = GXState()
        gx.setTevSwapModeTable(0, 0, 1, 2, 3)
        gx.setZMode(false, 7, false)
        gx.setNumChans(1)
        gx.setChanCtrl(GXState.color0a0, enable: false, ambSrc: 0, matSrc: 1)
        gx.setChanCtrl(GXState.color1a1, enable: false, ambSrc: 0, matSrc: 0)
        gx.setNumTexGens(1)
        gx.setTexCoordGen(0, type: 1, src: 4)
        gx.setNumIndStages(0)
        gx.setBlendMode(1, 4, 5, 0xF)
        gx.setAlphaCompare(7, 0, 0, 7, 0)
        let isDefaultMapping = minColor == SIMD4(0, 0, 0, 0) && maxColor == SIMD4(255, 255, 255, 255)
        if !isDefaultMapping {
            // fn_800D5180 SetupGXWithColorMapping
            gx.setNumTevStages(2)
            gx.setTevDirect(0); gx.setTevDirect(1)
            gx.setTevSwapMode(0, ras: 0, tex: 0); gx.setTevSwapMode(1, ras: 0, tex: 0)
            gx.setTevOrder(0, coord: 0, map: 0, color: 0xFF)
            gx.setTevColor(1, minColor); gx.setTevColor(2, maxColor)
            gx.setTevColorIn(0, .c0, .c1, .texc, .zero)
            gx.setTevAlphaIn(0, .a0, .a1, .texa, .zero)
            gx.setTevColorOp(0, op: 0, bias: 0, scale: 0, clamp: true, out: 0)
            gx.setTevAlphaOp(0, op: 0, bias: 0, scale: 0, clamp: true, out: 0)
            gx.setTevOrder(1, coord: 0xFF, map: 0xFF, color: 4)
            gx.setTevColorIn(1, .zero, .cprev, .rasc, .zero)
            gx.setTevAlphaIn(1, .zero, .aprev, .rasa, .zero)
            gx.setTevColorOp(1, op: 0, bias: 0, scale: 0, clamp: true, out: 0)
            gx.setTevAlphaOp(1, op: 0, bias: 0, scale: 0, clamp: true, out: 0)
            return gx
        }
        gx.setNumTevStages(1)
        gx.setTevDirect(0)
        gx.setTevSwapMode(0, ras: 0, tex: 0)
        gx.setTevOrder(0, coord: 0, map: 0, color: 4)
        switch sheetFormat {
        case .i4, .i8:
            // color = rasterized; alpha = texture intensity × rasterized alpha
            gx.setTevColorIn(0, .zero, .zero, .zero, .rasc)
            gx.setTevAlphaIn(0, .zero, .texa, .rasa, .zero)
            gx.setTevColorOp(0, op: 0, bias: 0, scale: 0, clamp: true, out: 0)
            gx.setTevAlphaOp(0, op: 0, bias: 0, scale: 0, clamp: true, out: 0)
        default:
            gx.setTevOp(0, 0) // GX_MODULATE
        }
        return gx
    }

    public struct Quad { public var rect: SIMD4<Float>; public var uv: SIMD4<Float>; public var sheet: Int; public var top: SIMD4<UInt8>; public var bottom: SIMD4<UInt8> }

    /// TextBox text layout: lines measured with the font's char widths and the box's spacing,
    /// block placed by textPosition (H = %3, V = /3), lines aligned by textAlignment (0 = follow H).
    /// Coordinates are pane-local (y up), relative to the pane rectangle's top-left.
    public static func layout(text: [UInt16], font: ResFont, fontSize: SIMD2<Float>, charSpace: Float, lineSpace: Float,
                              boxSize: SIMD2<Float>, textPosition: UInt8, textAlignment: UInt8,
                              top: SIMD4<UInt8>, bottom: SIMD4<UInt8>) -> [Quad] {
        let sx = fontSize.x / Float(max(font.width, 1)), sy = fontSize.y / Float(max(font.height, 1))
        let lineHeight = Float(font.lineFeed) * sy + lineSpace
        var lines: [[UInt16]] = [[]]
        for c in text { if c == 0x0A { lines.append([]) } else { lines[lines.count - 1].append(c) } }
        func lineWidth(_ l: [UInt16]) -> Float {
            guard !l.isEmpty else { return 0 }
            return l.reduce(Float(0)) { $0 + Float(font.glyph($1).widths.charWidth) * sx + charSpace } - charSpace
        }
        let widths = lines.map(lineWidth)
        let blockW = widths.max() ?? 0
        let blockH = Float(lines.count) * lineHeight - lineSpace
        let hPos = Int(textPosition % 3), vPos = Int(textPosition / 3)
        let blockX: Float = hPos == 0 ? 0 : (hPos == 1 ? (boxSize.x - blockW) / 2 : boxSize.x - blockW)
        let blockY: Float = vPos == 0 ? 0 : (vPos == 1 ? (boxSize.y - blockH) / 2 : boxSize.y - blockH)
        let align = textAlignment == 0 ? hPos : Int(textAlignment) - 1
        var quads: [Quad] = []
        for (i, l) in lines.enumerated() {
            var x = blockX + (align == 0 ? 0 : (align == 1 ? (blockW - widths[i]) / 2 : blockW - widths[i]))
            let y = blockY + Float(i) * lineHeight
            for c in l {
                let g = font.glyph(c)
                let gw = Float(g.widths.glyphWidth)
                let left = x + Float(g.widths.left) * sx
                let h = Float(font.cellHeight) * sy
                // 1-texel pad each side (blank cell gutter) so magnified, filtered glyph edges aren't cut flat.
                let pad: Float = 0.5
                quads.append(Quad(rect: SIMD4(left - pad * sx, -y, left + (gw + pad) * sx, -(y + h)),
                                  uv: SIMD4((Float(g.cellX) - pad) / Float(font.sheetWidth), Float(g.cellY) / Float(font.sheetHeight),
                                            (Float(g.cellX) + gw + pad) / Float(font.sheetWidth), Float(g.cellY + font.cellHeight) / Float(font.sheetHeight)),
                                  sheet: g.sheet, top: top, bottom: bottom))
                x += Float(g.widths.charWidth) * sx + charSpace
            }
        }
        return quads
    }
}
