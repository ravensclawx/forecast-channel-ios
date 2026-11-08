/// Generates Metal Shading Language that reproduces GX's fixed-function pipeline for a given `GXState`.
///
/// The pixel side is a line-by-line port of Dolphin's PixelShaderGen integer TEV emulation
/// (lerp with c+(c>>7), rounding bias, s24 texcoords, indirect matrices, swap tables, konst
/// selectors, alpha test), so results match console output bit-for-bit where Dolphin's do.
/// The vertex side ports VertexShaderGen's XF texgen path (pre-matrix, normalize, dual-tex post-matrix).
///
/// Uniform layouts (must match `GXUniforms` in the Metal backend):
///   VS buffer(1): float4x4 proj; float4 posMtx[3]; float4 nrmMtx[3]; float4 preMtx[24]; float4 postMtx[24];
///                 float4 matColor[2]; float4 ambColor[2];
///   FS buffer(0): int4 konst[4]; int4 tevRegs[4]; int4 texDims[8]; int4 coordDims[8];
///                 int4 indMtx[6]; int4 indScale[2]; int4 alphaRef;
public enum GXShaderGen {
    public static let vertexStride = 104 // pos3 nrm3 clr4 tex 8x2  (floats) = 26 * 4

    public static func generate(_ s: GXState) -> String {
        var o = header
        o += vertexShader(s)
        o += fragmentShader(s)
        return o
    }

    static let header = """
    #include <metal_stdlib>
    using namespace metal;

    struct VIn {
        float3 pos [[attribute(0)]];
        float3 nrm [[attribute(1)]];
        float4 clr0 [[attribute(2)]];
        float2 tex0 [[attribute(3)]]; float2 tex1 [[attribute(4)]]; float2 tex2 [[attribute(5)]]; float2 tex3 [[attribute(6)]];
        float2 tex4 [[attribute(7)]]; float2 tex5 [[attribute(8)]]; float2 tex6 [[attribute(9)]]; float2 tex7 [[attribute(10)]];
    };
    struct VUniforms {
        float4x4 proj; float4 posMtx[3]; float4 nrmMtx[3]; float4 preMtx[24]; float4 postMtx[24];
        float4 matColor[2]; float4 ambColor[2];
    };
    struct FUniforms {
        int4 konst[4]; int4 tevRegs[4]; int4 texDims[8]; int4 coordDims[8];
        int4 indMtx[6]; int4 indScale[2]; int4 alphaRef;
    };
    struct VOut {
        float4 position [[position]];
        float4 col0; float4 col1;
        float3 tex0; float3 tex1; float3 tex2; float3 tex3; float3 tex4; float3 tex5; float3 tex6; float3 tex7;
    };
    static inline int idot(int3 a, int3 b) { return a.x*b.x + a.y*b.y + a.z*b.z; }
    static inline int iround(float x) { return int(rint(x)); }
    static inline int4 iround(float4 x) { return int4(rint(x)); }

    """

    // MARK: Vertex

