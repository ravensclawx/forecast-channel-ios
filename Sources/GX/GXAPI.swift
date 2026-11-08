/// Revolution SDK GX API (the subset NW4R uses), encoded into `GXState` registers exactly as the SDK
/// packs them for the command processor. This lets ported library code (nw4r::lyt::Material::SetupGX,
/// nw4r::ut::CharWriter::SetupGX, ...) call the same functions with the same arguments as the original.
public enum GXTevColorArg: UInt32 { case cprev, aprev, c0, a0, c1, a1, c2, a2, texc, texa, rasc, rasa, one, half, konst, zero }
public enum GXTevAlphaArg: UInt32 { case aprev, a0, a1, a2, texa, rasa, konst, zero }

public extension GXState {
    static let texCoordNull: UInt8 = 0xFF, texMapNull: UInt8 = 0xFF, colorNull: UInt8 = 0xFF
    // GXChannelID
    static let color0 = 0, color1 = 1, alpha0 = 2, alpha1 = 3, color0a0 = 4, color1a1 = 5

    /// GXSetNumTevStages
    mutating func setNumTevStages(_ n: Int) { numTevStages = n }
    /// GXSetNumTexGens
    mutating func setNumTexGens(_ n: Int) { numTexGens = n }
    /// GXSetNumChans
    mutating func setNumChans(_ n: Int) { numChans = n }
    /// GXSetNumIndStages
    mutating func setNumIndStages(_ n: Int) { numIndStages = n }

    /// GXSetTevOrder(stage, coord, map, color)
    mutating func setTevOrder(_ stage: Int, coord: UInt8, map: UInt32, color: UInt8) {
        // map may carry GX_TEX_DISABLE (0x100) to keep the coordinate but skip the lookup.
        let enable: UInt32 = (map & 0xFF) != 0xFF && map & 0x100 == 0 ? 1 : 0
        let m = (map & 0xFF) == 0xFF ? 7 : map & 7
        let c = coord == 0xFF ? 7 : UInt32(coord & 7)
        // __GXSetTevOrder channel → RAS1_TREF color id
        let chan: UInt32
        switch color {
        case 0, 2, 4: chan = 0
        case 1, 3, 5: chan = 1
        case 6: chan = 5
        case 7: chan = 6
        default: chan = 7
        }
        let field = m | c << 3 | enable << 6 | chan << 7
        let reg = 0x28 + stage / 2, shift: UInt32 = stage & 1 == 1 ? 12 : 0
        bp[reg] = (bp[reg] & ~(0xFFF << shift)) | field << shift
    }

