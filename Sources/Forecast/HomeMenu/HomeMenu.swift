import Foundation
import Metal
import NW4R
import RVL
import simd

/// HBMGetSelectBtnNum: 0 close, 1 Wii Menu, 2 Reset, 3 Operations Guide (fn_8002D6F8 → manual).
public enum HomeMenuEvent: Equatable { case closed, returnToWiiMenu, reset, manual }

/// Port of the RVL SDK HOME Button Menu as linked into the Forecast Channel (decomp/notes/homemenu.md).
/// Layout th_HomeBtn_c (HomeButton3, English archive), anims bound to layout groups, HOMESE sounds.
public final class HomeMenu {
    /// An animation bound to one layout group (lyt BindAnimation on the group's panes + their materials).
    final class GroupAnim {
        let anim: LytAnimation
        let panes: Set<String>, materials: Set<String>
        var frame: Float = 0
        var playing = false
        var loop = false
        init(_ anim: LytAnimation, _ groupPanes: [Pane]) {
            self.anim = anim
            // Pane::BindAnimation(anim, recursive) on each group member: members and their descendants.
            var panes: [Pane] = []
            for g in groupPanes { g.forEach { panes.append($0) } }
            self.panes = Set(panes.map(\.name))
            var mats = Set<String>()
            for p in panes {
                if let m = (p as? Picture)?.material ?? (p as? TextBox)?.material ?? (p as? Window)?.material { mats.insert(m.name) }
            }
            materials = mats
        }
        var end: Float { Float(max(anim.frameSize - 1, 0)) }
    }

    enum State { case closed, opening, idle, dialog, connect, finishing }

    public private(set) var isActive = false
    public let isWide: Bool
    public var language: HBMMessages.Language = .english
    /// HBMDataInfo +0x24: big buttons that ask for confirmation (Wii Menu, Reset).
    public var confirmMask: UInt32 = 0b11
    public var hasNewMail = false

    let layout: Layout
    let renderer: LytRenderer
    let sound: SoundManager?
    let messages: HBMMessages?
    let cursor: Cursor?

    private var btnAnims: [GroupAnim?] = []        // 12: (in, out, psh) × 4
    private var oneToOne: [String: GroupAnim] = [:]
    private var pairAnims: [GroupAnim?] = []       // 74
    private var all: [GroupAnim] = []

    private(set) var state: State = .closed
    private var hovered: Int = -1                  // index into hit list
    private var panelOpen = false
    private var vibration = true
    private var volume = 10                        // speaker volume level 0..10
    private var pendingSelect: Int = 0             // HBMGetSelectBtnNum: 0 close, 1 Wii Menu, 2 Reset
    private var finishAnim: GroupAnim?
    private var connectTimer = 0
    private var dialogButton = -1
    private var refreshPanelState = false

    /// iPhone portrait: per-pane transform applied on top of the authored / animated values (see PortraitXform).
    private var portrait: [String: PortraitXform] = [:]
    /// iPhone: the HOME icon (the menu's own th_homeBtnImg_a) the shell draws in the status-bar band to open the menu.
    private var homeIconTex: MTLTexture?
    private var homeIconSize = SIMD2<Float>(0, 0)

    // backdrop / blackout pipeline
    private var blit: MTLRenderPipelineState?
    private var noDepth: MTLDepthStencilState?
    private var blackout: Float = 0

