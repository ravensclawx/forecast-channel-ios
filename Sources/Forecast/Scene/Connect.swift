import Foundation
import Metal
import NW4R
import RVL

/// CConnect (Connect.cpp, 0x460): the boot-time WiiConnect24 fetch of forecast.bin / short.bin, its progress dots
/// and error screen. Port of CConnect_ctor/Start/Update/IsDone (fn_8000AA94..fn_8000B624) and draws fn_8000B46C,
/// fn_8000B6B0 (progress) and fn_8000B9C8 (error code). The NWC24 download is replaced by ForecastService.
public final class Connect {
    let ctx: SceneContext
    let service: ForecastService
    let progress: UILayout          // +448 error1.brlyt ("please wait")
    let errorLayout: UILayout       // +44C error0.brlyt
    let fade: Fade                  // +C
    /// +10 download state: 0 start, 2 waiting, 6 done, 7 error
    public private(set) var state = 0
    /// +450 dialog state: 0, 1 decide, 2 progress shown, 3 → error fade, 4 → done fade, 5 error interactive, 6 done
    var ui = 0
    var counter = 0                 // +444 progress animation 0..72
    var result: Int32 = 0           // +34 NWC24-style result code
    var serverMessage: [UInt16]?    // +440 forecast-file message (shown instead of data)
    let box = ResultBox()
    var waitFrames = 0
    let loopSE = SoundHandle()      // +454 (SE 0x17 while the progress dialog is up)
    var loopSEActive = false        // +458
    var spinnerImages: [Int] = []
    var codeFormat: (fmt: [UInt16], label: [UInt16], prefix: [UInt16]) = ([], [], [])

    init(ctx: SceneContext, service: ForecastService) throws {
        self.ctx = ctx; self.service = service
        progress = try ctx.layout("error1.brlyt")
        errorLayout = try ctx.layout("error0.brlyt")
        // iPhone portrait: backgrounds cover the screen; the dialogs stay centred as one group.
        PortraitArrange.stretchBackgrounds(progress)
        PortraitArrange.stretchBackgrounds(errorLayout)
        fade = ctx.fade
        // Tables from main.dol: spinner image indices (lbl_80179358, +0x18 for non-JP regions) and the error-code
        // format "%ls %ls%06d" with its label/prefix strings (relative to the "error1.brlyt" string, lbl_80198D80).
        if let dol = try? ctx.assets.title.content(index: Assets.Content.mainDol.rawValue) {
            let img = DOLImage(dol), r = BEReader(dol)
            let base: UInt32 = 0x8017_9358 + (ctx.region != 0 ? 0x18 : 0)
            spinnerImages = (0..<6).map { Int(img.u32(base + UInt32($0 * 4))) }
            func wide(_ a: UInt32) -> [UInt16] {
                guard var o = img.offset(a) else { return [] }
                var s: [UInt16] = []
                while o + 1 < dol.count, r.u16(o) != 0, s.count < 64 { s.append(r.u16(o)); o += 2 }
                return s
            }
            let s: UInt32 = 0x8019_8D80
            let labels: [UInt32] = [0x1B8, 0x1C8, 0x1E0, 0x1F8, 0x218, 0x228, 0x248]
            codeFormat = (wide(s + 0x260), wide(s + labels[min(ctx.lang.rawValue, 6)]), wide(s + 0x1AC))
        }
    }

    /// CConnect_Start (fn_8000AC44): the original builds /<lang>/<country:03>/forecast.bin and short.bin here.
    public func start() {
        state = 0; ui = 0; counter = 0; result = 0; serverMessage = nil
        progress.reset(); errorLayout.reset()
        errorLayout.find("next")?.keepPressed = true
        box.set(nil)
    }

    public var isDone: Bool { state == 6 && fade.isIdle }       // CConnect_IsDone

    /// CConnect_Update (fn_8000AD28)
    public func update() {
        let prev = state
        progress.update(); errorLayout.update()
        switch state {
        case 0:
            let svc = service, b = box
            let pending = ctx.pendingData
            Task.detached { let r = await Task { try await svc.loadForBoot(refreshed: { pending.set($0) }) }.result; b.set(r) }
            state = 2; waitFrames = 0
        case 2:
            waitFrames += 1
            if let r = box.get() {
                switch r {
                case .success(let data):
                    ctx.data = data
                    if let m = data.forecast.message, !m.isEmpty { serverMessage = Array(m.utf16); state = 7; result = 0 }
                    else { state = 6 }
                case .failure(let e):
                    result = Connect.nwc24Code(for: e); state = 7
                }
            }
        default: break
        }
        _ = prev
        switch ui {
        case 0: ui = 1; fallthrough
        case 1:
            if state == 6 { ui = 6 }
            else if state == 7 { fade.startFadeIn(0x1E); ui = 5; ctx.playSE(0x19) }
            else if waitFrames > 30 { fade.startFadeIn(0x1E); ui = 2 }   // NWC24 status 4/5 = transferring
        case 2:
            if fade.isIdle {
                if state == 6 { fade.startFadeOut(0x32); ui = 4; ctx.playSE(0x18) }
                else if state == 7 { fade.startFadeOut(0x1E); ui = 3 }
            }
        case 3:
            if fade.isIdle { fade.startFadeIn(0x1E); ui = 5; ctx.playSE(0x19) }
        case 4:
            if fade.isIdle { ui = 6 }
        case 5:
            ctx.ui.updateHover(errorLayout, ctx.pad)
            if fade.isIdle && ctx.ui.buttonTrig("next", ctx.pad) { ctx.playSE(0x1A); ctx.returnToWiiMenu = true }
        default: break
        }
        if (2..<5).contains(ui) { counter += 1; if counter > 0x48 { counter = 0 } }
        if ui == 2 {
            if !loopSEActive, let s = ctx.sound { _ = s.startSound(loopSE, 0x17); loopSEActive = true }
        } else if loopSEActive { ctx.sound?.stop(loopSE); loopSEActive = false }
        // A finished download with the dialog never shown still has to report done.
        if ui == 6 && state != 6 { state = 6 }
    }

