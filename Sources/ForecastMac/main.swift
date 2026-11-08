import AppKit
import Forecast
import MetalKit

// macOS shell: window + Metal view, and the Wii Remote → mouse/keyboard mapping.
//   pointer      = mouse position       A = left button        B = right button / Esc
//   + / -        = = / -  (or scroll)   d-pad = arrow keys     twist = trackpad rotate gesture
//   reset button (until the layout port lands) = R

final class ForecastView: MTKView {
    var ctx: SceneContext!
    var scene: WeatherScene!
    var sound: SoundManager?
    var cursor: Cursor?
    var homeMenu: HomeMenu?
    var manual: ManualViewer?          // HOME Menu → Operations Guide (fn_8002DDCC)
    var manualWindow: NSWindow?        // WebKit renders only inside a window: an off-screen one
    var queue: MTLCommandQueue!
    var held: WPAD = []
    var pulse: WPAD = []          // one-frame presses (scroll wheel → +/-)
    var pointer = SIMD2<Float>(416, 228)
    var pointerInside = false
    var twist: Float = 0
    var scrollAccum: CGFloat = 0

    /// The 16:9 region the 832x456 logical screen is presented in (anamorphic, as a Wii on a 16:9 TV).
    var presentRect: CGRect {
        let b = bounds, target: CGFloat = 16.0 / 9.0
        if b.width / b.height > target { let w = b.height * target; return CGRect(x: (b.width - w) / 2, y: 0, width: w, height: b.height) }
        let h = b.width / target; return CGRect(x: 0, y: (b.height - h) / 2, width: b.width, height: h)
    }