    public init(assets: Assets, renderer: LytRenderer, sound: SoundManager?, isWide: Bool) throws {
        self.isWide = isWide; self.renderer = renderer; self.sound = sound
        let lang = try assets.hbmArchive("_ENG")
        let base = try? assets.hbmArchive("")
        guard let ld = lang.file("/arc/blyt/\(HBMTables.layoutName)") else { throw RVLError.missing(HBMTables.layoutName) }
        layout = try Layout(ld)
        messages = HBMMessages.load(assets)

        // Resource accessor: textures/fonts from the language archive, then the shared one.
        let prevTex = renderer.textureProvider, prevFont = renderer.fontProvider
        var tplCache: [String: TPLFile.Image] = [:]
        renderer.textureProvider = { name in
            if let t = tplCache[name] { return t }
            for a in [lang, base].compactMap({ $0 }) {
                if let d = a.file("/arc/timg/\(name)"), let t = try? TPLFile(d), let img = t.images.first { tplCache[name] = img; return img }
            }
            return prevTex(name)
        }
        var fontCache: [String: ResFont] = [:]
        renderer.fontProvider = { name in
            if let f = fontCache[name] { return f }
            if let d = lang.file("/arc/font/\(name)"), let f = try? ResFont(d) { fontCache[name] = f; return f }
            return prevFont(name)
        }
        cursor = try? Cursor(assets: assets, renderer: renderer)

        func loadAnim(_ suffix: String) -> LytAnimation? {
            let path = "/arc/anim/\(HBMTables.animPrefix)_\(suffix).brlan"
            for a in [base, lang].compactMap({ $0 }) { if let d = a.file(path), let an = try? LytAnimation(d) { return an } }
            return nil
        }
        var cache: [String: LytAnimation] = [:]
        func anim(_ s: String) -> LytAnimation? { if let a = cache[s] { return a }; let a = loadAnim(s); cache[s] = a; return a }
        func bind(_ suffix: String, _ group: String) -> GroupAnim? {
            guard let a = anim(suffix), let panes = layout.groups[group] else { return nil }
            let g = GroupAnim(a, panes); all.append(g); return g
        }
        btnAnims = HBMTables.btnPairs.map { bind(HBMTables.btnAnimSuffix[$0.1], HBMTables.btnGroups[$0.0]) }
        for n in HBMTables.oneToOne { if let g = bind(n, n) { oneToOne[n] = g } }
        pairAnims = HBMTables.pairs.map { bind(HBMTables.anims[$0.1], HBMTables.groups[$0.0]) }
        oneToOne["ltrIcn_on"]?.loop = true

        if LogicalScreen.isPortrait { setupPortrait() }
        // The HOME Menu's own house icon (th_homeBtnImg_a — the one beside "Close"); homeBtnIcon.tpl is the SDK's
        // "HOME Menu unavailable" (prohibited) icon and does not fit.
        if let d = lang.file("/arc/timg/th_homeBtnImg_a.tpl") ?? base?.file("/arc/timg/th_homeBtnImg_a.tpl"),
           let t = try? TPLFile(d), let img = t.images.first {
            let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: img.width, height: img.height, mipmapped: false)
            if let tex = renderer.gx.device.makeTexture(descriptor: td) {
                tex.replace(region: MTLRegionMake2D(0, 0, img.width, img.height), mipmapLevel: 0, withBytes: img.rgba8, bytesPerRow: img.width * 4)
                homeIconTex = tex; homeIconSize = SIMD2(Float(img.width), Float(img.height))
            }
        }

