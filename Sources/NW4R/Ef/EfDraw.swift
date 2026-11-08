import GX
import simd

/// One particle draw as the GX command stream would issue it: the GX state after
/// DrawStrategyImpl::InitGraphics + SetupGP, the texture matrices loaded per texgen, the texture bound to each
/// texmap, and the GX_QUADS vertices (view space, y up) with their texcoords.
public struct EfDrawPacket {
    public var gx: GXState
    /// Per texgen: GX_TEXMTX0 + texmap·3 rows (2x4 used).
    public var texMtx: [(SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)]
    /// Per texmap: texture, wrap S/T (GXTexWrapMode), linear filtering (mipmap ≤ 1 → GX_LINEAR/GX_LINEAR).
    public var textures: [(texture: EfTexture, wrapS: UInt32, wrapT: UInt32)]
    public var quad: [(position: SIMD3<Float>, texCoord: SIMD2<Float>)]
}

/// nw4r::ef::DrawStrategyImpl + DrawBillboardStrategy (DrawStrategyBuilder type 3, option 0 = normal billboard).
/// DOL: InitTev fn_8009A78C, InitTexture fn_8009A71C, InitColor fn_8009AA38, SetupGP fn_8009ACE8,
/// DrawNormalBillboard fn_8009C06C (via fn_8009D420).
public enum EfDraw {
    /// Billboard texcoord table (billboard_tex0_u8): indices 0..3 = (0,1) (0,0) (1,0) (1,1).
    static let billboardTexCoords: [SIMD2<Float>] = [SIMD2(0, 1), SIMD2(0, 0), SIMD2(1, 0), SIMD2(1, 1)]