    override var acceptsFirstResponder: Bool { true }
    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    func track(_ e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil), r = presentRect
        pointer = SIMD2(Float((p.x - r.minX) / r.width * 832), Float((r.maxY - p.y) / r.height * 456))
        pointerInside = r.contains(p)
    }
    override func mouseMoved(with e: NSEvent) { track(e) }
    override func mouseDragged(with e: NSEvent) { track(e) }
    override func rightMouseDragged(with e: NSEvent) { track(e) }
    override func mouseEntered(with e: NSEvent) { track(e); if cursor != nil { NSCursor.hide() } }
    override func mouseExited(with e: NSEvent) { pointerInside = false; if cursor != nil { NSCursor.unhide() } }
    override func mouseDown(with e: NSEvent) { track(e); held.insert(.a) }
    override func mouseUp(with e: NSEvent) { held.remove(.a) }
    override func rightMouseDown(with e: NSEvent) { held.insert(.b) }
    override func rightMouseUp(with e: NSEvent) { held.remove(.b) }
    override func rotate(with e: NSEvent) { twist -= e.rotation }
    override func scrollWheel(with e: NSEvent) {
        scrollAccum += e.scrollingDeltaY * (e.hasPreciseScrollingDeltas ? 0.05 : 1)
        // In the manual the wheel stands in for the +Control Pad (scroll); elsewhere for +/−.
        let inManual = manual?.isActive ?? false
        if scrollAccum > 1 { pulse.insert(inManual ? .up : .plus); scrollAccum = 0 }
        else if scrollAccum < -1 { pulse.insert(inManual ? .down : .minus); scrollAccum = 0 }
    }
    func key(_ e: NSEvent) -> WPAD? {
        switch e.keyCode {
        case 126: return .up
        case 125: return .down
        case 123: return .left
        case 124: return .right
        case 24, 69: return .plus     // = / keypad +
        case 27, 78: return .minus    // - / keypad -
        case 53: return .b            // Esc
        case 36: return .a            // Return
        case 18: return .one
        case 19: return .two
        case 4: return .home          // H
        default: return nil
        }
    }
    override func keyDown(with e: NSEvent) {
        if let k = key(e) { held.insert(k) }
    }
    override func keyUp(with e: NSEvent) { if let k = key(e) { held.remove(k) } }

    /// HBMGetSelectBtnNum() == 3: the Operations Guide (created on first use; it keeps its last page between opens).
    func openManual() {
        if manual == nil, let arc = try? ManualArchive(assets: ctx.assets),
           let m = try? ManualViewer(archive: arc, device: device!, language: 1, isWide: true) {
            m.playSE = { [weak self] in self?.sound?.playHomeSE($0) }
            m.cursor = try? ManualCursor(assets: ctx.assets, device: device!)
            let w = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: m.browserSize.width, height: m.browserSize.height),
                             styleMask: [.borderless], backing: .buffered, defer: false)
            w.contentView = m.webView
            w.isReleasedWhenClosed = false
            w.orderBack(nil)
            manual = m; manualWindow = w
        }
        manual?.open()
    }

    override func draw(_ dirtyRect: NSRect) {
        ctx.pad.update(PointerSample(position: pointer, valid: pointerInside, held: held.union(pulse), twistDegrees: twist))
        // fn_8002D6F8: HOME on any remote opens the HOME Menu; the scene Calc pauses while it (or the manual) is active.
        if let m = manual, m.isActive {
            // fn_8002DDCC runs the browser modally; on return the scene fades in over 0xF frames.
            if m.update(pad: ctx.pad) { ctx.fade.startFadeIn(0xF) }
        } else if let hbm = homeMenu, !hbm.isActive, ctx.pad.trig.contains(.home) { hbm.open() }
        if manual?.isActive ?? false {
        } else if let hbm = homeMenu, hbm.isActive {
            switch hbm.update(pad: ctx.pad) {
            case .returnToWiiMenu?: NSApp.terminate(nil)
            case .reset?: if let s = try? WeatherScene(ctx: ctx) { scene = s }   // OSRestart → reboot the scene
            case .manual?: openManual()
            default: break
            }
        } else {
            scene.calc()
            if scene.wantsQuit { NSApp.terminate(nil); return }
        }
        // fn_80041F54, once per game frame — not while the manual runs: fn_80083878 blocks the game loop, so the
        // BGM keeps playing untouched (the HBM restored the AX volumes at finish and skips its fade for button 3).
        if !(manual?.isActive ?? false) { sound?.update() }
        pulse = []
        ctx.gx.beginFrame()
        guard let rpd = currentRenderPassDescriptor, let drawable = currentDrawable, let cb = queue.makeCommandBuffer() else { return }
        let r = presentRect, s = window?.backingScaleFactor ?? 2
        let vp = MTLViewport(originX: Double(r.minX * s), originY: Double((bounds.height - r.maxY) * s),
                             width: Double(r.width * s), height: Double(r.height * s), znear: 0, zfar: 1)
        scene.render(commandBuffer: cb, pass: rpd, viewport: vp)          // System_Frame: scene + transition overlay
        // Overlay pass: HOME Menu or the cursor (CErrorSystem draws after the scene).
        let overlay = MTLRenderPassDescriptor()
        overlay.colorAttachments[0].texture = drawable.texture
        overlay.colorAttachments[0].loadAction = .load; overlay.colorAttachments[0].storeAction = .store
        overlay.depthAttachment.texture = rpd.depthAttachment.texture
        overlay.depthAttachment.loadAction = .clear; overlay.depthAttachment.storeAction = .dontCare
        guard let enc = cb.makeRenderCommandEncoder(descriptor: overlay) else { return }
        enc.setViewport(vp)
        if let m = manual, m.isActive {
            m.draw(enc, pad: ctx.pad)          // the manual draws its own pointer (fn_8007E67C)
        } else if let hbm = homeMenu, hbm.isActive {
            hbm.draw(enc, backgroundTexture: scene.frameTexture, pad: ctx.pad)   // HBM draws its own cursor
        } else if let cursor, pointerInside {
            cursor.state = scene.cursorState
            cursor.draw(ctx.lyt, enc, pointer: ctx.pad.pointer, twist: twist, screenWidth: 832)
        }
        enc.endEncoding()
        cb.present(drawable)
        cb.commit()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    func applicationDidFinishLaunching(_ n: Notification) {
        let device = MTLCreateSystemDefaultDevice()!
        let view = ForecastView(frame: NSRect(x: 0, y: 0, width: 1216, height: 684), device: device)
        view.colorPixelFormat = .bgra8Unorm
        view.depthStencilPixelFormat = .depth32Float
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)   // GXSetCopyClear black
        view.preferredFramesPerSecond = 60
        view.queue = device.makeCommandQueue()
        do {
            let assets = try Assets()
            let sound = try? SoundManager(assets: assets)
            try? sound?.startOutput()
            view.sound = sound
            let ctx = try SceneContext(assets: assets, device: device, colorFormat: view.colorPixelFormat,
                                       depthFormat: view.depthStencilPixelFormat, sound: sound)
            view.ctx = ctx
            view.cursor = try? Cursor(assets: assets, renderer: ctx.lyt)
            view.scene = try WeatherScene(ctx: ctx)
            view.homeMenu = try? HomeMenu(assets: assets, renderer: ctx.lyt, sound: sound, isWide: true)
        } catch {
            let a = NSAlert(); a.messageText = "Could not load the Forecast Channel"; a.informativeText = "\(error)"; a.runModal()
            NSApp.terminate(nil); return
        }
        window = NSWindow(contentRect: view.frame, styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Forecast Channel"
        window.contentView = view
        window.contentAspectRatio = NSSize(width: 16, height: 9)
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
