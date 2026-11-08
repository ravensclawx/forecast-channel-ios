import GX
import RVL

// nw4r::ef resources — REFF (effect/emitter set) and REFT (texture set), in the layout this channel's library
// version uses (verified against the DOL: ParticleManager ctor fn_80090698 reads the draw type at res+0x94,
// DrawStrategyImpl::InitTev fn_8009A78C reads EmitterDrawSetting at the offsets below).
//
// Differences from the later library (e.g. Wii Sports): EmitterDesc is 0xA0 bytes (the particle type/option/
// dir/axis bytes sit at +0x8C, before the draw setting, instead of at the end of it), EmitterDrawSetting is 0xA0
// bytes, and ParticleParameterDesc has no rotate-offset fields (texture names follow at +0x7A).

/// Common REFF/REFT container: "REFF"/"REFT" file header, one block of the same magic, the project name,
/// then a name table { u32 tableSize, u16 count, u16 pad, { u16 nameLen, name, u32 offset, u32 size }* }
/// whose offsets are relative to the table.
enum EfNameTable {
    static func read(_ b: [UInt8], magic: String) throws -> [(name: String, offset: Int, size: Int)] {
        let r = BEReader(b)
        guard r.magic(0) == magic, r.magic(0x10) == magic else { throw RVLError.badMagic(r.magic(0), expected: magic) }
        // Block header (0x10): magic, size, u32 projectHeaderSize at +8 (relative to +0x18), then the project
        // name (u16 len at +0x14 of the project header). The table follows the project header.
        let project = 0x18
        let table = project + Int(r.u32(0x18))
        let count = Int(r.u16(table + 4))
        var out: [(String, Int, Int)] = []
        var p = table + 8
        for _ in 0..<count {
            let n = Int(r.u16(p))
            let name = String(decoding: b[(p + 2)..<(p + 2 + n)].prefix { $0 != 0 }, as: UTF8.self)
            p += 2 + n
            out.append((name, table + Int(r.u32(p)), Int(r.u32(p + 4))))
            p += 8
        }
        return out
    }
}

/// EmitterDesc (0xA0 in this version) — the fields the library reads.
public struct EfEmitterDesc {
    public var commonFlag: UInt32          // +00
    public var emitFlag: UInt32            // +04 (low byte = EmitFormType)
    public var emitLife: UInt16            // +08 (0xFFFF = infinite)
    public var ptclLife: UInt16            // +0A
    public var ptclLifeRandom: Int8        // +0C
    public var emitIntervalRandom: Int8    // +0E
    public var emitRandom: Int8            // +0F
    public var emit: Float                 // +10 particles per emission
    public var emitStart: UInt16           // +14
    public var emitPast: UInt16            // +16
    public var emitInterval: UInt16        // +18
    public var commonParam: [Float]        // +1C ×6 (form parameters)
    public var emitDiv: UInt16             // +34
    public var velInitVelocityRandom: Int8 // +36
    public var velMomentumRandom: Int8     // +37
    public var velPower: [Float]           // +38 radiation, yAxis, random, normal, diffusionEmitterNormal, spec, diffusionSpec
    public var velSpecDir: SIMD3<Float>    // +54
    public var scale: SIMD3<Float>         // +60
    public var rotate: SIMD3<Float>        // +6C
    public var translate: SIMD3<Float>     // +78
    public var lodNear: UInt8, lodFar: UInt8, lodMinEmit: UInt8, lodAlpha: UInt8   // +84
    public var randomSeed: UInt32          // +88
    public var ptclType: UInt8             // +8C (DrawStrategyBuilder fn_8009A0CC: 0 point, 1 line, 2 free, 3 billboard, 4 directional, 5 stripe)
    public var typeOption: UInt8           // +8D (billboard: 0 normal, 1 Y, 2 directional)
    public var typeDir: UInt8              // +8E
    public var typeAxis: UInt8             // +8F