    static func vertexShader(_ s: GXState) -> String {
        var o = """
        vertex VOut gx_vs(VIn v [[stage_in]], constant VUniforms& u [[buffer(1)]]) {
            VOut out;
            float4 p = float4(v.pos, 1.0);
            float3 vp = float3(dot(u.posMtx[0], p), dot(u.posMtx[1], p), dot(u.posMtx[2], p));
            out.position = u.proj * float4(vp, 1.0);
            // GX clip-space z is [-w, 0]-ish via GXSetProjection; the backend supplies a Metal-ready proj.
            float3 n = normalize(float3(dot(u.nrmMtx[0].xyz, v.nrm), dot(u.nrmMtx[1].xyz, v.nrm), dot(u.nrmMtx[2].xyz, v.nrm)));
            (void)n;

        """
        // Color channels (unlit path + ambient when lighting enabled; light objects are supplied by g3d later).
        for c in 0..<2 {
            let cc = s.chanColorCtrl[c], ac = s.chanAlphaCtrl[c]
            let mat = "(\(cc & 1 == 1 ? "v.clr0" : "u.matColor[\(c)]"))"
            let lit = (cc >> 1) & 1 == 1
            let amb = "(\((cc >> 6) & 1 == 1 ? "v.clr0" : "u.ambColor[\(c)]"))"
            let rgb = lit ? "\(mat).rgb * saturate(\(amb).rgb)" : "\(mat).rgb"
            let amat = "(\(ac & 1 == 1 ? "v.clr0" : "u.matColor[\(c)]"))"
            let aamb = "(\((ac >> 6) & 1 == 1 ? "v.clr0" : "u.ambColor[\(c)]"))"
            let a = (ac >> 1) & 1 == 1 ? "\(amat).a * saturate(\(aamb).a)" : "\(amat).a"
            o += "    out.col\(c) = float4(\(rgb), \(a));\n"
        }
        for i in 0..<8 {
            guard i < s.numTexGens else { o += "    out.tex\(i) = float3(0);\n"; continue }
            let g = s.texGen(i)
            o += "    {\n        float4 coord = float4(0.0, 0.0, 1.0, 1.0);\n"
            switch g.sourceRow {
            case 0: o += "        coord.xyz = v.pos;\n"
            case 1: o += "        coord.xyz = v.nrm;\n"
            case 2: o += "        coord = v.clr0;\n"
            case 5...12: o += "        coord.xy = v.tex\(g.sourceRow - 5);\n"
            default: o += "        // unsupported source row \(g.sourceRow)\n"
            }
            if !g.inputABC1 { o += "        coord.z = 1.0;\n" }
            switch g.type {
            case 0:
                let m = i * 3
                if g.projectionSTQ {
                    o += "        float3 r = float3(dot(coord, u.preMtx[\(m)]), dot(coord, u.preMtx[\(m + 1)]), dot(coord, u.preMtx[\(m + 2)]));\n"
                } else {
                    o += "        float3 r = float3(dot(coord, u.preMtx[\(m)]), dot(coord, u.preMtx[\(m + 1)]), 1.0);\n"
                }
                if g.normalize { o += "        r = normalize(r);\n" }
                o += """
                        float4 P0 = u.postMtx[\(m)], P1 = u.postMtx[\(m + 1)], P2 = u.postMtx[\(m + 2)];
                        r = float3(dot(P0.xyz, r) + P0.w, dot(P1.xyz, r) + P1.w, dot(P2.xyz, r) + P2.w);
                        if (r.z == 0.0) r.xy = clamp(r.xy / 2.0, float2(-1.0), float2(1.0));
                        out.tex\(i) = r;

                """
            case 2: o += "        out.tex\(i) = float3(out.col0.rg, 1.0);\n"
            case 3: o += "        out.tex\(i) = float3(out.col1.rg, 1.0);\n"
            default: o += "        out.tex\(i) = coord.xyz; // emboss texgen: TODO light-space shift\n"
            }
            o += "    }\n"
        }
        o += "    return out;\n}\n\n"
        return o
    }

    // MARK: Fragment

    static let cIn = ["prev.rgb", "prev.aaa", "c0.rgb", "c0.aaa", "c1.rgb", "c1.aaa", "c2.rgb", "c2.aaa",
                      "textemp.rgb", "textemp.aaa", "rastemp.rgb", "rastemp.aaa", "int3(255)", "int3(128)", "konsttemp.rgb", "int3(0)"]
    static let aIn = ["prev.a", "c0.a", "c1.a", "c2.a", "textemp.a", "rastemp.a", "konsttemp.a", "0"]
    static let cOut = ["prev.rgb", "c0.rgb", "c1.rgb", "c2.rgb"]
    static let aOut = ["prev.a", "c0.a", "c1.a", "c2.a"]
    static let swz = ["r", "g", "b", "a"]

    static func kselC(_ k: Int) -> String {
        switch k {
        case 0...7: let v = [255, 223, 191, 159, 128, 96, 64, 32][k]; return "int3(\(v))"
        case 0xC...0xF: return "u.konst[\(k - 0xC)].rgb"
        case 0x10...0x1F:
            let c = ["r", "g", "b", "a"][(k - 0x10) / 4], i = (k - 0x10) % 4
            return "u.konst[\(i)].\(c)\(c)\(c)"
        default: return "int3(0)"
        }
    }
    static func kselA(_ k: Int) -> String {
        switch k {
        case 0...7: return "\([255, 223, 191, 159, 128, 96, 64, 32][k])"
        case 0x10...0x1F: return "u.konst[\((k - 0x10) % 4)].\(["r", "g", "b", "a"][(k - 0x10) / 4])"
        default: return "0"
        }
    }

