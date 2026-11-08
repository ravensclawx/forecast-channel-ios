import Foundation
import Metal
import NW4R
import RVL

/// CMessage (0x18, d_s_weather.cpp): modal message box. Port of CMessage_ctor/Open/Update (fn_8000BED8..fn_8000C0C4)
/// and its draw (fn_8000C2C4).
///   type 1      error3.brlyt — "is this date and time correct?" yes/no, with the current date written into `message`
///   type 0,2,3  error4.brlyt — OK (`next`); text 0 for type 2 (save corrupted), 1 for type 3 (cities changed)
///   type 4,5,6  error2.brlyt — fatal; `next` returns to the Wii Menu; text 1 / 2 / 0
/// State (+10): 0 start fade-in → 1 wait → 2 interactive → 3 after "no" (re-open as type 6) → 4 closing → 5 closed.
public final class Message {
    let ctx: SceneContext
    let fade: Fade                 // +0 (m_pFade)
    let yesNo: UILayout            // +4 error3
    let ok: UILayout               // +8 error4
    let fatal: UILayout            // +C error2
    public private(set) var state = 5    // +10
    public private(set) var type = 0     // +14
    var dateText: [UInt16] = []

    public var isClosed: Bool { state == 5 }

    init(ctx: SceneContext) throws {
        self.ctx = ctx
        fade = ctx.fade
        yesNo = try ctx.layout("error3.brlyt")
        ok = try ctx.layout("error4.brlyt")
        fatal = try ctx.layout("error2.brlyt")
        Message.arrangePortrait(yesNo: yesNo, ok: ok, fatal: fatal)
        open(0); state = 5
    }

    /// CMessage_Open(type)
    public func open(_ t: Int) {
        state = 0; type = t
        yesNo.reset(); ok.reset(); fatal.reset()
        yesNo.find("yes")?.keepPressed = true; yesNo.find("no")?.keepPressed = true
        ok.find("next")?.keepPressed = true; fatal.find("next")?.keepPressed = true
        if t == 1 { dateText = Message.formatDate(ctx) }
    }

    /// iPhone portrait: backgrounds cover the screen; each dialog stays one compact group, centred on screen
    /// (the original's layout around the 456 screen's centre lands at the tall screen's centre).
    static func arrangePortrait(yesNo: UILayout, ok: UILayout, fatal: UILayout) {
        guard PortraitArrange.on else { return }
        for ui in [yesNo, ok, fatal] { PortraitArrange.stretchBackgrounds(ui) }
        // No Wii Menu on the iPhone: the fatal box's button retries (the shell reboots the channel) and its
        // texts don't mention the Wii.
        PortraitArrange.setText(fatal, "nextTUS", "Try Again")
        PortraitArrange.setText(fatal, "textTUS1", "The saved settings couldn't be read.\nPlease try again.")
    }

    /// CMessage_Update
    public func update() {
        yesNo.update(); ok.update(); fatal.update()
        switch state {
        case 0:
            fade.startFadeIn(0x1E); state = 1
        case 1:
            if fade.isIdle { state = 2 }
        case 2:
            if type < 4 {
                if type == 1 {
                    ctx.ui.updateHover(yesNo, ctx.pad)
                    if ctx.ui.buttonTrig("yes", ctx.pad) { fade.startFadeOut(0x1E); state = 4; ctx.playSE(0x1A) }
                    else if ctx.ui.buttonTrig("no", ctx.pad) { fade.startFadeOut(0x1E); state = 3; ctx.playSE(0x1B) }
                } else {
                    ctx.ui.updateHover(ok, ctx.pad)
                    if ctx.ui.buttonTrig("next", ctx.pad) { fade.startFadeOut(0x1E); state = 4; ctx.playSE(0x1A) }
                }
            } else if type < 7 {
                ctx.ui.updateHover(fatal, ctx.pad)
                if ctx.ui.buttonTrig("next", ctx.pad) { ctx.playSE(0x1A); ctx.returnToWiiMenu = true }
            }
        case 3:
            if fade.isIdle { fade.startFadeIn(0x1E); state = 2; type = 6 }
        case 4:
            if fade.isIdle { state = 5 }
        default: break
        }
    }

