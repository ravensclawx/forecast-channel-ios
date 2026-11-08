import Foundation
import Metal
import MetalKit
import WebKit
import simd
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// The HOME Menu "Operations Guide": the channel manual the original runs through its Opera-based manual library
/// (WWW* imports, wwwlib-rvl in content 2). Port of the DOL-side wrapper around that browser:
///
///   - CContentArc (0x8002D1D4) keeps the start URL (+0x28) and the *last* URL (+0x2C); fn_8002DDCC runs the browser
///     modally (fn_80083878) and copies the URL it returns back to +0x2C, so reopening resumes at the last page.
///   - fn_8002D6F8: HBMGetSelectBtnNum() == 3 → manual; afterwards the scene fades in over 0xF frames.
///   - Input (fn_800822BC): A = click (WWWSurfaceMouseEvt move/down/up at once), +Control Pad ↑/↓ = wheel ∓1
///     (repeat after 16 frames, then every frame on the 808-px wide surface), − = previous page, + = start page
///     (SE 0x1A unless already there), HOME = close (SE 0x1B). Buttons only act when no page load or transition runs.
///   - Sounds fn_8007E2A8 → HBM SE: 0 → 0x17 FocusSound, 1 → 0x18 select/scroll page, 2 → 0x16 first page shown,
///     3 → 0x1B close, 5 → 0x1A start page; the same id again within 3 frames is dropped.
///   - Display (fn_800809B8): a new page replaces the old one only once it has finished loading, in 15 frames: the old
///     page fades out (255 − 255·t/15) and, after LeftScroll/RightScroll, both slide by 15 % of the width.
///   - Surface 808×456 (wide) / 608×456, stretched across the screen (fn_8002E1A0 clears with black first).
///   - Sound: nothing in fn_8002DDCC touches audio; the HBM finish skips its master-volume fade for button 3
///     (fn_80073E74: `+B0 != 3`) and restores the AX volumes it saved at open, so the BGM keeps playing. The
///     game loop (fn_80041F54 sound update) is blocked while the browser runs.
///   - fn_8002E384 (reset/power callbacks fn_8003F4A4/B8) force-closes a running manual.
///
/// The page engine itself is WebKit (WKWebView, macOS/iOS); the pages, images, CSS and font are the original ones
/// served from memory through the `wiiarc:` scheme. What the user sees is composited in Metal from page snapshots,
/// so transitions, the cursor and the 832-px stretch work as on the console.
public final class ManualViewer: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    public static let scheme = "wiiarc"
    public static let host = "arc"

    public let webView: WKWebView
    public let browserSize: CGSize
    let archive: ManualArchive
    let device: MTLDevice
    let loader: MTKTextureLoader
    let homeURL: URL                                   // lbl_80330DA8 (first URL ever opened)
    /// CContentArc +0x2C: where the next open starts.
    public private(set) var resumeURL: URL
    public private(set) var isActive = false
    /// Played through the HOME Menu sound archive (fn_80072354).
    public var playSE: ((Int) -> Void)?
    /// fn_8007E67C pointer (HOME Menu archive textures); set by the host.
    public var cursor: ManualCursor?
    /// Logical screen width the browser surface is stretched to (832 wide / 608).
    public let screenWidth: Float

    // fn_80082E18 / fn_8007F714 state
    private var frame = 0                              // E70
    private var loading = false                        // DFE: a document is loading
    private var waitingForPage = false                 // DFF/E00: loaded, waiting for its first picture
    private var finishedAt = -1
    private var openCountdown = 2                      // E59
    private var selectFlag = false                     // E38 (SelectSound)
    private var pendingTransition = 0                  // E2C: 0 fade, 1 LeftScroll, 2 RightScroll
    private var transitionT = 15                       // DF0 (15 = idle, lbl_803303E4)
    private var transitionDir: Float = 0               // ±1/15 or 0
    private var repeatAt = 0                           // E7C
    private var lastSE = (id: -1, frame: -100)         // lbl_803303D0 / lbl_80330D80
    private var lastPointer = SIMD2<Float>(-1, -1)
    private var closing = false
    private var lastTopURL: URL?

    // display
    private var current: MTLTexture?                   // E0D
    private var previous: MTLTexture?                  // E0E
    private var snapshotInFlight = false
    private var dirtyFrames = 0                        // live-surface refresh window after input / page activity
    private var snapshotGeneration = 0, navigationGeneration = 0
    private var pipeline: MTLRenderPipelineState?
    private var noDepth: MTLDepthStencilState?

    // iPhone portrait: the browser fills the safe band; one finger scrolls the frame under it; "Close" is tappable.
    public let isPortrait: Bool
    private var browserTop: Float = 0                  // logical px of the browser's top edge
    private var touchTravel: Float = 0, touchDragging = false, touchAt = SIMD2<Float>(0, 0)
    private var flingVel: Float = 0
    private var closeRequested = false
    /// The shell's HOME icon (or the page's Close) closes the manual like the HOME button.
    public func requestClose() { closeRequested = true }

    public init(archive: ManualArchive, device: MTLDevice, language: Int = 1, isWide: Bool = true) throws {
        guard let start = ManualArchive.startPath(language: language) else { throw RVLErrorManual.noManual }
        self.archive = archive
        self.device = device
        loader = MTKTextureLoader(device: device)
        isPortrait = LogicalScreen.isPortrait
        if isPortrait {
            // iPhone portrait: 608 wide (the 4:3 surface) and as tall as the safe band; the frameset's main frame grows.
            browserSize = CGSize(width: 608, height: CGFloat((LogicalScreen.height - LogicalScreen.safeTop - LogicalScreen.safeBottom).rounded()))
            screenWidth = 608
            browserTop = LogicalScreen.safeTop
        } else {
            browserSize = CGSize(width: isWide ? 808 : 608, height: 456)   // fn_80083B44(0x328 / 0x260, 0x1C8)
            screenWidth = isWide ? 832 : 608
        }
        homeURL = URL(string: "\(ManualViewer.scheme)://\(ManualViewer.host)\(start)")!
        resumeURL = homeURL

        let cfg = WKWebViewConfiguration()
        let uc = WKUserContentController()
        let fontURL = "\(ManualViewer.scheme)://\(ManualViewer.host)/__fc/pgothic.ttf"
        uc.addUserScript(WKUserScript(source: ManualScript.ext(fontURL: fontURL, portrait: LogicalScreen.isPortrait), injectionTime: .atDocumentStart, forMainFrameOnly: false))
        uc.addUserScript(WKUserScript(source: ManualScript.host, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        cfg.userContentController = uc
        cfg.suppressesIncrementalRendering = true
        let proxy = SchemeProxy()
        cfg.setURLSchemeHandler(proxy, forURLScheme: ManualViewer.scheme)
        cfg.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: CGRect(origin: .zero, size: browserSize), configuration: cfg)
        super.init()
        proxy.target = self
        uc.add(WeakHandler(self), name: "fc")
        webView.navigationDelegate = self
        pipeline = try? ManualViewer.makePipeline(device)
        let dd = MTLDepthStencilDescriptor(); dd.depthCompareFunction = .always; dd.isDepthWriteEnabled = false
        noDepth = device.makeDepthStencilState(descriptor: dd)
    }

    // MARK: open / close

    /// fn_8002DDCC: start the browser at +0x2C.
    public func open() {
        isActive = true; closing = false
        frame = 0; loading = true; waitingForPage = false; finishedAt = -1
        openCountdown = 2; selectFlag = false; pendingTransition = 0
        closeRequested = false; touchDragging = false; flingVel = 0
        transitionT = 15; transitionDir = 0; repeatAt = 0; lastSE = (-1, -100)
        current = nil; previous = nil; lastPointer = SIMD2(-1, -1)
        cursor?.reset()
        navigationGeneration += 1
        webView.load(URLRequest(url: resumeURL))
    }

    /// Returns true on the frame the manual closes (HOME); the caller then fades the scene in (0xF frames).
    public func update(pad: KPad) -> Bool {
        guard isActive else { return false }
        frame += 1
        cursor?.update(pad: pad)
        requestSnapshot()
        if transitionT < 15 { transitionT += 1; if transitionT >= 15 { previous = nil } }
        // E09/DFF: the loaded page waits for its picture before input resumes.
        let idle = !loading && !waitingForPage

        let size = browserSize
        let idleForHover = !loading && !waitingForPage
        let px = Float(size.width) / screenWidth
        let x = max(2, min(Float(size.width) - 2, pad.pointer.x * px))
        let y = max(2, min(Float(size.height) - 2, pad.pointer.y - browserTop))
        if isPortrait {
            touchScroll(pad: pad, x: x, y: y)
            // A lifted finger leaves no pointer: clear the page's rollover state (mouse leaves to the corner).
            if !pad.pointerValid && lastPointer != SIMD2(1, 1) && idleForHover {
                js("window.__fc&&__fc.move(1,1)"); lastPointer = SIMD2(1, 1); dirtyFrames = max(dirtyFrames, 8)
            }
        }

        if idle && pad.pointerValid {
            // fn_80082B64(0): mouse move only when the position changed
            if SIMD2(x, y) != lastPointer { js("window.__fc&&__fc.move(\(x),\(y))"); lastPointer = SIMD2(x, y); dirtyFrames = max(dirtyFrames, 8) }
            // A: move + down + up in one frame (WWWSurfaceMouseEvt 0/1/2)
            if pad.trig.contains(.a) { js("window.__fc&&(__fc.press(\(x),\(y)),__fc.release(\(x),\(y)))"); dirtyFrames = max(dirtyFrames, 8) }
        }
        // Buttons other than A wait for the transition (DF0 == lbl_803303E4).
        if idle && transitionT >= 15 {
            if pad.trig.contains(.plus) {                 // 0x20: back to the start page
                if !sameDocument(lastTopURL, homeURL) { se(5); webView.load(URLRequest(url: homeURL)) }
            } else if pad.trig.contains(.minus) {         // 0x10: previous page (WWWPrevPage)
                if webView.canGoBack { webView.goBack() }
            }
            if pad.trig.contains(.down) { wheel(x, y, 1); repeatAt = frame + 16 }
            else if pad.hold.contains(.down), repeatAt < frame { wheel(x, y, 1); repeatAt = size.width <= 640 ? frame + 1 : frame }
            else if pad.trig.contains(.up) { wheel(x, y, -1); repeatAt = frame + 16 }
            else if pad.hold.contains(.up), repeatAt < frame { wheel(x, y, -1); repeatAt = size.width <= 640 ? frame + 1 : frame }
        }
        js("window.__fc&&__fc.step()")
        // 0x40 HOME: close (fn_8007E2A8(3)), regardless of loading. iPhone: the HOME icon / the page's Close.
        if pad.trig.contains(.home) || closeRequested {
            closeRequested = false
            se(3)
            if let u = webView.url { resumeURL = u }   // fn_80083CA0 returns the current URL → +0x2C
            isActive = false
            webView.stopLoading()
            return true
        }
        return false
    }

    /// Pixels per WWWSurfaceWheelEvt(±1). wwwlib-rvl (content 2, RSO www_no_font.plf): the prefs table entry
    /// "Scroll Step" defaults to 50 ("Scroll Step Handheld" 25 applies to handheld/SSR layout only). The manual sets
    /// WWWSetRenderingMode(6) (fn_80080068 ← lbl_80330E50 = 6), which the RSO's switch (0x6d704) maps to LayoutMode 0,
    /// the normal layout — so the 50-px step applies. Assumed: one wheel unit = one Scroll Step.
    public var wheelStep: Float = 50

    /// iPhone: one finger moves the frame under it with the finger (after an 18 px slop, so taps still click);
    /// on release the page keeps the finger's speed and decays (×0.92 per frame).
    private func touchScroll(pad: KPad, x: Float, y: Float) {
        let g = ctxGestures
        if pad.pointerValid && g.fingers == 1 {
            if !touchDragging { touchTravel += abs(g.dragY); touchAt = SIMD2(x, y) }
            if !touchDragging && touchTravel > 18 { touchDragging = true; flingVel = 0 }
            if touchDragging, g.dragY != 0 {
                js("window.__fc&&__fc.drag(\(touchAt.x),\(touchAt.y),\(g.dragY))"); flingVel = g.dragY; dirtyFrames = max(dirtyFrames, 8)
            }
            return
        }
        touchTravel = 0
        if touchDragging { touchDragging = false }
        if abs(flingVel) > 0.5 {
            flingVel *= 0.92
            js("window.__fc&&__fc.drag(\(touchAt.x),\(touchAt.y),\(flingVel))"); dirtyFrames = max(dirtyFrames, 8)
        } else { flingVel = 0 }
    }
    /// This frame's touch gestures (set by the host each frame on the iPhone).
    public var ctxGestures = TouchInput.Gestures()

    private func wheel(_ x: Float, _ y: Float, _ dir: Int) { dirtyFrames = max(dirtyFrames, 60); js("window.__fc&&__fc.wheel(\(x),\(y),\(dir),\(wheelStep))") }

    private func sameDocument(_ a: URL?, _ b: URL) -> Bool { a?.path == b.path }

    private func js(_ s: String) { webView.evaluateJavaScript(s, completionHandler: nil) }

    /// fn_8007E2A8 → HBM SE.
    private func se(_ n: Int) {
        if lastSE.id == n && frame - lastSE.frame < 3 { return }
        lastSE = (n, frame)
        let ids = [0: 0x17, 1: 0x18, 2: 0x16, 3: 0x1B, 5: 0x1A]
        if let id = ids[n] { playSE?(id) }
    }

    // MARK: WebKit

    public func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        guard isActive, let body = m.body as? [String: Any], let k = body["k"] as? String else { return }
        dirtyFrames = max(dirtyFrames, 8)
        switch k {
        case "focus":   // fn_80081FB4: only while nothing loads or animates
            if !loading && !waitingForPage && transitionT >= 15 { se(0) }
        case "trans":   // fn_80081F78 / fn_8008200C / fn_80082060
            let d = (body["d"] as? Int) ?? 0
            pendingTransition = d
            if d != 0 { se(1) }
        case "select":  // fn_800820B4
            selectFlag = true
        case "close":   // iPhone: the bottom bar's "Close" (stands in for the HOME button)
            closeRequested = true
        default: break
        }
    }

    // case 5 of fn_8007F714: a new top-level document starts loading.
    public func webView(_ w: WKWebView, didStartProvisionalNavigation n: WKNavigation!) {
        guard isActive else { return }
        if ProcessInfo.processInfo.environment["FC_MANUAL_DEBUG"] != nil { print("  nav start \(w.url?.path ?? "-") frame \(frame)") }
        loading = true
        navigationGeneration += 1
        if selectFlag {
            selectFlag = false
            se(sameDocument(w.url, homeURL) ? 5 : 1)
        }
    }

    // case 7: loaded.
    public func webView(_ w: WKWebView, didFinish n: WKNavigation!) {
        guard isActive else { return }
        loading = false
        waitingForPage = true
        finishedAt = frame
        lastTopURL = w.url
        js("window.__fc&&__fc.reset()")
        lastPointer = SIMD2(-1, -1)
        if openCountdown > 0 { openCountdown -= 1; if openCountdown == 1 { se(2) } }
    }

    public func webView(_ w: WKWebView, didFail n: WKNavigation!, withError e: Error) { loading = false }
    public func webView(_ w: WKWebView, didFailProvisionalNavigation n: WKNavigation!, withError e: Error) { loading = false }

    fileprivate func serve(_ task: WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        var path = url.path
        if path.isEmpty || path == "/" { path = "/html/startup.html" }
        let data: Data?
        if path == "/__fc/pgothic.ttf" { data = archive.pGothic }
        else { data = archive.file(path).map { Data($0) } }
        // Opera draws nothing for a missing image (index_contentsframe's img/spacer.png): answer a transparent GIF.
        let ext = (path as NSString).pathExtension.lowercased()
        if data == nil, ["png", "gif", "jpg", "jpeg"].contains(ext) {
            let gif: [UInt8] = [0x47, 0x49, 0x46, 0x38, 0x39, 0x61, 1, 0, 1, 0, 0x80, 0, 0, 0, 0, 0, 0xFF, 0xFF, 0xFF, 0x21, 0xF9, 4, 1, 0, 0,
                                0, 0, 0x2C, 0, 0, 0, 0, 1, 0, 1, 0, 0, 2, 2, 0x44, 1, 0, 0x3B]
            task.didReceive(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "image/gif"])!)
            task.didReceive(Data(gif)); task.didFinish(); return
        }
        guard let d = data else {
            task.didReceive(HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: nil)!)
            task.didFinish()
            return
        }
        let mime = path.hasPrefix("/__fc/") ? "font/ttf" : ManualArchive.mimeType(path)
        var headers = ["Content-Type": mime, "Content-Length": "\(d.count)"]
        if mime.hasPrefix("text/") { headers["Content-Type"] = mime + "; charset=utf-8" }
        headers["Access-Control-Allow-Origin"] = "*"
        task.didReceive(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!)
        task.didReceive(d)
        task.didFinish()
    }
    public func webView(_ w: WKWebView, start t: WKURLSchemeTask) { serve(t) }
    public func webView(_ w: WKWebView, stop t: WKURLSchemeTask) {}

    // MARK: snapshots → textures

    private func requestSnapshot() {
        guard !snapshotInFlight else { return }
        // While a document loads the old picture stays (the surface keeps the last finished page).
        if loading { return }
        // Give a finished page two frames to decode its images before it becomes the new picture.
        if waitingForPage && frame - finishedAt < 2 { return }
        // The live surface only needs a new picture while something on the page may be changing.
        if !waitingForPage && current != nil { guard dirtyFrames > 0 else { return }; dirtyFrames -= 1 }
        snapshotInFlight = true
        let gen = navigationGeneration
        let cfg = WKSnapshotConfiguration()
        cfg.rect = CGRect(origin: .zero, size: browserSize)
        cfg.afterScreenUpdates = true
        webView.takeSnapshot(with: cfg) { [weak self] image, _ in
            guard let self else { return }
            self.snapshotInFlight = false
            guard self.isActive, gen == self.navigationGeneration, let image, let tex = self.texture(image) else { return }
            if self.waitingForPage {
                // E09: the new page is ready — start the 15-frame change (fn_800809B8 head).
                self.waitingForPage = false
                self.previous = self.current
                self.current = tex
                self.transitionT = self.previous == nil ? 15 : 0
                self.transitionDir = self.pendingTransition == 1 ? 1 / 15 : self.pendingTransition == 2 ? -1 / 15 : 0
                self.pendingTransition = 0
                self.dirtyFrames = 8
            } else if !self.loading {
                self.current = tex   // live surface (rollovers, scrolling)
            }
        }
    }

    #if canImport(AppKit)
    private func texture(_ image: NSImage) -> MTLTexture? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return try? loader.newTexture(cgImage: cg, options: [.SRGB: false, .textureUsage: MTLTextureUsage.shaderRead.rawValue])
    }
    #elseif canImport(UIKit)
    private func texture(_ image: UIImage) -> MTLTexture? {
        guard let cg = image.cgImage else { return nil }
        return try? loader.newTexture(cgImage: cg, options: [.SRGB: false, .textureUsage: MTLTextureUsage.shaderRead.rawValue])
    }
    #endif

    /// Debug: evaluate JavaScript in the top document.
    public func debugEval(_ s: String, _ done: @escaping (Any?) -> Void) { webView.evaluateJavaScript(s) { r, e in done(r ?? e) } }

    /// True once the first page is on screen (for tests).
    public var hasPicture: Bool { current != nil }
    public var currentPath: String? { lastTopURL?.path }

    // MARK: draw

    /// fn_8002E1A0 + fn_800809B8: black clear, the page(s), then the pointer.
    public func draw(_ enc: MTLRenderCommandEncoder, pad: KPad) {
        guard isActive, let pipeline else { return }
        enc.setRenderPipelineState(pipeline)
        if let noDepth { enc.setDepthStencilState(noDepth) }
        quadBand = (0, 1)
        quad(enc, nil, x0: 0, x1: 1, color: SIMD4(0, 0, 0, 1))
        if isPortrait {
            let H = LogicalScreen.height
            quadBand = (browserTop / H, (browserTop + Float(browserSize.height)) / H)
        }
        let t = Float(transitionT)
        if let cur = current {
            // new page slides in from −(15 − t)·d·15 % of the width
            let off = transitionT < 15 ? -(15 - t) * transitionDir * 0.15 : 0
            quad(enc, cur, x0: off, x1: 1 + off, color: SIMD4(1, 1, 1, 1))
        }
        if transitionT < 15, let old = previous {
            let off = t * transitionDir * 0.15
            let a = (255 - (255 * Float(transitionT)) / 15) / 255
            quad(enc, old, x0: off, x1: 1 + off, color: SIMD4(1, 1, 1, a))
        }
        quadBand = (0, 1)
        if !isPortrait, let c = cursor, pad.pointerValid {
            c.draw(enc, pointer: pad.pointer, twist: pad.twist, screenWidth: screenWidth)
        }
    }

    private var quadBand: (Float, Float) = (0, 1)
    private func quad(_ enc: MTLRenderCommandEncoder, _ tex: MTLTexture?, x0: Float, x1: Float, color: SIMD4<Float>) {
        guard let pipeline else { return }
        enc.setRenderPipelineState(pipeline)
        var r = SIMD4<Float>(x0, quadBand.0, x1, quadBand.1)
        var c = color
        var useTex: Int32 = tex == nil ? 0 : 1
        enc.setVertexBytes(&r, length: 16, index: 0)
        enc.setFragmentBytes(&c, length: 16, index: 0)
        enc.setFragmentBytes(&useTex, length: 4, index: 1)
        if let tex { enc.setFragmentTexture(tex, index: 0) } else { enc.setFragmentTexture(nil, index: 0) }
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }

    static func makePipeline(_ device: MTLDevice) throws -> MTLRenderPipelineState {
        let src = """
        #include <metal_stdlib>
        using namespace metal;
        struct V { float4 p [[position]]; float2 uv; };
        vertex V man_vs(uint id [[vertex_id]], constant float4& r [[buffer(0)]]) {
            float2 q = float2(id & 1, id >> 1);
            float x = mix(r.x, r.z, q.x), y = mix(r.y, r.w, q.y);
            V o; o.p = float4(x * 2 - 1, 1 - y * 2, 0, 1); o.uv = q; return o;
        }
        fragment float4 man_fs(V in [[stage_in]], constant float4& c [[buffer(0)]], constant int& useTex [[buffer(1)]],
                               texture2d<float> t [[texture(0)]]) {
            constexpr sampler s(filter::linear, address::clamp_to_edge);
            float4 x = useTex != 0 ? t.sample(s, in.uv) : float4(1);
            return float4(x.rgb, 1) * c;
        }
        """
        let lib = try device.makeLibrary(source: src, options: nil)
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = lib.makeFunction(name: "man_vs"); d.fragmentFunction = lib.makeFunction(name: "man_fs")
        d.colorAttachments[0].pixelFormat = .bgra8Unorm
        d.depthAttachmentPixelFormat = .depth32Float
        let ca = d.colorAttachments[0]!
        ca.isBlendingEnabled = true
        ca.sourceRGBBlendFactor = .sourceAlpha; ca.destinationRGBBlendFactor = .oneMinusSourceAlpha
        ca.sourceAlphaBlendFactor = .one; ca.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        return try device.makeRenderPipelineState(descriptor: d)
    }
}

public enum RVLErrorManual: Error { case noManual }

/// WKURLSchemeHandler / script handler without a retain cycle through the configuration.
private final class SchemeProxy: NSObject, WKURLSchemeHandler {
    weak var target: ManualViewer?
    func webView(_ w: WKWebView, start t: WKURLSchemeTask) { target?.webView(w, start: t) }
    func webView(_ w: WKWebView, stop t: WKURLSchemeTask) {}
}

private final class WeakHandler: NSObject, WKScriptMessageHandler {
    weak var target: ManualViewer?
    init(_ t: ManualViewer) { target = t }
    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        target?.userContentController(c, didReceive: m)
    }
}