    /// GXSetTevColorIn(stage, a, b, c, d)
    mutating func setTevColorIn(_ stage: Int, _ a: GXTevColorArg, _ b: GXTevColorArg, _ c: GXTevColorArg, _ d: GXTevColorArg) {
        let r = 0xC0 + stage * 2
        bp[r] = (bp[r] & ~0xFFFF) | d.rawValue | c.rawValue << 4 | b.rawValue << 8 | a.rawValue << 12
    }
    /// GXSetTevAlphaIn(stage, a, b, c, d)
    mutating func setTevAlphaIn(_ stage: Int, _ a: GXTevAlphaArg, _ b: GXTevAlphaArg, _ c: GXTevAlphaArg, _ d: GXTevAlphaArg) {
        let r = 0xC1 + stage * 2
        bp[r] = (bp[r] & ~0xFFF0) | d.rawValue << 4 | c.rawValue << 7 | b.rawValue << 10 | a.rawValue << 13
    }
    /// GXSetTevColorOp / GXSetTevAlphaOp(stage, op, bias, scale, clamp, out). op 0 add, 1 sub, >=8 compare.
    mutating func setTevColorOp(_ stage: Int, op: UInt32, bias: UInt32, scale: UInt32, clamp: Bool, out: UInt32) {
        bp[0xC0 + stage * 2] = (bp[0xC0 + stage * 2] & 0xFFFF) | GXState.encodeOp(op, bias, scale, clamp, out)
    }
    mutating func setTevAlphaOp(_ stage: Int, op: UInt32, bias: UInt32, scale: UInt32, clamp: Bool, out: UInt32) {
        bp[0xC1 + stage * 2] = (bp[0xC1 + stage * 2] & 0xFFFF) | GXState.encodeOp(op, bias, scale, clamp, out)
    }
    private static func encodeOp(_ op: UInt32, _ bias: UInt32, _ scale: UInt32, _ clamp: Bool, _ out: UInt32) -> UInt32 {
        var v: UInt32 = (clamp ? 1 : 0) << 19 | (out & 3) << 22
        if op <= 1 { v |= (op & 1) << 18 | (bias & 3) << 16 | (scale & 3) << 20 }
        else { v |= (op & 1) << 18 | 3 << 16 | ((op >> 1) & 3) << 20 }  // compare modes
        return v
    }
    /// GXSetTevOp(stage, mode): 0 MODULATE, 1 DECAL, 2 BLEND, 3 REPLACE, 4 PASSCLR
    mutating func setTevOp(_ stage: Int, _ mode: Int) {
        let carg: GXTevColorArg = stage == 0 ? .rasc : .cprev
        let aarg: GXTevAlphaArg = stage == 0 ? .rasa : .aprev
        switch mode {
        case 0: setTevColorIn(stage, .zero, .texc, carg, .zero); setTevAlphaIn(stage, .zero, .texa, aarg, .zero)
        case 1: setTevColorIn(stage, carg, .texc, .texa, .zero); setTevAlphaIn(stage, .zero, .zero, .zero, aarg)
        case 2: setTevColorIn(stage, carg, .one, .texc, .zero); setTevAlphaIn(stage, .zero, .texa, aarg, .zero)
        case 3: setTevColorIn(stage, .zero, .zero, .zero, .texc); setTevAlphaIn(stage, .zero, .zero, .zero, .texa)
        default: setTevColorIn(stage, .zero, .zero, .zero, carg); setTevAlphaIn(stage, .zero, .zero, .zero, aarg)
        }
        setTevColorOp(stage, op: 0, bias: 0, scale: 0, clamp: true, out: 0)
        setTevAlphaOp(stage, op: 0, bias: 0, scale: 0, clamp: true, out: 0)
    }
    /// GXSetTevKColorSel / GXSetTevKAlphaSel
    mutating func setTevKColorSel(_ stage: Int, _ sel: UInt32) {
        let r = 0xF6 + stage / 2, sh: UInt32 = stage & 1 == 1 ? 14 : 4
        bp[r] = (bp[r] & ~(0x1F << sh)) | (sel & 0x1F) << sh
    }
    mutating func setTevKAlphaSel(_ stage: Int, _ sel: UInt32) {
        let r = 0xF6 + stage / 2, sh: UInt32 = stage & 1 == 1 ? 19 : 9
        bp[r] = (bp[r] & ~(0x1F << sh)) | (sel & 0x1F) << sh
    }
    /// GXSetTevSwapMode(stage, rasSel, texSel)
    mutating func setTevSwapMode(_ stage: Int, ras: UInt32, tex: UInt32) {
        let r = 0xC1 + stage * 2
        bp[r] = (bp[r] & ~0xF) | (ras & 3) | (tex & 3) << 2
    }
    /// GXSetTevSwapModeTable(table, r, g, b, a)
    mutating func setTevSwapModeTable(_ t: Int, _ r: UInt32, _ g: UInt32, _ b: UInt32, _ a: UInt32) {
        let rg = 0xF6 + t * 2, ba = rg + 1
        bp[rg] = (bp[rg] & ~0xF) | r | g << 2
        bp[ba] = (bp[ba] & ~0xF) | b | a << 2
    }
    /// GXSetTevDirect(stage)
    mutating func setTevDirect(_ stage: Int) { bp[0x10 + stage] = 0 }

    /// GXSetTevColor (u8) / GXSetTevColorS10: reg 0 PREV, 1..3 REG0..REG2
    mutating func setTevColor(_ reg: Int, _ c: SIMD4<Int32>) { tevRegs[reg] = c }
    /// GXSetTevKColor
    mutating func setTevKColor(_ id: Int, _ c: SIMD4<Int32>) { konst[id] = c }