    static func fragmentShader(_ s: GXState) -> String {
        var o = "fragment float4 gx_fs(VOut in [[stage_in]], constant FUniforms& u [[buffer(0)]]"
        for i in 0..<8 { o += ",\n    texture2d<float> t\(i) [[texture(\(i))]], sampler s\(i) [[sampler(\(i))]]" }
        o += ") {\n"
        o += """
            int4 prev = u.tevRegs[0], c0 = u.tevRegs[1], c1 = u.tevRegs[2], c2 = u.tevRegs[3];
            int4 rastemp = int4(0), textemp = int4(0), konsttemp = int4(0), rawtextemp = int4(0);
            int3 tevcoord = int3(0); int2 wrappedcoord = int2(0), tempcoord = int2(0);
            int alphabump = 0;
            int4 tevin_a, tevin_b, tevin_c, tevin_d;
            const int3 comp16 = int3(1, 256, 0), comp24 = int3(1, 256, 65536);
            (void)rastemp; (void)konsttemp; (void)alphabump; (void)wrappedcoord; (void)tempcoord; (void)comp16; (void)comp24;
            (void)tevin_a; (void)tevin_b; (void)tevin_c; (void)tevin_d; (void)c0; (void)c1; (void)c2; (void)tevcoord;

        """
        // Texture sampling helper per map: GX coords are s24 fixed point with 7 fractional bits over texture size.
        func sample(_ map: Int, _ uv: String) -> String {
            "iround(255.0 * t\(map).sample(s\(map), float2(\(uv)) / float2(u.texDims[\(map)].xy * 128)))"
        }
        for i in 0..<max(s.numTexGens, 1) {
            if i < s.numTexGens {
                o += "    int2 fixpoint_uv\(i) = int2((in.tex\(i).z == 0.0 ? in.tex\(i).xy : in.tex\(i).xy / in.tex\(i).z) * float2(u.coordDims[\(i)].xy * 128));\n"
            } else {
                o += "    int2 fixpoint_uv0 = int2(0);\n"
            }
        }
        // Indirect texture lookups
        var usedInd = Set<Int>()
        for n in 0..<s.numTevStages { let st = s.tevStage(n); if Int(st.ind & 3) < s.numIndStages { usedInd.insert(Int(st.ind & 3)) } }
        for i in 0..<s.numIndStages where usedInd.contains(i) {
            var (map, coord) = s.indRef(i)
            if coord >= s.numTexGens { coord = 0 }
            let (ss, ts) = s.indScale(i)
            o += "    tempcoord = fixpoint_uv\(coord) >> int2(\(ss), \(ts));\n"
            o += "    int3 iindtex\(i) = \(sample(map, "tempcoord")).abg;\n"
        }

        for n in 0..<s.numTevStages { o += stage(s, n, sample) }

        // Last stage's destination is what reaches the EFB.
        let last = s.tevStage(s.numTevStages - 1)
        let lcd = Int((last.cc >> 22) & 3), lad = Int((last.ac >> 22) & 3)
        if lcd != 0 { o += "    prev.rgb = \(cOut[lcd]);\n" }
        if lad != 0 { o += "    prev.a = \(aOut[lad]);\n" }
        o += "    prev = prev & 255;\n"
        o += alphaTest(s)
        o += "    return float4(prev) / 255.0;\n}\n"
        return o
    }

