import simd

// nw4r::ef runtime: EffectSystem → Effect → Emitter → ParticleManager → Particle.
// Ported for the emitter features this channel's effects use (point/zero-size forms, no animation tracks);
// the calc order follows Effect::Calc: CalcEmitter, CalcParticle, CalcEmission, CalcParticle.

/// ParticleParameter (Particle +0x20): the per-particle copy of ParticleParameterDesc plus motion state.
public struct EfParticleParameter {
    public var color: [[SIMD4<UInt8>]]      // +00 [layer][pri, sec]
    public var size: SIMD2<Float>           // +10
    public var scale: SIMD2<Float>          // +18
    public var rotate: SIMD3<Float>         // +20 (+0x28 = rotate.z: written by the channel's fn_8002CB1C)
    public var textureScale: [SIMD2<Float>]
    public var textureRotate: [Float]
    public var textureTranslate: [SIMD2<Float>]
    public var textureWrap: UInt16
    public var textureReverse: UInt8
    public var aCmpRef0: UInt8, aCmpRef1: UInt8
    public var alphaFlickRnd: Int8 = 0
    public var velocity = SIMD3<Float>(repeating: 0)
    public var position = SIMD3<Float>(repeating: 0)
    public var prevPosition = SIMD3<Float>(repeating: 0)
    public var momentum: Float = 1

    /// ParticleParameter::Initialize
    init(_ d: EfParticleDesc) {
        color = d.color; size = d.size; scale = d.scale; rotate = d.rotate
        textureScale = d.textureScale; textureRotate = d.textureRotate; textureTranslate = d.textureTranslate
        textureWrap = d.textureWrap; textureReverse = d.textureReverse; aCmpRef0 = d.aCmpRef0; aCmpRef1 = d.aCmpRef1
    }
}

/// nw4r::ef::Particle
public final class EfParticle {
    public var parameter: EfParticleParameter
    public var tick: UInt16 = 0
    public let life: UInt16
    public internal(set) var alive = true   // mLifeStatus ACTIVE (1) / CLOSING (2) — what fn_8002CB1C tests at +0xC

    init(life: UInt16, position: SIMD3<Float>, velocity: SIMD3<Float>, momentum: Float, desc: EfParticleDesc) {
        parameter = EfParticleParameter(desc)
        parameter.momentum = momentum
        self.life = life == 0 ? 1 : life
        parameter.position = position; parameter.prevPosition = position; parameter.velocity = velocity
    }

    /// Particle::Draw_GetColor (alpha flicker; ParticleManager::Draw_ModifyColor is identity here).
    public func drawColor(layer: Int, _ ds: EfDrawSetting) -> (SIMD4<UInt8>, SIMD4<UInt8>) {
        var pri = parameter.color[layer][0], sec = parameter.color[layer][1]
        if ds.alphaFlickType != 0 {
            let cycleL = UInt32(ds.alphaFlickCycle) + UInt32(ds.alphaFlickCycle) * UInt32(bitPattern: Int32(parameter.alphaFlickRnd)) &* UInt32(ds.alphaFlickRandom) / 12700
            let cycle = Int(min(cycleL, 0xFFFF)), amp = Int(ds.alphaFlickAmplitude)
            let pos = (Int(tick) - 1) % max(cycle, 1)
            var alpha = 0
            switch ds.alphaFlickType {
            case 1: alpha = pos * 2 <= cycle ? 128 - amp + amp * (pos * 4) / cycle : 128 + amp * 3 - (amp * pos * 4) / cycle
            case 2: alpha = 128 + amp - (amp * pos * 2) / cycle
            case 3: alpha = 128 - amp + amp * (pos * 2) / cycle
            case 4: alpha = pos * 2 <= cycle ? 128 + amp : 128 - amp
            case 5: alpha = 128 + Int(Float(amp) * sin(2 * Float.pi * Float(pos) / Float(cycle)))
            default: break
            }
            alpha = max(0, min(255, alpha))
            pri.w = UInt8((Int(pri.w) * alpha + 128) >> 8); sec.w = UInt8((Int(sec.w) * alpha + 128) >> 8)
        }
        return (pri, sec)
    }

    /// Draw_GetSizeX / Draw_GetSizeY (ParticleManager::Draw_ModifyScale = ×1 for these managers).
    public func drawSize(_ ds: EfDrawSetting) -> SIMD2<Float> {
        let p = parameter
        let sx = p.size.x * p.scale.x
        let sy: Float
        switch ds.flags & (EfDrawSetting.xySameSize | EfDrawSetting.xySameScale) {
        case EfDrawSetting.xySameScale: sy = p.size.y * p.scale.x
        case EfDrawSetting.xySameSize: sy = p.size.x * p.scale.y
        case EfDrawSetting.xySameSize | EfDrawSetting.xySameScale: sy = p.size.x * p.scale.x
        default: sy = p.size.y * p.scale.y
        }
        return SIMD2(sx, sy)
    }
}

/// nw4r::ef::ParticleManager — the particles of one emitter, drawn with the resource's draw setting.
public final class EfParticleManager {
    public let resource: EfEmitterResource
    public internal(set) var particles: [EfParticle] = []
    weak var emitter: EfEmitter?
    var lastCalced = 0

    init(_ r: EfEmitterResource) { resource = r }

    /// CalcGlobalMtx: the particle manager inherits the emitter's space.
    public var globalMtx: simd_float4x4 { emitter?.globalMtx ?? matrix_identity_float4x4 }

    /// ParticleManager::Calc — particles not yet calculated this frame: retire at end of life, integrate, tick++.
    func calc() {
        for p in particles[lastCalced...] where p.alive {
            p.parameter.prevPosition = p.parameter.position
            if p.life <= p.tick { p.alive = false; continue }
            // No particle tracks in these resources (NumPtclTrack == 0); velocity integration (AddPosition).
            p.parameter.position += p.parameter.velocity * p.parameter.momentum
            p.tick &+= 1
        }
        particles.removeAll { !$0.alive }
        lastCalced = particles.count
    }
}