    final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Result<WeatherData, Error>?
        func set(_ v: Result<WeatherData, Error>?) { lock.lock(); value = v; lock.unlock() }
        func get() -> Result<WeatherData, Error>? { lock.lock(); defer { lock.unlock() }; return value }
    }

    /// Map our download failures onto the NWC24 result codes CConnect switches on.
    static func nwc24Code(for e: Error) -> Int32 {
        if let u = e as? URLError {
            switch u.code {
            case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed: return -9
            case .timedOut: return -9
            default: return -1
            }
        }
        if e is WeatherDataError { return -1 }
        return -1
    }

    /// fn_8000B46C
    func draw(_ enc: MTLRenderCommandEncoder, _ d2: SceneDraw2D, weatherTPL: TPLFile?) {
        if ui == 5 && ctx.isPortrait {
            // iPhone: a plain message instead of WiiConnect24 texts and error codes; the button retries.
            let offline = result == -9 || result == -4
            let msg = offline ? "Couldn't connect to the internet.\nCheck your connection and try again."
                              : "The forecast couldn't be downloaded\nright now. Please try again later."
            if let tb = errorLayout.pane("error_server") as? TextBox { tb.text = Array(msg.utf16); tb.visible = true }
            if let t = errorLayout.find("text"), let tp = t.text { tp.children.forEach { $0.visible = false }; tp.visible = false }
            (errorLayout.pane("error_code") as? TextBox)?.text = []
            PortraitArrange.setText(errorLayout, "nextTUS", "Try Again")
            errorLayout.draw(ctx.lyt, enc)
            return
        }
        if ui == 5 {
            var code = 0
            let text = errorLayout.find("text")
            var idx: Int? = nil
            switch result {
            case -11: idx = 0
            case -3: idx = 1
            case -9, -4: idx = 2
            case -5: idx = 3
            case -12: idx = 6
            case -2: idx = 7
            case 0:
                if let m = serverMessage, let tb = errorLayout.pane("error_server") as? TextBox {
                    tb.text = m; idx = -1
                } else { code = 6 }
            case -8: code = 1
            case -1: code = 5
            case -6: code = 2
            case -7: code = 3
            default: code = 0x63
            }
            if let t = text {
                if let i = idx { t.textIndex = i } else if code != 0 { t.textIndex = 5 }
                t.pendingTextIndex = t.textIndex
                if t.textIndex < 0, let tp = t.text { tp.children.forEach { $0.visible = false } }
            }
            (errorLayout.pane("error_server"))?.visible = (idx == -1)
            setErrorCode(code)
            errorLayout.draw(ctx.lyt, enc)
        } else if ui >= 2 && ui < 5 {
            progress.draw(ctx.lyt, enc)
            drawSpinner(enc, d2, weatherTPL)
        }
    }

    /// fn_8000B9C8: "Error Code: FORE000005"-style line into the `error_code` text box.
    func setErrorCode(_ code: Int) {
        guard let tb = errorLayout.pane("error_code") as? TextBox else { return }
        guard code != 0, !codeFormat.fmt.isEmpty else { tb.text = []; return }
        // %ls %ls%06d with (label, prefix, |code|)
        var out: [UInt16] = [], strs = [codeFormat.label, codeFormat.prefix], i = 0, f = codeFormat.fmt
        while i < f.count {
            if f[i] == 0x25, i + 2 < f.count, f[i + 1] == 0x6C, f[i + 2] == 0x73 { out += strs.isEmpty ? [] : strs.removeFirst(); i += 3; continue }
            if f[i] == 0x25 { out += Array(String(format: "%06d", abs(code)).utf16); i += 4; continue }
            out.append(f[i]); i += 1
        }
        tb.text = out
    }

    /// fn_8000B6B0: six dots at y 280, 40 px apart, scale 0.6, a light chasing along every 12 frames.
    func drawSpinner(_ enc: MTLRenderCommandEncoder, _ d2: SceneDraw2D, _ tpl: TPLFile?) {
        guard let tpl, spinnerImages.count == 6 else { return }
        var x = 0.5 * (ctx.screenWidth - 200)
        let cur = counter / 12, rem = counter % 12
        for i in 0..<6 {
            var a: Int
            if i == cur { a = Int(255 * sin(1.5707964 * Float(rem + 1) / 12)) }
            else {
                var d = cur - i; if d < 0 { d += 6 }
                a = max(0, 0x48 - (rem + d * 12)) * 255 / 72
            }
            let img = spinnerImages[i]
            guard img < tpl.images.count else { continue }
            let w = Float(tpl.images[img].width), h = Float(tpl.images[img].height)
            d2.image(tpl, img, x: x - 0.5 * 0.6 * w, y: PortraitSlots.pixelCentre(280) - 0.5 * 0.6 * h, sx: 0.6, sy: 0.6,
                     color: SIMD4(255, 255, 255, UInt8(max(0, min(255, a)))), key: "TPLWeather", enc)
            x += 40
        }
    }
}