    public var formType: UInt8 { UInt8(emitFlag & 0xFF) }   // 9 = point
}

public struct EfTevStage {
    public var color: (a: UInt8, b: UInt8, c: UInt8, d: UInt8)
    public var colorOp: (op: UInt8, bias: UInt8, scale: UInt8, clamp: UInt8, out: UInt8)
    public var alpha: (a: UInt8, b: UInt8, c: UInt8, d: UInt8)
    public var alphaOp: (op: UInt8, bias: UInt8, scale: UInt8, clamp: UInt8, out: UInt8)
    public var kColorSel: UInt8, kAlphaSel: UInt8
}

/// EmitterDrawSetting (0xA0 in this version).
public struct EfDrawSetting {
    public static let zCompEnableTest: UInt16 = 1 << 0, zCompEnableUpdate: UInt16 = 1 << 1, zCompBeforeTex: UInt16 = 1 << 2
    public static let clipDisable: UInt16 = 1 << 3, tex1Enable: UInt16 = 1 << 4, tex2Enable: UInt16 = 1 << 5, texIndEnable: UInt16 = 1 << 6
    public static let tex1Proj: UInt16 = 1 << 7, drawOrder: UInt16 = 1 << 11, fogEnable: UInt16 = 1 << 12
    public static let xySameSize: UInt16 = 1 << 13, xySameScale: UInt16 = 1 << 14

    public var flags: UInt16                 // +00
    public var aCmpComp0: UInt8, aCmpComp1: UInt8, aCmpOp: UInt8   // +02
    public var numTevs: UInt8                // +05
    public var flagClamp: UInt8              // +06
    public var indirectTargetStage: UInt8    // +07
    public var tev: [EfTevStage]             // +08 colour in, +18 colour op, +2C alpha in, +3C alpha op, +50/+54 k sels
    public var blend: (type: UInt8, src: UInt8, dst: UInt8, op: UInt8)   // +58
    public var rasColor: UInt8               // +5C ColorInput
    public var tevColorInput: [UInt8]        // +5D ×3 (TEVREG0..2)
    public var tevKColorInput: [UInt8]       // +60 ×4 (KCOLOR0..3)
    public var zCompareFunc: UInt8           // +64
    public var alphaFlickType: UInt8         // +65
    public var alphaFlickCycle: UInt16       // +66
    public var alphaFlickRandom: UInt8       // +68
    public var alphaFlickAmplitude: UInt8    // +69
    public var indTexOffsetMtx: [Float]      // +84 ×6
    public var indTexScaleExp: Int8          // +9C
    public var pivot: SIMD2<Float>           // +9D/+9E (s8, percent)
}

/// ParticleParameterDesc (no rotate offsets in this version).
public struct EfParticleDesc {
    public var color: [[SIMD4<UInt8>]]       // +00 [layer 0/1][pri/sec]
    public var size: SIMD2<Float>            // +10
    public var scale: SIMD2<Float>           // +18
    public var rotate: SIMD3<Float>          // +20
    public var textureScale: [SIMD2<Float>]  // +2C ×3
    public var textureRotate: [Float]        // +44 ×3
    public var textureTranslate: [SIMD2<Float>]  // +50 ×3
    public var textureWrap: UInt16           // +74
    public var textureReverse: UInt8         // +76
    public var aCmpRef0: UInt8, aCmpRef1: UInt8  // +77/+78
    public var textureNames: [String]        // +7A: 3 × { u16 len, name }
}

/// EmitterResource: { char* name, u32 headerSize } EmitterDesc (headerSize) { u32 size, ParticleParameterDesc }
/// { u16 numPtclTrack, numPtclInitTrack, ptr/size tables } { emitter tracks } track data.
public struct EfEmitterResource {
    public let name: String
    public let desc: EfEmitterDesc
    public let draw: EfDrawSetting
    public let particle: EfParticleDesc
    public let numPtclTrack: Int, numEmitTrack: Int