        blit = try? HomeMenu.makeBlit(renderer.gx.device)
        let dd = MTLDepthStencilDescriptor(); dd.depthCompareFunction = .always; dd.isDepthWriteEnabled = false
        noDepth = renderer.gx.device.makeDepthStencilState(descriptor: dd)
    }

    // MARK: anim helpers

    private func pair(_ group: Int, _ anim: Int) -> GroupAnim? {
        guard let i = HBMTables.pairs.firstIndex(where: { $0.0 == group && $0.1 == anim }) else { return nil }
        return pairAnims[i]
    }
    @discardableResult private func play(_ g: GroupAnim?) -> GroupAnim? {
        guard let g else { return nil }
        g.frame = 0; g.playing = true
        apply(g)
        return g
    }
    /// Jump an anim to its last frame (static state display).
    private func show(_ g: GroupAnim?) { guard let g else { return }; g.frame = g.end; g.playing = false; apply(g) }
    private func se(_ s: HBMTables.SE) { sound?.playHomeSE(s.rawValue) }

    private func apply(_ g: GroupAnim) {
        for c in g.anim.contents {
            if c.isMaterial {
                guard g.materials.contains(c.name), let m = layout.materials.first(where: { $0.name == c.name }) else { continue }
                for info in c.infos { for t in info.targets { HomeMenu.applyMaterial(info.kind, t, m, LytAnimation.evaluate(t, frame: g.frame), g.anim) } }
            } else {
                guard g.panes.contains(c.name), let p = layout.find(c.name) else { continue }
                let x = portrait[c.name]
                for info in c.infos {
                    for t in info.targets {
                        var v = LytAnimation.evaluate(t, frame: g.frame)
                        if let x, info.kind == "RLPA" {
                            switch t.target { case 0: v += x.dx; case 1: v = v * x.ty + x.dy; case 7: v *= x.sy; default: break }
                        }
                        HomeMenu.applyPane(info.kind, t, p, v, g.anim)
                    }
                }
            }
        }
    }

    static func u8(_ v: Float) -> UInt8 { UInt8(max(0, min(255, v + 0.5))) }
    static func applyPane(_ kind: String, _ t: LytAnimation.Target, _ p: Pane, _ v: Float, _ a: LytAnimation) {
        switch kind {
        case "RLPA":
            switch t.target {
            case 0: p.translate.x = v; case 1: p.translate.y = v; case 2: p.translate.z = v
            case 3: p.rotate.x = v; case 4: p.rotate.y = v; case 5: p.rotate.z = v
            case 6: p.scale.x = v; case 7: p.scale.y = v
            case 8: p.size.x = v; case 9: p.size.y = v
            default: break
            }
        case "RLVC":
            if t.target == 16 { p.alpha = u8(v); return }
            let corner = Int(t.target / 4), ch = Int(t.target % 4)
            if let pic = p as? Picture, corner < 4 { pic.vtxColors[corner][ch] = u8(v) }
            else if let w = p as? Window, corner < 4 { w.vtxColors[corner][ch] = u8(v) }
        case "RLVI": p.visible = v != 0
        default:
            if let m = (p as? Picture)?.material ?? (p as? TextBox)?.material ?? (p as? Window)?.material { applyMaterial(kind, t, m, v, a) }
        }
    }
    static func applyMaterial(_ kind: String, _ t: LytAnimation.Target, _ m: LytMaterial, _ v: Float, _ a: LytAnimation) {
        switch kind {
        case "RLMC":
            let ch = Int(t.target % 4)
            switch t.target {
            case 0..<4: var c = m.matColor ?? SIMD4(255, 255, 255, 255); c[ch] = u8(v); m.matColor = c
            case 4..<16: m.tevColors[Int(t.target - 4) / 4][ch] = Int32(max(-1024, min(1023, v.rounded())))
            case 16..<32: m.tevKColors[Int(t.target - 16) / 4][ch] = Int32(u8(v))
            default: break
            }
        case "RLTS":
            let i = Int(t.index)
            guard i < m.texSRTs.count else { return }
            switch t.target {
            case 0: m.texSRTs[i].translate.x = v; case 1: m.texSRTs[i].translate.y = v
            case 2: m.texSRTs[i].rotate = v
            case 3: m.texSRTs[i].scale.x = v; case 4: m.texSRTs[i].scale.y = v
            default: break
            }
        case "RLTP": m.texturePatternOverride[Int(t.index)] = a.textureNames[safe: Int(v)]
        default: break
        }
    }

    private var busy: Bool { all.contains { $0.playing && !$0.loop } }

    private func setPane(_ name: String, visible: Bool) { layout.find(name)?.visible = visible }

    // MARK: open / close

    /// HBM state 0: HOME pressed.
    public func open() {
        isActive = true; state = .opening
        hovered = -1; panelOpen = false; pendingSelect = 0; blackout = 0; dialogButton = -1
        for g in all { g.playing = false }
        // No captured-background flag in this channel: back_00 (dimmer) on, back_02 off.
        setPane("back_00", visible: true); setPane("back_02", visible: false)
        // Initial static states: buttons out, panel closed, dialog hidden.
        for i in 0..<3 { show(btnAnims[i * 3 + 1]) }
        show(oneToOne["cntrl_dwn"]); show(pair(5, 3))
        show(oneToOne["cmn_msg_out"]); show(oneToOne["link_msg_out"])
        show(pair(17, 12)); show(pair(18, 12))
        for g in 6...10 { show(pair(g, 7)) }
        showSettingsState()
        setPane("let_icn_00", visible: hasNewMail)
        if hasNewMail { play(oneToOne["ltrIcn_on"]) }
        play(pair(0, 0))   // hmMenu_strt
        se(.homeButton)
    }

    /// Volume bars (vol_xx: sound_ylw lit / sound_gry unlit), battery icons (P1 present, P2-4 absent), rumble selection.
    private func showSettingsState() {
        for i in 0..<10 { show(pair(21 + i, i < volume ? 10 : 9)) }
        show(pair(31, 17)); for p in 32...34 { show(pair(p, 16)) }
        if vibration { show(pair(14, 8)) } else { show(pair(13, 8)); show(pair(14, 6)) }
    }

    private func beginFinish(select: Int, sound s: HBMTables.SE?) {
        if let s { se(s) }
        pendingSelect = select
        state = .finishing
        finishAnim = play(pair(1, 1))   // hmMenu_fnsh
    }

    // MARK: input

    /// Logical px (y down) → layout space (origin center, y up).
    /// With HBMSetAdjustFlag(wide) the 608-wide layout is stretched across 832 logical px, so x scales by 608/832.
    private func layoutPoint(_ p: SIMD2<Float>) -> SIMD2<Float> {
        isWide ? SIMD2((p.x - 416) * (608.0 / 832.0), 228 - p.y) : SIMD2(p.x - 304, LogicalScreen.halfHeight - p.y)
    }

    private func hit(_ name: String, _ pt: SIMD2<Float>) -> Bool {
        guard let b = layout.find(name) else { return false }
        var q: Pane? = b
        while let x = q { if !x.visible { return false }; q = x.parent }
        let inv = b.globalMtx.inverse
        let l = inv * SIMD4(pt.x, pt.y, 0, 1)
        let o = b.vertexOrigin
        return l.x >= o.x && l.x <= o.x + b.size.x && l.y <= o.y && l.y >= o.y - b.size.y
    }

    /// fn_8007AEC8: returns the index of the pane under the pointer (big buttons, then the fixed list).
    private func hitTest(_ pt: SIMD2<Float>) -> Int {
        if state == .dialog {
            for (i, n) in HBMTables.dialogButtons.enumerated() where hit(n, pt) { return 100 + i }
            return -1
        }
        for (i, n) in HBMTables.bigButtons.enumerated() where hit(n, pt) { return i }
        for (i, n) in HBMTables.bounds.enumerated() {
            if i >= 2 && i != 7 && !panelOpen { continue }   // option buttons only while the panel is open
            if LogicalScreen.isPortrait && i != 0 { continue }   // iPhone: no Wii Remote settings bar / panel
            if hit(n, pt) { return 10 + i }
        }
        return -1
    }

    private func hoverChanged(from old: Int, to new: Int) {
        func inOut(_ idx: Int, _ entering: Bool) {
            switch idx {
            case 0..<3: play(btnAnims[idx * 3 + (entering ? 0 : 1)])
            case 10: play(oneToOne[entering ? "hmMenu_bar_in" : "hmMenu_bar_out"])
            case 11: play(entering ? pair(4, panelOpen ? 19 : 2) : pair(5, panelOpen ? 20 : 3))
            case 12...16: play(pair(6 + (idx - 12), entering ? 4 : 7))
            case 100, 101: play(pair(17 + (idx - 100), entering ? 11 : 12))
            default: break
            }
        }
        if old >= 0 { inOut(old, false) }
        if new >= 0 { inOut(new, true); se(.focus) }
    }

    /// HBMCalc + input. Returns an event once the menu has finished.
    public func update(pad: KPad) -> HomeMenuEvent? {
        guard isActive else { return nil }
        layout.root.calculate(parentMtx: matrix_identity_float4x4, parentAlpha: 255, locationAdjust: isWide ? SIMD2(1 / 1.368_421_1, 1) : nil)
        for g in all where g.playing {
            g.frame += 1
            if g.frame >= g.end { if g.loop { g.frame = 0 } else { g.frame = g.end; g.playing = false } }
            apply(g)
        }
        let pt = layoutPoint(pad.pointer)
        if refreshPanelState && !busy { refreshPanelState = false; showSettingsState() }

        switch state {
        case .closed: return nil
        case .opening:
            if !busy { state = .idle }
        case .idle:
            let h = pad.pointerValid ? hitTest(pt) : -1
            if h != hovered { hoverChanged(from: hovered, to: h); hovered = h }
            if pad.trig.contains(.home) { beginFinish(select: 0, sound: .returnApp); break }
            if pad.trig.contains(.b) {
                if panelOpen { togglePanel() } else { beginFinish(select: 0, sound: .returnApp) }
                break
            }
            if panelOpen && (pad.trig.contains(.minus) || pad.trig.contains(.plus)) {
                changeVolume(pad.trig.contains(.plus) ? 1 : -1)
            }
            if pad.trig.contains(.a) && h >= 0 { press(h) }
        case .dialog:
            let h = pad.pointerValid ? hitTest(pt) : -1
            if h != hovered { hoverChanged(from: hovered, to: h); hovered = h }
            if pad.trig.contains(.b) { closeDialog(); break }
            if pad.trig.contains(.a) && h >= 100 {
                if h == 100 {                    // Yes
                    play(pair(19, 13))
                    let sel = dialogButton + 1
                    play(oneToOne["cmn_msg_rtrn"])
                    beginFinish(select: sel, sound: sel == 1 ? .gotoMenu : .resetApp)
                } else {
                    play(pair(20, 13)); se(.cancel); closeDialog()
                }
            }
        case .connect:
            connectTimer -= 1
            if connectTimer <= 0 || pad.trig.contains(.b) || pad.trig.contains(.a) {
                play(oneToOne["link_msg_out"]); se(.endConnectWindow)
                for p in 0..<4 { setPane(String(format: "N_plyr_%02d", p), visible: true) }
                state = .idle
            }
        case .finishing:
            if pendingSelect != 0 { blackout = min(1, (finishAnim.map { $0.frame / max($0.end, 1) } ?? 1)) }
            if !(finishAnim?.playing ?? false) {
                isActive = false; state = .closed
                for g in all { g.playing = false }
                switch pendingSelect {
                case 1: return .returnToWiiMenu
                case 2: return .reset
                case 3: return .manual
                default: return .closed
                }
            }
        }
        return nil
    }

    private func press(_ h: Int) {
        switch h {
        case 0..<3:   // big buttons: Wii Menu, Reset, (third)
            play(btnAnims[h * 3 + 2]); se(.select)
            if confirmMask & (1 << UInt32(h)) != 0 {
                dialogButton = h
                if let t = layout.find("T_Dialog") as? TextBox { t.setString(messages?.message(row: h + 2, language: language) ?? "") }
                play(oneToOne["cmn_msg_in"]); play(pair(17, 11)); play(pair(18, 11))
                hoverChanged(from: hovered, to: -1); hovered = -1
                state = .dialog
            } else {
                beginFinish(select: h + 1, sound: nil)
            }
        case 10:      // top bar: back to the channel
            play(oneToOne["hmMenu_bar_psh"])
            beginFinish(select: 0, sound: .returnApp)
        case 11, 17:  // bottom bar / Wii Remote picture: settings panel
            togglePanel()
        case 12: play(pair(11, 5)); changeVolume(-1)
        case 13: play(pair(12, 5)); changeVolume(1)
        case 14:      // vibration on
            if !vibration { vibration = true; play(pair(14, 8)); play(pair(16, 6)); se(.vibeOn) } else { se(.nothingDone) }
        case 15:      // vibration off
            if vibration { vibration = false; play(pair(13, 8)); play(pair(14, 6)); se(.vibeOff) } else { se(.nothingDone) }
        case 16:      // connect window
            play(pair(15, 5)); se(.select); se(.startConnectWindow)
            for p in 0..<4 { setPane(String(format: "N_plyr_%02d", p), visible: false) }
            if let t = layout.find("T_msg_00") as? TextBox { t.setString(messages?.message(row: 0, language: language) ?? "") }
            if let t = layout.find("T_msg_01") as? TextBox { t.setString(messages?.message(row: 1, language: language) ?? "") }
            play(oneToOne["link_msg_in"])
            connectTimer = 180
            state = .connect
        default: break
        }
    }

    private func togglePanel() {
        if panelOpen {
            panelOpen = false
            play(oneToOne["close_bar_psh"]); play(oneToOne["cntrl_dwn"]); play(pair(5, 20))
            for g in 6...10 { play(pair(g, 7)) }
            se(.closeController)
        } else {
            panelOpen = true
            play(oneToOne["optn_bar_psh"]); play(oneToOne["cntrl_up"]); play(oneToOne["cntrl_wndw_opn"]); play(pair(4, 19))
            refreshPanelState = true
            for g in 6...10 { play(pair(g, 4)) }
            se(.select); se(.openController)
        }
        hovered = -1
    }

    private func changeVolume(_ d: Int) {
        if (d < 0 && volume == 0) || (d > 0 && volume == 10) { se(.nothingDone); return }
        if d < 0 {
            volume -= 1; play(pair(21 + volume, 9))
            se(volume == 0 ? .volumeMinusLimit : .volumeMinus)
        } else {
            play(pair(21 + volume, 10)); volume += 1
            se(volume == 10 ? .volumePlusLimit : .volumePlus)
        }
    }

    private func closeDialog() {
        play(oneToOne["cmn_msg_out"]); play(pair(17, 12)); play(pair(18, 12))
        dialogButton = -1; hovered = -1
        state = .idle
    }

    // MARK: iPhone portrait

    /// Additive / multiplicative pane transform applied over authored and animated values.
    struct PortraitXform { var dx: Float = 0; var dy: Float = 0; var ty: Float = 1; var sy: Float = 1 }

    /// HOME Menu in portrait: header bar under the safe area (its colour continues up behind the status bar), the
    /// three big buttons stacked in the middle, the Wii Remote settings bar and controller picture hidden, the
    /// backdrops and the confirm dialog's off-screen rest position scaled to the tall screen.
    private func setupPortrait() {
        let half = LogicalScreen.halfHeight
        let k = LogicalScreen.height / 456
        // bar_00 (origin top-centre) rests at its top edge = 228 (screen top); in portrait its top edge sits at the
        // safe-area line, and the hidden position (+310) scales so it still starts off-screen.
        let barDy = PortraitSlots.safeTopY - 228 * 1
        portrait["bar_00"] = PortraitXform(dy: barDy)
        // Big buttons: no "Wii Menu" on the iPhone (there is no Wii Menu to return to); Reset and Operations Guide
        // stacked 150 apart, centred on screen. (Parent N_cntBtn_all sits at y −22; targets +75 / −75.)
        for (n, d) in [("N_btnL_01", SIMD2<Float>(-138, -3)), ("N_btnL_10", SIMD2<Float>(0, -29))] {
            portrait[n] = PortraitXform(dx: d.x, dy: d.y)
            portrait["B" + n.dropFirst(1)] = PortraitXform(dx: d.x, dy: d.y)    // B_btnL_xx hit bounds
        }
        // Dialog: slides from +500 (off-screen above) to 0 — scale the travel so it still starts off-screen.
        portrait["N_Dialog"] = PortraitXform(ty: k)
        for n in ["back_00", "back_01", "back_02"] { portrait[n] = PortraitXform(sy: k) }
        _ = half
        for (name, x) in portrait {
            guard let p = layout.find(name) else { continue }
            p.translate.x += x.dx; p.translate.y = p.translate.y * x.ty + x.dy; p.scale.y *= x.sy
        }
        layout.find("N_btnL_00")?.visible = false
        layout.find("B_btnL_00")?.visible = false
        // No Wii Remote on the iPhone.
        layout.find("bar_10")?.visible = false
        layout.find("N_cntrl_01")?.visible = false
    }

    /// The black header bar continues up behind the status bar / Dynamic Island.
    private func drawTopBarFill(_ enc: MTLRenderCommandEncoder) {
        guard let bar = layout.find("bar_00"), bar.visible else { return }
        layout.root.calculate(parentMtx: matrix_identity_float4x4, parentAlpha: 255, locationAdjust: nil)
        let topEdge = bar.globalMtx.columns.3.y                       // origin top-centre
        let y1 = LogicalScreen.halfHeight - topEdge                       // pixels, y down
        guard y1 > 0 else { return }
        let a = UInt8(Float(bar.alpha) * Float(layout.root.alpha) / 255)
        renderer.drawScreenRect(x0: 0, y0: 0, x1: 608, y1: y1 + 1, color: SIMD4(0, 0, 0, a), screenWidth: 608, enc)
    }

    /// Where the shell draws the HOME icon (logical px, y down): the status-bar band, left of the Dynamic Island.
    public var homeIconRect: SIMD4<Float> {
        let s: Float = 0.75
        let w = max(homeIconSize.x, 1) * s, h = max(homeIconSize.y, 1) * s
        let cy = max(LogicalScreen.safeTop * 0.5, h * 0.5 + 6), x0: Float = 34
        return SIMD4(x0, cy - h / 2, x0 + w, cy + h / 2)
    }
    /// Touch slop around the icon (finger-sized target).
    public func homeIconHit(_ p: SIMD2<Float>) -> Bool {
        let r = homeIconRect, m: Float = 24
        return p.x >= r.x - m && p.x <= r.z + m && p.y >= r.y - m && p.y <= r.w + m
    }
    /// Draw the HOME icon (hidden while the menu is open). `pressed` dims it while the finger is on it.
    public func drawHomeIcon(_ enc: MTLRenderCommandEncoder, pressed: Bool = false) {
        guard !isActive, let tex = homeIconTex else { return }
        let r = homeIconRect
        let c: SIMD4<UInt8> = pressed ? SIMD4(170, 170, 170, 255) : SIMD4(255, 255, 255, 230)
        renderer.drawScreenQuad(tex, x: r.x, y: r.y, w: r.z - r.x, h: r.w - r.y, color: c, screenWidth: 608, enc)
    }

    // MARK: draw

    /// Draws the frozen game frame (optional), the HOME Menu layout, cursor and the exit blackout.
    public func draw(_ enc: MTLRenderCommandEncoder, backgroundTexture: MTLTexture?, pad: KPad? = nil) {
        guard isActive else { return }
        let w: Float = isWide ? 832 : 608
        if let bg = backgroundTexture { fullscreen(enc, texture: bg, color: SIMD4(1, 1, 1, 1)) }
        // HBMDataInfo.adjust = (1.3684211, 1) + HBMSetAdjustFlag(wide): the layout's own 608 width is stretched to the
        // screen and location-adjust panes (the buttons) are counter-scaled, as nw4r DrawInfo does for CLayout.
        if LogicalScreen.isPortrait { drawTopBarFill(enc) }
        renderer.draw(layout, enc, screenWidth: 608, locationAdjust: isWide ? SIMD2(1 / 1.368_421_1, 1) : nil)
        if let pad, let c = cursor, pad.pointerValid { c.state = .normal; c.draw(renderer, enc, pointer: pad.pointer, twist: pad.twist, screenWidth: w) }
        if blackout > 0 { fullscreen(enc, texture: nil, color: SIMD4(0, 0, 0, blackout)) }
    }

    private func fullscreen(_ enc: MTLRenderCommandEncoder, texture: MTLTexture?, color: SIMD4<Float>) {
        guard let blit else { return }
        enc.setRenderPipelineState(blit)
        if let noDepth { enc.setDepthStencilState(noDepth) }
        var c = color, useTex: Int32 = texture == nil ? 0 : 1
        enc.setFragmentBytes(&c, length: 16, index: 0)
        enc.setFragmentBytes(&useTex, length: 4, index: 1)
        enc.setFragmentTexture(texture ?? renderer.gx.whiteTexture, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }

    static func makeBlit(_ device: MTLDevice) throws -> MTLRenderPipelineState {
        let src = """
        #include <metal_stdlib>
        using namespace metal;
        struct V { float4 p [[position]]; float2 uv; };
        vertex V hbm_vs(uint id [[vertex_id]]) {
            float2 q = float2(id & 1, id >> 1);
            V o; o.p = float4(q.x * 2 - 1, 1 - q.y * 2, 0, 1); o.uv = q; return o;
        }
        fragment float4 hbm_fs(V in [[stage_in]], constant float4& c [[buffer(0)]], constant int& useTex [[buffer(1)]],
                               texture2d<float> t [[texture(0)]]) {
            constexpr sampler s(filter::linear);
            float4 x = useTex != 0 ? t.sample(s, in.uv) : float4(1);
            return x * c;
        }
        """
        let lib = try device.makeLibrary(source: src, options: nil)
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = lib.makeFunction(name: "hbm_vs"); d.fragmentFunction = lib.makeFunction(name: "hbm_fs")
        d.colorAttachments[0].pixelFormat = .bgra8Unorm
        d.depthAttachmentPixelFormat = .depth32Float
        let ca = d.colorAttachments[0]!
        ca.isBlendingEnabled = true
        ca.sourceRGBBlendFactor = .sourceAlpha; ca.destinationRGBBlendFactor = .oneMinusSourceAlpha
        ca.sourceAlphaBlendFactor = .one; ca.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        return try device.makeRenderPipelineState(descriptor: d)
    }
}
