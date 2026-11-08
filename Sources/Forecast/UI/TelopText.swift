import Metal
import NW4R
import simd

/// nw4r::ut::TextWriter-style free text in SetOrtho2D screen space (y down), as the pages use for telops
/// (weather names, wind, weekday, city name). Draw flags follow TextWriter::SetDrawFlag:
/// bits 0-1 line alignment (0 left, 1 centre, 2 right), bits 4-5 horizontal origin, bits 8-9 vertical origin.
public final class TelopText {
    let ctx: SceneContext
    public init(ctx: SceneContext) { self.ctx = ctx }

    public struct Style {
        public var scale: SIMD2<Float> = SIMD2(1, 1)
        public var charSpace: Float = 0
        public var lineSpace: Float = 0
        public var flags: Int = 0
        public init(scale: SIMD2<Float> = SIMD2(1, 1), flags: Int = 0, charSpace: Float = 0, lineSpace: Float = 0) {
            self.scale = scale; self.flags = flags; self.charSpace = charSpace; self.lineSpace = lineSpace
        }
    }

    static func lines(_ s: String) -> [[UInt16]] { s.split(separator: "\n", omittingEmptySubsequences: false).map { Array($0.utf16) } }

    func lineWidth(_ l: [UInt16], _ f: ResFont, _ st: Style) -> Float {
        guard !l.isEmpty else { return 0 }
        return l.reduce(Float(0)) { $0 + Float(f.glyph($1).widths.charWidth) * st.scale.x + st.charSpace } - st.charSpace
    }

    /// TextWriter::CalcStringWidth
    public func width(_ s: String, font f: ResFont, style st: Style = Style()) -> Float { TelopText.lines(s).map { lineWidth($0, f, st) }.max() ?? 0 }
    /// TextWriter::CalcStringHeight
    public func height(_ s: String, font f: ResFont, style st: Style = Style()) -> Float {
        let n = Float(TelopText.lines(s).count)
        return n * Float(f.lineFeed) * st.scale.y + (n - 1) * st.lineSpace
    }

    /// TextWriter::Print at cursor `p`.
    /// `clipY` (screen y range) emulates the GXSetScissor band the telop ticker draws inside: glyph quads are cut
    /// against it with their texture coordinates adjusted.
    public func draw(_ s: String, font f: ResFont, at p: SIMD2<Float>, style st: Style = Style(), color: SIMD4<UInt8>, _ enc: MTLRenderCommandEncoder,
                     clipY: ClosedRange<Float>? = nil) {
        let ls = TelopText.lines(s)
        let widths = ls.map { lineWidth($0, f, st) }
        let bw = widths.max() ?? 0, bh = height(s, font: f, style: st)
        let hOrigin = (st.flags >> 4) & 3, vOrigin = (st.flags >> 8) & 3, align = st.flags & 3
        let x0 = p.x - (hOrigin == 1 ? bw / 2 : hOrigin == 2 ? bw : 0)
        let y0 = p.y - (vOrigin == 1 ? bh / 2 : vOrigin == 2 ? bh : 0)
        let lineH = Float(f.lineFeed) * st.scale.y + st.lineSpace
        var bySheet: [Int: [(SIMD4<Float>, SIMD4<Float>)]] = [:]
        for (i, l) in ls.enumerated() {
            var x = x0 + (align == 1 ? (bw - widths[i]) / 2 : align == 2 ? bw - widths[i] : 0)
            let y = y0 + Float(i) * lineH
            for c in l {
                let g = f.glyph(c)
                let gw = Float(g.widths.glyphWidth)
                let left = x + Float(g.widths.left) * st.scale.x
                // 1-texel pad each side (the sheet's cell gutter is blank): magnified + filtered glyphs keep their
                // anti-aliased edge instead of being cut flat at the glyph width.
                let pad: Float = 0.5
                let uv = SIMD4((Float(g.cellX) - pad) / Float(f.sheetWidth), Float(g.cellY) / Float(f.sheetHeight),
                               (Float(g.cellX) + gw + pad) / Float(f.sheetWidth), Float(g.cellY + f.cellHeight) / Float(f.sheetHeight))
                var r = SIMD4(left - pad * st.scale.x, y, left + (gw + pad) * st.scale.x, y + Float(f.cellHeight) * st.scale.y)
                var t = uv
                if let c = clipY {
                    if r.w <= c.lowerBound || r.y >= c.upperBound { x += Float(g.widths.charWidth) * st.scale.x + st.charSpace; continue }
                    let h = r.w - r.y, dv = t.w - t.y
                    if r.y < c.lowerBound { t.y += dv * (c.lowerBound - r.y) / h; r.y = c.lowerBound }
                    if r.w > c.upperBound { t.w -= dv * (r.w - c.upperBound) / h; r.w = c.upperBound }
                }
                bySheet[g.sheet, default: []].append((r, t))
                x += Float(g.widths.charWidth) * st.scale.x + st.charSpace
            }
        }
        let sheets = ctx.lyt.fontSheets(f)
        let intensity = f.sheetFormat == .i4 || f.sheetFormat == .i8
        for (sheet, quads) in bySheet where sheet < sheets.count {
            ctx.lyt.drawScreenQuads(sheets[sheet], quads, color: color, screenWidth: ctx.screenWidth, enc, intensityFont: intensity)
        }
    }

    /// fn_8001C89C pattern: fit `s` into (maxW, maxH) by shrinking the scale, then draw shadow (+1,+1) and text.
    public func drawFitted(_ s: String, font f: ResFont, at p: SIMD2<Float>, maxSize: SIMD2<Float>, scale: SIMD2<Float>, flags: Int,
                           color: SIMD4<UInt8>, shadow: SIMD4<UInt8>?, _ enc: MTLRenderCommandEncoder) {
        var st = Style(scale: scale, flags: flags)
        var sx = scale.x, sy = scale.y
        let w = width(s, font: f, style: st), h = height(s, font: f, style: st)
        if w > maxSize.x, w > 0 { sx = scale.x * maxSize.x / w }
        if h > maxSize.y, h > 0 { sy = scale.y * maxSize.y / h }
        let k = min(sx, sy)
        st.scale = SIMD2(k, k)
        if let shadow { draw(s, font: f, at: p + SIMD2(1, 1), style: st, color: shadow, enc) }
        draw(s, font: f, at: p, style: st, color: color, enc)
    }
}