    static func stage(_ s: GXState, _ n: Int, _ sample: (Int, String) -> String) -> String {
        let st = s.tevStage(n)
        var o = "\n    // TEV stage \(n)\n"
        let texcoord = st.texCoord < s.numTexGens ? st.texCoord : 0
        let ind = st.ind
        let bt = Int(ind & 3), fmt = Int((ind >> 2) & 3), bias = Int((ind >> 4) & 7), bs = Int((ind >> 7) & 3)
        let mtxIndex = Int((ind >> 9) & 3), mtxID = Int((ind >> 11) & 3)
        let sw = Int((ind >> 13) & 7), tw = Int((ind >> 16) & 7), addPrev = (ind >> 20) & 1 == 1
        let hasInd = bt < s.numIndStages

        if hasInd && bs != 0 {
            o += "    alphabump = (iindtex\(bt).\(["", "x", "y", "z"][bs]) << \(["0", "5", "4", "3"][fmt])) & 248;\n"
        }
        if hasInd && mtxIndex != 0 {
            o += "    int3 iindtevcrd\(n) = iindtex\(bt) >> \(["0", "3", "4", "5"][fmt]);\n"
            if bias != 0 {
                let add = fmt == 0 ? "-128" : "1"
                let fields = ["", "x", "y", "xy", "z", "xz", "yz", "xyz"][bias]
                o += "    iindtevcrd\(n).\(fields) += \(add);\n"
            }
            let m = 2 * (mtxIndex - 1)
            switch mtxID {
            case 0:
                o += "    int2 indtevtrans\(n) = int2(idot(u.indMtx[\(m)].xyz, iindtevcrd\(n)), idot(u.indMtx[\(m + 1)].xyz, iindtevcrd\(n))) >> 3;\n"
            case 1:
                o += "    int2 indtevtrans\(n) = int2(fixpoint_uv\(texcoord) * iindtevcrd\(n).xx) >> 8;\n"
            default:
                o += "    int2 indtevtrans\(n) = int2(fixpoint_uv\(texcoord) * iindtevcrd\(n).yy) >> 8;\n"
            }
            o += "    if (u.indMtx[\(m)].w >= 0) indtevtrans\(n) >>= u.indMtx[\(m)].w; else indtevtrans\(n) <<= -u.indMtx[\(m)].w;\n"
        } else {
            o += "    int2 indtevtrans\(n) = int2(0);\n"
        }
        let wrapStart = ["(256<<7)", "(128<<7)", "(64<<7)", "(32<<7)", "(16<<7)"]
        func wrap(_ w: Int, _ c: String) -> String {
            if w == 0 { return "fixpoint_uv\(texcoord).\(c)" }
            if w >= 6 { return "0" }
            return "(fixpoint_uv\(texcoord).\(c) & (\(wrapStart[w - 1]) - 1))"
        }
        o += "    wrappedcoord = int2(\(wrap(sw, "x")), \(wrap(tw, "y")));\n"
        o += addPrev ? "    tevcoord.xy += wrappedcoord + indtevtrans\(n);\n" : "    tevcoord.xy = wrappedcoord + indtevtrans\(n);\n"
        o += "    tevcoord.xy = (tevcoord.xy << 8) >> 8;\n"

        let cc = st.cc, ac = st.ac
        let ca = Int((cc >> 12) & 0xF), cb = Int((cc >> 8) & 0xF), cc_ = Int((cc >> 4) & 0xF), cd = Int(cc & 0xF)
        let aa = Int((ac >> 13) & 7), ab = Int((ac >> 10) & 7), ac_ = Int((ac >> 7) & 7), ad = Int((ac >> 4) & 7)
        let rswap = s.swapTable(Int(ac & 3)), tswap = s.swapTable(Int((ac >> 2) & 3))

        let usesRas = [ca, cb, cc_, cd].contains { $0 == 10 || $0 == 11 } || [aa, ab, ac_, ad].contains(5)
        if usesRas {
            let ras: String
            switch st.colorChan {
            case 0: ras = "iround(in.col0 * 255.0)"
            case 1: ras = "iround(in.col1 * 255.0)"
            case 5: ras = "(int4(1) * alphabump)"
            case 6: ras = "(int4(1) * (alphabump | (alphabump >> 5)))"
            default: ras = "int4(0)"
            }
            o += "    rastemp = (\(ras)).\(rswap.map { swz[$0] }.joined());\n"
        }
        if st.texEnable && s.numTexGens > 0 {
            o += "    rawtextemp = \(sample(st.texMap, "tevcoord.xy"));\n"
            o += "    textemp = rawtextemp.\(tswap.map { swz[$0] }.joined());\n"
        } else if s.numTexGens == 0 {
            o += "    textemp = int4(0);\n"
        } else {
            o += "    textemp = int4(255);\n"
        }
        if [ca, cb, cc_, cd].contains(14) || [aa, ab, ac_, ad].contains(6) {
            o += "    konsttemp = int4(\(kselC(st.kcsel)), \(kselA(st.kasel)));\n"
        }
        o += "    tevin_a = int4(\(cIn[ca]), \(aIn[aa])) & int4(255);\n"
        o += "    tevin_b = int4(\(cIn[cb]), \(aIn[ab])) & int4(255);\n"
        o += "    tevin_c = int4(\(cIn[cc_]), \(aIn[ac_])) & int4(255);\n"
        o += "    tevin_d = int4(\(cIn[cd]), \(aIn[ad]));\n"

        o += "    \(cOut[Int((cc >> 22) & 3)]) = clamp(\(combiner(cc, isAlpha: false)), "
        o += (cc >> 19) & 1 == 1 ? "int3(0), int3(255));\n" : "int3(-1024), int3(1023));\n"
        o += "    \(aOut[Int((ac >> 22) & 3)]) = clamp(\(combiner(ac, isAlpha: true)), "
        o += (ac >> 19) & 1 == 1 ? "0, 255);\n" : "-1024, 1023);\n"
        return o
    }

