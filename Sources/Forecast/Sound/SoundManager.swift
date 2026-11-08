import Foundation
import NW4R
import RVL

/// Port of sound_manager.cpp (main.dol 0x800418A8–0x800429A4). See decomp/notes/sound.md.
/// The channel calls these by sound ID — IDs are rev_wtr.brsar sound indices (see `SE`).
public final class SoundManager {
    /// rev_wtr.brsar sound IDs (names from the archive's SYMB block).
    public enum SE: Int {
        case cikyugi = 0, earthSel, earthZoom1, earthZoom2, earthZoom3, earthZoom4, earthZoom5, earthZoom6, earthZoom7, earthZoom8,
             earthZoom9, earthZoom10, earthAngle1, earthAngle2, earthAngle3, earthAngle4, earthAngle5, earthAngle6,
             earthAxis /*0x12*/, earthUndo /*0x13*/, earthKaiten /*0x14 rotate loop*/, earthTukami /*0x15 grab*/, bScroll,
             comReceive, comSuccess, comError, comButton, comButtonB,
             bgmMorningYohou /*28*/, bgmMorningCikyu, bgmMorningSelf, bgmNightYohou, bgmNightCikyu, bgmNightSelf, bgmOption /*34*/,
             ketteiB0, ketteiB1, ketteiB2, cancel /*0x26*/, cancelBig, menuSel, tenki, tenki2, tenki2Ret, kion,
             placeChange, placeSel1, placeSel2, placeScroll, rain, thunder
    }

    /// Volume faders updated in fn_80041F54 (struct at the "Nonef" label: {step, cur, target, active} ×3).
    public struct Fader { public var step: Float = 0, current: Float = 1, target: Float = 1, active = false }

    public let system: SoundSystem
    public let weatherArchive: Int
    public private(set) var homeArchive: Int?
    private var output: AudioOutput?

    /// lbl_80330C4C — the shared SE handle used by PlaySE.
    public let seHandle = SoundHandle()
    /// lbl_801F76D4[4] — BGM layers: [0] SELF, [1] YOHOU (forecast), [2] CIKYU (globe), [3] OPTION.
    public let bgmHandles = [SoundHandle(), SoundHandle(), SoundHandle(), SoundHandle()]
    /// lbl_80330C2C — the globe rotation loop (SimpleGlobe::UpdateRotateSound).
    public let rotateHandle = SoundHandle()
    public var faders = [Fader(), Fader(), Fader()]
    /// lbl_803301E8 — SCGetSoundMode: true = stereo (AX output mode 0), false = mono (mode 3).
    public var stereo = true

    /// fn_800418A8 Init: opens rev_wtr.brsar (content 9) and, like fn_80042130, the HOME Menu SE archive.
    public init(assets: Assets) throws {
        let tables = try SndTables(dol: assets.title.content(index: Assets.Content.mainDol.rawValue))
        system = SoundSystem(tables: tables, reverbParam: tables.channelReverbParam)
        guard let rsar = try assets.archive(.weather).file("/rev_wtr.brsar") else {
            throw RVLError.missing("Cannot open Sound Archive File")   // OSPanic at sound_manager.cpp:0x19D
        }
        weatherArchive = system.addArchive(try SoundArchive(rsar))
        if let huf = try? assets.archive(.homeButton).file("/HomeButton3/Huf8_HomeButtonSe.brsar"),
           let raw = try? CXHuffman.uncompress(huf), let hbm = try? SoundArchive(raw) {
            homeArchive = system.addArchive(hbm)
        }
    }

    /// Start audio output (AVAudioEngine). Separate so offline tools can render without a device.
    public func startOutput() throws {
        let o = AudioOutput(system: system)
        try o.start()
        output = o
    }

    // MARK: - sound_manager.cpp API

    /// fn_80042520 PlaySE(id): StartSound into the shared SE handle; volume 1, pitch 1, pan 0.
    public func playSE(_ id: Int) { playSE(id, volume: 1, pitch: 1, pan: 0) }
    public func playSE(_ se: SE) { playSE(se.rawValue) }

    /// fn_80042640 PlaySE(id, volume, pitch, pan).
    public func playSE(_ id: Int, volume: Float, pitch: Float, pan: Float) {
        system.startSound(archive: weatherArchive, id: id, handle: seHandle)
        seHandle.setVolume(volume)
        seHandle.setPitch(pitch)
        seHandle.setPan(pan)
    }

    /// fn_800427A8 StartSound(handle, id).
    @discardableResult
    public func startSound(_ handle: SoundHandle, _ id: Int) -> Bool { system.startSound(archive: weatherArchive, id: id, handle: handle) }

    /// fn_800428A4 SetVolume(handle, v) (BasicSound vtable +0x38).
    public func setVolume(_ h: SoundHandle, _ v: Float, frames: Int = 0) { h.setVolume(v, frames: frames) }
    /// fn_80042964 SetPitch(handle, p).
    public func setPitch(_ h: SoundHandle, _ p: Float) { h.setPitch(p) }
    /// fn_80042984 SetPan(handle, p).
    public func setPan(_ h: SoundHandle, _ p: Float) { h.setPan(p) }
    /// fn_80042810 Stop(handle, fadeFrames) (vtable +0x18).
    public func stop(_ h: SoundHandle, fadeFrames: Int = 0) { h.stop(fadeFrames: fadeFrames) }
    /// fn_80042830 Pause(handle, flag, fadeFrames) (vtable +0x1C).
    public func pause(_ h: SoundHandle, _ flag: Bool, fadeFrames: Int = 0) { h.pause(flag, fadeFrames: fadeFrames) }
    /// fn_800429A4 IsAttached(handle).
    public func isAttached(_ h: SoundHandle) -> Bool { h.isAttached }

    /// HOME Menu SE (HOMESE_* in Huf8_HomeButtonSe.brsar) — used by the HBM port.
    public func playHomeSE(_ id: Int) {
        guard let a = homeArchive else { return }
        system.startSound(archive: a, id: id, handle: nil)
    }

    /// fn_80041F54 Update — once per game frame: step the three faders, then SoundArchivePlayer::Update.
    public func update() {
        for i in faders.indices {
            let target = faders[i].active ? faders[i].target : 1
            if faders[i].current < target { faders[i].current = min(faders[i].current + faders[i].step, target) }
            else if faders[i].current > target { faders[i].current = max(faders[i].current - faders[i].step, target) }
        }
        system.gameFrameUpdate()
    }

    /// SimpleGlobe::UpdateRotateSound (fn_800410A4): seId 0x14, volume speed/5, pitch speed/90 + 0.5.
    public func updateRotateSound(speed: Float) {
        guard speed >= 1 else { return }
        if !rotateHandle.isAttached { startSound(rotateHandle, SE.earthKaiten.rawValue) }
        rotateHandle.setVolume(min(speed / 5, 1))
        rotateHandle.setPitch(min(speed / 90, 1) + 0.5)
        rotateHandle.setPan(0)
    }
}