    init(name: String, _ b: [UInt8], at o: Int) {
        let r = BEReader(b)
        self.name = name
        let headerSize = Int(r.u32(o + 4))
        let e = o + 8
        func f(_ x: Int) -> Float { r.f32(x) }
        func v3(_ x: Int) -> SIMD3<Float> { SIMD3(f(x), f(x + 4), f(x + 8)) }
        desc = EfEmitterDesc(
            commonFlag: r.u32(e), emitFlag: r.u32(e + 4), emitLife: r.u16(e + 8), ptclLife: r.u16(e + 0xA),
            ptclLifeRandom: r.s8(e + 0xC), emitIntervalRandom: r.s8(e + 0xE), emitRandom: r.s8(e + 0xF),
            emit: f(e + 0x10), emitStart: r.u16(e + 0x14), emitPast: r.u16(e + 0x16), emitInterval: r.u16(e + 0x18),
            commonParam: (0..<6).map { f(e + 0x1C + $0 * 4) }, emitDiv: r.u16(e + 0x34),
            velInitVelocityRandom: r.s8(e + 0x36), velMomentumRandom: r.s8(e + 0x37),
            velPower: (0..<7).map { f(e + 0x38 + $0 * 4) }, velSpecDir: v3(e + 0x54),
            scale: v3(e + 0x60), rotate: v3(e + 0x6C), translate: v3(e + 0x78),
            lodNear: r.u8(e + 0x84), lodFar: r.u8(e + 0x85), lodMinEmit: r.u8(e + 0x86), lodAlpha: r.u8(e + 0x87),
            randomSeed: r.u32(e + 0x88),
            ptclType: r.u8(e + 0x8C), typeOption: r.u8(e + 0x8D), typeDir: r.u8(e + 0x8E), typeAxis: r.u8(e + 0x8F))

        let d = e + 0xA0
        let stages: [EfTevStage] = (0..<4).map { i in
            let c = d + 8 + i * 4, co = d + 0x18 + i * 5, a = d + 0x2C + i * 4, ao = d + 0x3C + i * 5
            return EfTevStage(color: (r.u8(c), r.u8(c + 1), r.u8(c + 2), r.u8(c + 3)),
                              colorOp: (r.u8(co), r.u8(co + 1), r.u8(co + 2), r.u8(co + 3), r.u8(co + 4)),
                              alpha: (r.u8(a), r.u8(a + 1), r.u8(a + 2), r.u8(a + 3)),
                              alphaOp: (r.u8(ao), r.u8(ao + 1), r.u8(ao + 2), r.u8(ao + 3), r.u8(ao + 4)),
                              kColorSel: r.u8(d + 0x50 + i), kAlphaSel: r.u8(d + 0x54 + i))
        }
        draw = EfDrawSetting(
            flags: r.u16(d), aCmpComp0: r.u8(d + 2), aCmpComp1: r.u8(d + 3), aCmpOp: r.u8(d + 4), numTevs: r.u8(d + 5),
            flagClamp: r.u8(d + 6), indirectTargetStage: r.u8(d + 7), tev: stages,
            blend: (r.u8(d + 0x58), r.u8(d + 0x59), r.u8(d + 0x5A), r.u8(d + 0x5B)),
            rasColor: r.u8(d + 0x5C), tevColorInput: (0..<3).map { r.u8(d + 0x5D + $0) },
            tevKColorInput: (0..<4).map { r.u8(d + 0x60 + $0) }, zCompareFunc: r.u8(d + 0x64),
            alphaFlickType: r.u8(d + 0x65), alphaFlickCycle: r.u16(d + 0x66), alphaFlickRandom: r.u8(d + 0x68),
            alphaFlickAmplitude: r.u8(d + 0x69), indTexOffsetMtx: (0..<6).map { f(d + 0x84 + $0 * 4) },
            indTexScaleExp: r.s8(d + 0x9C), pivot: SIMD2(Float(r.s8(d + 0x9D)), Float(r.s8(d + 0x9E))) / 100)

        let p0 = e + headerSize, psize = Int(r.u32(p0)), p = p0 + 4
        func rgba(_ x: Int) -> SIMD4<UInt8> { SIMD4(r.u8(x), r.u8(x + 1), r.u8(x + 2), r.u8(x + 3)) }
        var names: [String] = [], q = p + 0x7A
        for _ in 0..<3 {
            let n = Int(r.u16(q))
            names.append(String(decoding: b[(q + 2)..<(q + 2 + n)].prefix { $0 != 0 }, as: UTF8.self))
            q += 2 + n
        }
        particle = EfParticleDesc(
            color: [[rgba(p), rgba(p + 4)], [rgba(p + 8), rgba(p + 0xC)]],
            size: SIMD2(f(p + 0x10), f(p + 0x14)), scale: SIMD2(f(p + 0x18), f(p + 0x1C)), rotate: v3(p + 0x20),
            textureScale: (0..<3).map { SIMD2(f(p + 0x2C + $0 * 8), f(p + 0x30 + $0 * 8)) },
            textureRotate: (0..<3).map { f(p + 0x44 + $0 * 4) },
            textureTranslate: (0..<3).map { SIMD2(f(p + 0x50 + $0 * 8), f(p + 0x54 + $0 * 8)) },
            textureWrap: r.u16(p + 0x74), textureReverse: r.u8(p + 0x76), aCmpRef0: r.u8(p + 0x77), aCmpRef1: r.u8(p + 0x78),
            textureNames: names)

        let tracks = p0 + 4 + psize
        numPtclTrack = Int(r.u16(tracks))
        numEmitTrack = Int(r.u16(tracks + 4 + numPtclTrack * 8))
    }
}