    /// EffectSystem::Draw for one particle manager. `view` is DrawInfo's view matrix (identity for the cursor).
    public static func draw(_ pm: EfParticleManager, view: simd_float4x4 = matrix_identity_float4x4,
                            textures: EfTextureFile) -> [EfDrawPacket] {
        let res = pm.resource
        guard res.desc.ptclType == 3, res.desc.typeOption == 0 else {
            assertionFailure("ef: draw type \(res.desc.ptclType)/\(res.desc.typeOption) not ported (\(res.name))")
            return []
        }
        let ds = res.draw
        if ds.flags & (1 << 10) != 0 { return [] }   // FLAG_HIDDEN

        // InitTexture: texmap slots for layer 1, layer 2, indirect.
        var texmapMap = [-1, -1, -1], numTexmap = 0
        if ds.flags & EfDrawSetting.tex1Enable != 0 { texmapMap[0] = 0; numTexmap += 1 }
        if ds.flags & EfDrawSetting.tex2Enable != 0 { texmapMap[1] = numTexmap; numTexmap += 1 }
        if ds.flags & EfDrawSetting.texIndEnable != 0 { texmapMap[2] = numTexmap; numTexmap += 1 }

        var gx = GXState()
        gx.setNumTexGens(numTexmap)
        initTev(&gx, ds, texmapMap)
        let (useColor1, useColor2) = initColor(&gx, ds)

        // DrawNormalBillboard
        let pmMtx = pm.globalMtx
        let viewMtx = view * pmMtx
        let vx = simd_length(SIMD3(viewMtx.columns.0.x, viewMtx.columns.0.y, viewMtx.columns.0.z))
        let vy = simd_length(SIMD3(viewMtx.columns.1.x, viewMtx.columns.1.y, viewMtx.columns.1.z))
        let mag = sqrt(view.columns.1.x * view.columns.1.x + view.columns.1.y * view.columns.1.y)
        let (rs, rc): (Float, Float) = mag == 0 ? (0, 1) : (-view.columns.1.x / mag, view.columns.1.y / mag)
        let pivot = ds.pivot

        var out: [EfDrawPacket] = []
        // Draw order: elders first unless FLAG_DRAW_ORDER (youngers first).
        let order = ds.flags & EfDrawSetting.drawOrder != 0 ? Array(pm.particles.reversed()) : pm.particles
        for p in order where p.alive {
            let s = p.drawSize(ds)
            guard s.x >= Float.ulpOfOne, s.y >= Float.ulpOfOne else { continue }
            var g = gx
            // SetupGP: _SetupACmp, _SetupTevReg, _SetupTexture.
            g.setAlphaCompare(UInt32(ds.aCmpComp0), UInt32(p.parameter.aCmpRef0), UInt32(ds.aCmpOp),
                              UInt32(ds.aCmpComp1), UInt32(p.parameter.aCmpRef1))
            setupTevReg(&g, p, ds, useColor1, useColor2)
            var mtx: [(SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)] = Array(repeating: (SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 1, 0)), count: max(numTexmap, 1))
            var texs: [(EfTexture, UInt32, UInt32)] = []
            for layer in 0..<3 where texmapMap[layer] >= 0 {
                let name = res.particle.textureNames[layer]
                guard let t = textures.textures[name] else { continue }
                let slot = texmapMap[layer]
                let wrapS = UInt32(p.parameter.textureWrap >> UInt16(layer * 4) & 3)
                let wrapT = UInt32(p.parameter.textureWrap >> UInt16(layer * 4 + 2) & 3)
                while texs.count <= slot { texs.append((t, wrapS, wrapT)) }
                texs[slot] = (t, wrapS, wrapT)
                mtx[slot] = textureMatrix(p, layer: layer, wrapS: wrapS, wrapT: wrapT)
                // Projection mapping (FLAG_TEX1_PROJ << layer) is not used by these resources.
                g.setTexCoordGen(slot, type: 1, src: 4)   // GX_TG_MTX2x4, GX_TG_TEX0, GX_TEXMTX0 + slot·3
            }
            out.append(EfDrawPacket(gx: g, texMtx: mtx, textures: texs.map { ($0.0, $0.1, $0.2) },
                                    quad: billboardQuad(p, viewMtx, vx, vy, rc, rs, s, pivot)))
        }
        return out
    }

    /// DrawStrategyImpl::InitTev (fn_8009A78C). The alpha op is taken from the colour-op table (library bug,
    /// present in the DOL too: both GXSetTevColorOp and GXSetTevAlphaOp read +0x18).
    static func initTev(_ gx: inout GXState, _ ds: EfDrawSetting, _ texmapMap: [Int]) {
        gx.setNumTevStages(Int(ds.numTevs))
        gx.setTevSwapModeTable(0, 0, 1, 2, 3)
        for i in 0..<Int(ds.numTevs) {
            let st = ds.tev[i]
            gx.setTevDirect(i)
            gx.setTevColorIn(i, GXTevColorArg(rawValue: UInt32(st.color.a))!, GXTevColorArg(rawValue: UInt32(st.color.b))!,
                             GXTevColorArg(rawValue: UInt32(st.color.c))!, GXTevColorArg(rawValue: UInt32(st.color.d))!)
            gx.setTevAlphaIn(i, GXTevAlphaArg(rawValue: UInt32(st.alpha.a))!, GXTevAlphaArg(rawValue: UInt32(st.alpha.b))!,
                             GXTevAlphaArg(rawValue: UInt32(st.alpha.c))!, GXTevAlphaArg(rawValue: UInt32(st.alpha.d))!)
            let op = st.colorOp
            gx.setTevColorOp(i, op: UInt32(op.op), bias: UInt32(op.bias), scale: UInt32(op.scale), clamp: op.clamp != 0, out: UInt32(op.out))
            gx.setTevAlphaOp(i, op: UInt32(op.op), bias: UInt32(op.bias), scale: UInt32(op.scale), clamp: op.clamp != 0, out: UInt32(op.out))
            gx.setTevKColorSel(i, UInt32(st.kColorSel))
            gx.setTevKAlphaSel(i, UInt32(st.kAlphaSel))
            gx.setTevSwapMode(i, ras: 0, tex: 0)
            let slot = i == 0 ? texmapMap[0] : texmapMap[1]
            if slot < 0 { gx.setTevOrder(i, coord: GXState.texCoordNull, map: UInt32(GXState.texMapNull), color: 4) }
            else { gx.setTevOrder(i, coord: UInt8(slot), map: UInt32(slot), color: 4) }
        }
        assert(ds.flags & EfDrawSetting.texIndEnable == 0, "ef: indirect texturing not ported")
        gx.setNumIndStages(0)
        // GXSetCullMode(GX_CULL_NONE), GXSetZCompLoc, GXSetClipMode: fixed-function state handled by the encoder.
        gx.setBlendMode(UInt32(ds.blend.type), UInt32(ds.blend.src), UInt32(ds.blend.dst), UInt32(ds.blend.op))
        gx.setZMode(ds.flags & EfDrawSetting.zCompEnableTest != 0, UInt32(ds.zCompareFunc), ds.flags & EfDrawSetting.zCompEnableUpdate != 0)
    }

    /// DrawStrategyImpl::InitColor (fn_8009AA38): one channel, material colour from the register (white).
    static func initColor(_ gx: inout GXState, _ ds: EfDrawSetting) -> (Bool, Bool) {
        gx.setNumChans(1)
        gx.setChanCtrl(GXState.color0, enable: false, ambSrc: 0, matSrc: 0)
        gx.setChanCtrl(GXState.alpha0, enable: false, ambSrc: 0, matSrc: 0)
        gx.setChanCtrl(GXState.color1a1, enable: false, ambSrc: 0, matSrc: 0)
        gx.setChanMatColor(GXState.color0a0, 0xFFFF_FFFF)
        gx.setChanAmbColor(GXState.color0a0, 0)
        var use1 = false, use2 = false
        for c in ds.tevColorInput where c == 1 || c == 2 { use1 = true; use2 = true }   // (library bug: use2 tests 1/2 too)
        for c in ds.tevKColorInput {
            if c == 1 || c == 2 { use1 = true }
            if c == 3 || c == 4 { use2 = true }
        }
        return (use1, use2)
    }

    /// DrawStrategyImpl::_SetupTevReg — particle colour layers into TEV registers / konst colours per ColorInput
    /// (1 = layer-1 primary, 2 = layer-1 secondary, 3 = layer-2 primary, 4 = layer-2 secondary).
    static func setupTevReg(_ gx: inout GXState, _ p: EfParticle, _ ds: EfDrawSetting, _ use1: Bool, _ use2: Bool) {
        func v(_ c: SIMD4<UInt8>) -> SIMD4<Int32> { SIMD4(Int32(c.x), Int32(c.y), Int32(c.z), Int32(c.w)) }
        for (layer, use, priID, secID) in [(0, use1, UInt8(1), UInt8(2)), (1, use2, UInt8(3), UInt8(4))] where use {
            let (pri, sec) = p.drawColor(layer: layer, ds)
            for i in 0..<3 {
                if ds.tevColorInput[i] == priID { gx.setTevColor(1 + i, v(pri)) }
                if ds.tevColorInput[1] == secID { gx.setTevColor(1 + i, v(sec)) }   // library typo: [1], not [i]
            }
            for i in 0..<4 {
                if ds.tevKColorInput[i] == priID { gx.setTevKColor(i, v(pri)) }
                if ds.tevKColorInput[i] == secID { gx.setTevKColor(i, v(sec)) }
            }
        }
    }

    /// DrawStrategyImpl::_SetupTexture texture matrix: T(trans) · [R about centre] · S about centre · (reverse/mirror).
    static func textureMatrix(_ p: EfParticle, layer: Int, wrapS: UInt32, wrapT: UInt32) -> (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>) {
        let pr = p.parameter
        let rev = Int(pr.textureReverse >> UInt8(layer * 2) & 3)
        var scaleS: Float = wrapS == 2 ? 2 : 1, scaleT: Float = wrapT == 2 ? 2 : 1
        if rev == 1 || rev == 3 { scaleS -= scaleS * 2 }
        if rev == 2 || rev == 3 { scaleT -= scaleT * 2 }
        var transS: Float = rev == 1 || rev == 3 ? 1 : 0, transT: Float = rev == 2 || rev == 3 ? 1 : 0
        if wrapS == 2 { transS *= 2 }
        if wrapT == 2 { transT *= 2 }
        func t(_ x: Float, _ y: Float) -> simd_float3x3 { simd_float3x3(rows: [SIMD3(1, 0, x), SIMD3(0, 1, y), SIMD3(0, 0, 1)]) }
        // MTX34Mult(&mtx, &work, &mtx) each step: mtx = work · mtx.
        var m = t(pr.textureTranslate[layer].x, pr.textureTranslate[layer].y)
        let r = pr.textureRotate[layer]
        if r != 0 {
            m = t(-0.5, -0.5) * m
            m = simd_float3x3(rows: [SIMD3(cos(r), -sin(r), 0), SIMD3(sin(r), cos(r), 0), SIMD3(0, 0, 1)]) * m
            m = t(0.5, 0.5) * m
        }
        m = t(-0.5, -0.5) * m
        m = simd_float3x3(rows: [SIMD3(pr.textureScale[layer].x, 0, 0), SIMD3(0, pr.textureScale[layer].y, 0), SIMD3(0, 0, 1)]) * m
        m = t(0.5, 0.5) * m
        m = simd_float3x3(rows: [SIMD3(scaleS, 0, transS), SIMD3(0, scaleT, transT), SIMD3(0, 0, 1)]) * m
        // Rows of the 2x4 matrix applied to (s, t, 1, 1): (m00, m01, 0, m02)
        let r0 = SIMD4<Float>(m[0][0], m[1][0], 0, m[2][0]), r1 = SIMD4<Float>(m[0][1], m[1][1], 0, m[2][1])
        return (r0, r1, SIMD4(0, 0, 1, 0))
    }

    /// DrawBillboardStrategy::DispParticle_Normal + DispPolygon (GX_QUADS: P−D0, P−D1, P+D0, P+D1).
    static func billboardQuad(_ p: EfParticle, _ viewMtx: simd_float4x4, _ vx: Float, _ vy: Float, _ rc: Float, _ rs: Float,
                              _ s: SIMD2<Float>, _ pivot: SIMD2<Float>) -> [(SIMD3<Float>, SIMD2<Float>)] {
        let rotZ = p.parameter.rotate.z   // Draw_GetRotate (no rotate offsets / manager rotation here)
        let pos4 = viewMtx * SIMD4(p.parameter.position, 1)
        let pos = SIMD3(pos4.x, pos4.y, pos4.z)
        let (px, py) = (pivot.x, pivot.y), (sx, sy) = (s.x, s.y)
        let vxrc = vx * rc, vxrs = vx * rs, vyrc = vy * rc, vyrs = vy * rs
        // nw4r::math::SinCosFIdx(−rotZ · 256/2π)
        let sr = sin(-rotZ), cr = cos(-rotZ)
        let crsx = cr * sx, srsx = sr * sx, crsy = cr * sy, srsy = sr * sy
        let e0 = (px - crsx * px) - srsy * py
        let e1 = (py + srsx * px) - crsy * py
        let p0 = SIMD3(vxrc * e0 + vyrs * e1 + pos.x, vxrs * e0 - vyrc * e1 + pos.y, pos.z)
        let d0 = SIMD3(vxrc * crsx - vxrc * srsy - vyrs * srsx - vyrs * crsy,
                       vxrs * crsx - vxrs * srsy + vyrc * srsx + vyrc * crsy, 0)
        let d1 = SIMD3(vxrc * crsx + vxrc * srsy - vyrs * srsx + vyrs * crsy,
                       vxrs * crsx + vxrs * srsy + vyrc * srsx - vyrc * crsy, 0)
        return [(p0 - d0, billboardTexCoords[0]), (p0 - d1, billboardTexCoords[1]),
                (p0 + d0, billboardTexCoords[2]), (p0 + d1, billboardTexCoords[3])]
    }
}