    /// GXSetAlphaCompare(comp0, ref0, op, comp1, ref1)
    mutating func setAlphaCompare(_ comp0: UInt32, _ ref0: UInt32, _ op: UInt32, _ comp1: UInt32, _ ref1: UInt32) {
        bp[0xF3] = (ref0 & 0xFF) | (ref1 & 0xFF) << 8 | (comp0 & 7) << 16 | (comp1 & 7) << 19 | (op & 3) << 22
    }
    /// GXSetBlendMode(type, src, dst, logicOp). type 0 none, 1 blend, 2 logic, 3 subtract.
    mutating func setBlendMode(_ type: UInt32, _ src: UInt32, _ dst: UInt32, _ logic: UInt32) {
        let enable: UInt32 = type == 1 || type == 3 ? 1 : 0
        bp[0x41] = (bp[0x41] & 0x1C) | enable | (type == 2 ? 2 : 0) | (dst & 7) << 5 | (src & 7) << 8
            | (type == 3 ? 1 : 0) << 11 | (logic & 0xF) << 12
    }
    /// GXSetZMode(enable, func, update)
    mutating func setZMode(_ enable: Bool, _ fn: UInt32, _ update: Bool) {
        bp[0x40] = (enable ? 1 : 0) | (fn & 7) << 1 | (update ? 1 : 0) << 4
    }

    /// GXSetChanCtrl(chan, enable, ambSrc, matSrc, lightMask, diffFn, attnFn)
    mutating func setChanCtrl(_ chan: Int, enable: Bool, ambSrc: UInt32, matSrc: UInt32, lightMask: UInt32 = 0, diffFn: UInt32 = 0, attnFn: UInt32 = 2) {
        var v = (matSrc & 1) | (enable ? 2 : 0) | (lightMask & 0xF) << 2 | (ambSrc & 1) << 6
        v |= (attnFn == 0 ? 0 : diffFn & 3) << 7 | (attnFn != 2 ? 1 : 0) << 9 | (attnFn != 0 ? 1 : 0) << 10 | ((lightMask >> 4) & 0xF) << 11
        switch chan {
        case 0: chanColorCtrl[0] = v
        case 1: chanColorCtrl[1] = v
        case 2: chanAlphaCtrl[0] = v
        case 3: chanAlphaCtrl[1] = v
        case 4: chanColorCtrl[0] = v; chanAlphaCtrl[0] = v
        default: chanColorCtrl[1] = v; chanAlphaCtrl[1] = v
        }
    }
    /// GXSetChanMatColor / GXSetChanAmbColor (RGBA8)
    mutating func setChanMatColor(_ chan: Int, _ rgba: UInt32) { chanMatColor[chan == 1 || chan == 5 ? 1 : 0] = rgba }
    mutating func setChanAmbColor(_ chan: Int, _ rgba: UInt32) { chanAmbColor[chan == 1 || chan == 5 ? 1 : 0] = rgba }

    /// GXSetTexCoordGen2(dst, type, src, mtx, normalize, postMtx). Matrices themselves are uniforms.
    /// type: 0 MTX3x4, 1 MTX2x4, 2..9 BUMP, 10 SRTG. src: 0 POS, 1 NRM, 2 BINRM, 3 TANGENT, 4..11 TEX0..7, ...
    mutating func setTexCoordGen(_ i: Int, type: UInt32, src: UInt32, normalize: Bool = false, postMtx: UInt32 = 125) {
        let row: UInt32
        switch src {
        case 0: row = 0
        case 1: row = 1
        case 2: row = 4
        case 3: row = 3
        case 4...11: row = src + 1
        case 19, 20: row = 2
        default: row = 5
        }
        let tgType: UInt32 = type <= 1 ? 0 : (type == 10 ? 2 : 1)
        texMtxInfo[i] = (type == 0 ? 2 : 0) | (src <= 1 ? 4 : 0) | tgType << 4 | row << 7
        postMtxInfo[i] = ((postMtx &- 64) & 0x3F) | (normalize ? 1 << 8 : 0)
    }
}