/// REFF file: emitter resources by name (EffectSystem::RegisterResource / Resource::_GetEmitterResource).
public final class EfEffectFile {
    public let emitters: [String: EfEmitterResource]
    public init(_ b: [UInt8]) throws {
        var e: [String: EfEmitterResource] = [:]
        for (name, off, _) in try EfNameTable.read(b, magic: "REFF") { e[name] = EfEmitterResource(name: name, b, at: off) }
        emitters = e
    }
}

/// REFT TextureData: { u32 0, u16 width, u16 height, u32 dataSize, u8 format, u8 tlutFormat, u16 tlutEntries,
/// u32 tlutSize, u8 mipmap, ... } (0x20) then the image (and TLUT).
public struct EfTexture {
    public let name: String
    public let width: Int, height: Int
    public let format: GXTexFmt
    public let mipmap: Int
    public let rgba8: [UInt8]
}

public final class EfTextureFile {
    public let textures: [String: EfTexture]
    public init(_ b: [UInt8]) throws {
        let r = BEReader(b)
        var t: [String: EfTexture] = [:]
        for (name, off, _) in try EfNameTable.read(b, magic: "REFT") {
            let w = Int(r.u16(off + 4)), h = Int(r.u16(off + 6))
            let fmt = GXTexFmt(rawValue: UInt32(r.u8(off + 0xC))) ?? .i8
            let dataSize = Int(r.u32(off + 8))
            var palette: [UInt16] = []
            let tlutEntries = Int(r.u16(off + 0xE))
            if [.c4, .c8, .c14x2].contains(fmt) {
                palette = (0..<tlutEntries).map { r.u16(off + 0x20 + dataSize + $0 * 2) }
            }
            let rgba = GXTextureDecoder.decode(b, offset: off + 0x20, width: w, height: h, format: fmt,
                                               palette: palette, paletteFormat: UInt32(r.u8(off + 0xD)))
            t[name] = EfTexture(name: name, width: w, height: h, format: fmt, mipmap: Int(r.u8(off + 0x14)), rgba8: rgba)
        }
        textures = t
    }
}