    /// Dolphin WriteTevRegular / compare modes.
    static func combiner(_ v: UInt32, isAlpha: Bool) -> String {
        let comp = isAlpha ? "a" : "rgb"
        let bias = Int((v >> 16) & 3), op = Int((v >> 18) & 1), scale = Int((v >> 20) & 3)
        if bias != 3 {
            let biasS = ["", " + 128", " - 128", ""][bias]
            let sl = ["", " << 1", " << 2", ""][scale], sr = ["", "", "", " >> 1"][scale]
            let lerpBias = scale != 3 ? (op == 0 ? " + 128" : " + 127") : ""
            let opS = op == 0 ? "+" : "-"
            // (d + bias) << sl  op  ((((a<<8) + (b-a)*(c + (c>>7))) << sl) + lerpBias) >> 8,  then >> sr
            let X = comp
            let lhs = "(((tevin_d.\(X))\(biasS))\(sl))"
            let l1 = "(tevin_a.\(X)<<8) + (tevin_b.\(X)-tevin_a.\(X))*(tevin_c.\(X)+(tevin_c.\(X)>>7))"
            let l2 = "((\(l1))\(sl))"
            let l3 = "((\(l2))\(lerpBias)) >> 8"
            return "((\(lhs) \(opS) (\(l3)))\(sr))"
        }
        let mode = scale, eq = op == 1
        if !isAlpha {
            let gt = ["((tevin_a.r > tevin_b.r) ? tevin_c.rgb : int3(0))",
                      "((idot(tevin_a.rgb, comp16) > idot(tevin_b.rgb, comp16)) ? tevin_c.rgb : int3(0))",
                      "((idot(tevin_a.rgb, comp24) > idot(tevin_b.rgb, comp24)) ? tevin_c.rgb : int3(0))",
                      "(max(sign(tevin_a.rgb - tevin_b.rgb), int3(0)) * tevin_c.rgb)"]
            let e = ["((tevin_a.r == tevin_b.r) ? tevin_c.rgb : int3(0))",
                     "((idot(tevin_a.rgb, comp16) == idot(tevin_b.rgb, comp16)) ? tevin_c.rgb : int3(0))",
                     "((idot(tevin_a.rgb, comp24) == idot(tevin_b.rgb, comp24)) ? tevin_c.rgb : int3(0))",
                     "((int3(1) - sign(abs(tevin_a.rgb - tevin_b.rgb))) * tevin_c.rgb)"]
            return "tevin_d.rgb + \((eq ? e : gt)[mode])"
        }
        let gt = ["((tevin_a.r > tevin_b.r) ? tevin_c.a : 0)",
                  "((idot(tevin_a.rgb, comp16) > idot(tevin_b.rgb, comp16)) ? tevin_c.a : 0)",
                  "((idot(tevin_a.rgb, comp24) > idot(tevin_b.rgb, comp24)) ? tevin_c.a : 0)",
                  "((tevin_a.a > tevin_b.a) ? tevin_c.a : 0)"]
        let e = ["((tevin_a.r == tevin_b.r) ? tevin_c.a : 0)",
                 "((idot(tevin_a.rgb, comp16) == idot(tevin_b.rgb, comp16)) ? tevin_c.a : 0)",
                 "((idot(tevin_a.rgb, comp24) == idot(tevin_b.rgb, comp24)) ? tevin_c.a : 0)",
                 "((tevin_a.a == tevin_b.a) ? tevin_c.a : 0)"]
        return "tevin_d.a + \((eq ? e : gt)[mode])"
    }

    static func alphaTest(_ s: GXState) -> String {
        let a = s.alphaCompare
        func f(_ mode: Int, _ ref: String) -> String {
            ["(false)", "(prev.a < \(ref))", "(prev.a == \(ref))", "(prev.a <= \(ref))",
             "(prev.a > \(ref))", "(prev.a != \(ref))", "(prev.a >= \(ref))", "(true)"][mode]
        }
        if a.comp0 == 7 && a.comp1 == 7 && (a.logic == 0 || a.logic == 1) { return "" }
        let logic = [" && ", " || ", " != ", " == "][a.logic]
        return "    if (!(\(f(a.comp0, "u.alphaRef.x"))\(logic)\(f(a.comp1, "u.alphaRef.y")))) discard_fragment();\n"
    }
}