    /// fn_8000C2C4
    func draw(_ enc: MTLRenderCommandEncoder, _ d2: SceneDraw2D) {
        if type < 4 {
            if type != 1 {
                if let t = ok.find("text") { t.textIndex = type == 3 ? 1 : 0; t.pendingTextIndex = t.textIndex }
                ok.draw(ctx.lyt, enc)
            } else {
                yesNo.draw(ctx.lyt, enc)
                // The date/time line, white, centred in the `message` bounding pane, system font.
                if let m = yesNo.find("message"), let font = Message.systemFont(ctx) {
                    let cx = (m.hitRect.x + m.hitRect.z) * 0.5, cy = (m.hitRect.y + m.hitRect.w) * 0.5
                    let x = cx + 0.5 * ctx.screenWidth, y = LogicalScreen.halfHeight - cy   // as fn_8000C2C4: no wide rescale
                    d2.text(dateText, font: font, x: x, y: y, color: SIMD4(255, 255, 255, 255), enc)
                }
            }
        } else if type < 7 {
            if let t = fatal.find("text") { t.textIndex = [4: 1, 5: 2, 6: 0][type] ?? 0; t.pendingTextIndex = t.textIndex }
            fatal.draw(ctx.lyt, enc)
        }
    }

    /// The channel uses the console's system font (wbf1.brfna, ArchiveFont) for free text. It is not part of the
    /// channel's title data; the port substitutes the channel's own city-name font.
    static func systemFont(_ ctx: SceneContext) -> ResFont? {
        ctx.assets.systemFont() ?? ctx.assets.font("font_weather_city.brfnt.LZ")
    }

    /// fn_8000C4F4: date/time string. Region 1 + language 1 (US English) uses the format at lbl_80199018+0x16C
    /// with (month, day, year, hour, minute). The wide format string is read from main.dol at runtime.
    static func formatDate(_ ctx: SceneContext) -> [UInt16] {
        let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: Date())
        let args = [c.month ?? 1, c.day ?? 1, c.year ?? 2000, c.hour ?? 0, c.minute ?? 0]
        guard let dol = try? ctx.assets.title.content(index: Assets.Content.mainDol.rawValue),
              let off = DOLImage(dol).offset(0x8019_9018 + 0x16C) else { return Array("\(args[0])/\(args[1])/\(args[2]) \(args[3]):\(String(format: "%02d", args[4]))".utf16) }
        let r = BEReader(dol)
        var fmt: [UInt16] = []
        var p = off
        while p + 1 < dol.count, r.u16(p) != 0, fmt.count < 0x40 { fmt.append(r.u16(p)); p += 2 }
        return swprintf(fmt, args)
    }

    /// Minimal swprintf: %d, %0Nd, %Nd, %%.
    static func swprintf(_ fmt: [UInt16], _ args: [Int]) -> [UInt16] {
        var out: [UInt16] = [], i = 0, a = 0
        while i < fmt.count {
            let ch = fmt[i]
            if ch != 0x25 { out.append(ch); i += 1; continue }
            i += 1
            if i < fmt.count, fmt[i] == 0x25 { out.append(0x25); i += 1; continue }
            var zero = false, width = 0
            if i < fmt.count, fmt[i] == 0x30 { zero = true; i += 1 }
            while i < fmt.count, (0x30...0x39).contains(fmt[i]) { width = width * 10 + Int(fmt[i] - 0x30); i += 1 }
            while i < fmt.count, [0x6C, 0x68].contains(fmt[i]) { i += 1 }   // l / h
            if i < fmt.count { i += 1 }
            var s = String(a < args.count ? args[a] : 0); a += 1
            while s.count < width { s = (zero ? "0" : " ") + s }
            out += Array(s.utf16)
        }
        return out
    }
}