/// nw4r::ef::Emitter
public final class EfEmitter {
    public let resource: EfEmitterResource
    public let manager: EfParticleManager
    weak var effect: EfEffect?
    var tick: UInt32 = 0
    var waitTime: Int
    var emitIntervalWait: Int = 0
    var emitCount: Float = 0
    var isFirstEmission = true
    var alive = true

    init(_ r: EfEmitterResource) {
        resource = r
        manager = EfParticleManager(r)
        waitTime = Int(r.desc.emitStart)
        manager.emitter = self
    }

    /// Emitter::CalcGlobalMtx: effect root × emitter S/R/T from the EmitterDesc.
    var globalMtx: simd_float4x4 {
        let d = resource.desc
        var m = effect?.rootMtx ?? matrix_identity_float4x4
        m = m * simd_float4x4(translation: d.translate)
        if d.rotate != .zero { m = m * simd_float4x4(rotationZYX: d.rotate) }
        return m * simd_float4x4(diagonal: SIMD4(d.scale, 1))
    }

    /// Emitter::CalcEmitter — retire at the end of the emit span unless CMN_FLAG_MAX_LIFE (4).
    func calcEmitter() {
        guard alive, waitTime <= 0 else { return }
        if resource.desc.commonFlag & 4 == 0, tick >= UInt32(resource.desc.emitLife) { alive = false }
    }

    /// Emitter::CalcEmission → Emission → EmitterForm::Emission
    func calcEmission() {
        guard alive else { tick &+= 1; return }
        if waitTime > 0 { waitTime -= 1; return }
        emission()
        tick &+= 1
    }

    func emission() {
        if emitIntervalWait > 0 { emitIntervalWait -= 1; return }
        let d = resource.desc
        emitIntervalWait = Int(d.emitInterval)   // emitIntervalRandom is 0 in these resources
        emitCount += d.emit                       // emitRandom is 0 in these resources
        if isFirstEmission, d.emit != 0, emitCount < 1 { emitCount = 1 }
        if emitCount >= 1 {
            let n = Int(emitCount)
            for _ in 0..<n { emitOne() }
            emitCount -= Float(n)
        }
        isFirstEmission = false
    }

    /// EmitterFormPoint::Emission (form 9): position at the emitter origin. CalcVelocity scales random/normal
    /// directions by the velPower terms, all of which are 0 in these resources, so the velocity is zero.
    func emitOne() {
        let d = resource.desc
        // Powers: radiation, Y axis, random, normal, spec (indices 4 and 6 are diffusion angles).
        assert([0, 1, 2, 3, 5].allSatisfy { d.velPower[$0] == 0 } && d.velInitVelocityRandom == 0 && d.velMomentumRandom == 0,
               "ef: emitter velocity/random terms beyond this port's scope (\(resource.name))")
        manager.particles.append(EfParticle(life: d.ptclLife, position: .zero, velocity: .zero, momentum: 1, desc: resource.particle))
    }
}

/// nw4r::ef::Effect — a set of emitters created from one resource name, placed by its root matrix.
public final class EfEffect {
    public var translate = SIMD3<Float>(repeating: 0)   // +8C..+94, set by the channel before the first Calc
    public internal(set) var emitters: [EfEmitter] = []
    public var rootMtx: simd_float4x4 { simd_float4x4(translation: translate) }

    /// Effect::Calc
    public func calc() {
        for e in emitters { e.calcEmitter() }
        for e in emitters { e.manager.calc() }
        for e in emitters { e.calcEmission() }
        for e in emitters { e.manager.calc() }
    }

    /// The particle managers in draw order.
    public var particleManagers: [EfParticleManager] { emitters.map(\.manager) }
}

/// nw4r::ef::EffectSystem (CreateEffect by resource name).
public final class EfEffectSystem {
    public let effects: EfEffectFile
    public let textures: EfTextureFile
    public init(effects: EfEffectFile, textures: EfTextureFile) { self.effects = effects; self.textures = textures }

    /// EffectSystem::CreateEffect(name, group, calcRemain) — one emitter per resource of that name.
    public func createEffect(_ name: String) -> EfEffect? {
        guard let r = effects.emitters[name] else { return nil }
        let fx = EfEffect()
        let e = EfEmitter(r)
        e.effect = fx
        fx.emitters = [e]
        return fx
    }
}

extension simd_float4x4 {
    init(translation t: SIMD3<Float>) {
        self = matrix_identity_float4x4
        columns.3 = SIMD4(t, 1)
    }
    /// MTX34 from a ZYX Euler rotation (nw4r::math::MTX34RotXYZRad order: Rz·Ry·Rx).
    init(rotationZYX r: SIMD3<Float>) {
        let (sx, cx, sy, cy, sz, cz) = (sin(r.x), cos(r.x), sin(r.y), cos(r.y), sin(r.z), cos(r.z))
        let rx = simd_float4x4(rows: [SIMD4(1, 0, 0, 0), SIMD4(0, cx, -sx, 0), SIMD4(0, sx, cx, 0), SIMD4(0, 0, 0, 1)])
        let ry = simd_float4x4(rows: [SIMD4(cy, 0, sy, 0), SIMD4(0, 1, 0, 0), SIMD4(-sy, 0, cy, 0), SIMD4(0, 0, 0, 1)])
        let rz = simd_float4x4(rows: [SIMD4(cz, -sz, 0, 0), SIMD4(sz, cz, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(0, 0, 0, 1)])
        self = rz * ry * rx
    }
}
