import Cocoa
import WebKit
import CoreGraphics

// ============================================================
// 受控测试目标：AppKit 控件 / 自绘 Canvas / WKWebView / 拖拽
// 每个交互都写一行 JSONL，并发布目标控件的 CG 全局坐标，
// 供外部投递器做「后台点击是否真的生效」的判定。
// ============================================================

let LAB = "/tmp/wbcu-lab"
let EVENTS = "\(LAB)/events.jsonl"
let TARGETS = "\(LAB)/targets.json"
let STATE = "\(LAB)/state.json"

func ensureDir() {
    try? FileManager.default.createDirectory(atPath: LAB, withIntermediateDirectories: true)
}

final class Logger {
    static let shared = Logger()
    private let q = DispatchQueue(label: "log")
    private var clicks = 0, canvasClicks = 0, webClicks = 0, drops = 0, drags = 0
    private var text = ""

    func event(_ kind: String, _ view: String, _ local: CGPoint?, _ note: String = "") {
        q.async {
            var d: [String: Any] = [
                "ts": Date().timeIntervalSince1970,
                "kind": kind,
                "view": view,
                "appActive": NSApp.isActive,
                "note": note
            ]
            if let p = local { d["localX"] = p.x; d["localY"] = p.y }
            if let line = try? JSONSerialization.data(withJSONObject: d, options: [.sortedKeys]),
               let s = String(data: line, encoding: .utf8) {
                if let h = FileHandle(forWritingAtPath: EVENTS) {
                    h.seekToEndOfFile(); h.write((s + "\n").data(using: .utf8)!); try? h.close()
                } else {
                    try? (s + "\n").write(toFile: EVENTS, atomically: true, encoding: .utf8)
                }
            }
            self.flushState()
        }
    }

    /// 原样落盘一条已经在主线程组装好的记录（事件监视器用，不再碰状态文件）
    func raw(_ d: [String: Any]) {
        guard let line = try? JSONSerialization.data(withJSONObject: d, options: [.sortedKeys]),
              let s = String(data: line, encoding: .utf8) else { return }
        q.async {
            if let h = FileHandle(forWritingAtPath: EVENTS) {
                h.seekToEndOfFile(); h.write((s + "\n").data(using: .utf8)!); try? h.close()
            } else {
                try? (s + "\n").write(toFile: EVENTS, atomically: true, encoding: .utf8)
            }
        }
    }

    func bump(_ key: String) {
        q.async {
            switch key {
            case "clicks": self.clicks += 1
            case "canvas": self.canvasClicks += 1
            case "web": self.webClicks += 1
            case "drops": self.drops += 1
            case "drags": self.drags += 1
            default: break
            }
            self.flushState()
        }
    }

    func setText(_ t: String) { q.async { self.text = t; self.flushState() } }

    private func flushState() {
        let d: [String: Any] = [
            "clicks": clicks, "canvasClicks": canvasClicks, "webClicks": webClicks,
            "drops": drops, "drags": drags,
            "text": text,
            "appActive": NSApp.isActive,
            "frontmost": NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
        ]
        if let data = try? JSONSerialization.data(withJSONObject: d, options: [.sortedKeys, .prettyPrinted]) {
            try? data.write(to: URL(fileURLWithPath: STATE))
        }
    }
}

// MARK: - 全事件监视器
//
// 只记录「进程真的收到了什么」，不掺任何推断。
// 有了它才能把失败原因切开：
//   · 没有 monitor 行          → 事件根本没进进程（投递层失败）
//   · 有 monitor 但按钮没回调  → AppKit 把事件吞了（firstMouse 语义）
//   · 有 monitor 且回调了但值不对 → 坐标/命中层失败
// 同时把投递方设置的 CGEvent 私有字段原样回读，验证 51/58/91/92 是否真的落到了事件上。
func cgField(_ e: CGEvent?, _ n: UInt32) -> Int64? {
    guard let e = e, let f = CGEventField(rawValue: n) else { return nil }
    return e.getIntegerValueField(f)
}

func installEventMonitor() {
    NSEvent.addLocalMonitorForEvents(matching: .any) { e in
        // 只关心鼠标/键盘，避免被 timer 之类的杂音淹没日志
        let interesting: Set<NSEvent.EventType> = [
            .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
            .otherMouseDown, .otherMouseUp, .mouseMoved, .leftMouseDragged,
            .rightMouseDragged, .keyDown, .keyUp
        ]
        guard interesting.contains(e.type) else { return e }
        let cg = e.cgEvent
        let d: [String: Any] = [
            "ts": Date().timeIntervalSince1970,
            "kind": "monitor",
            "type": e.type.rawValue,
            "windowNumber": e.windowNumber,
            "clickCount": e.clickCount,
            "appActive": NSApp.isActive,
            "keyWindow": NSApp.keyWindow?.windowNumber ?? -1,
            "mainWindow": NSApp.mainWindow?.windowNumber ?? -1,
            "locationInWindow": ["x": e.locationInWindow.x, "y": e.locationInWindow.y],
            "f51": cgField(cg, 51) ?? -1,
            "f58": cgField(cg, 58) ?? -1,
            "f91": cgField(cg, 91) ?? -1,
            "f92": cgField(cg, 92) ?? -1,
            "hasWindowLoc": (cg?.getIntegerValueField(.mouseEventClickState) ?? -1) >= 0
        ]
        // 事件自身的「窗口局部坐标」：私有 CGEventGetWindowLocation 不在公开头文件，
        // 这里用 locationInWindow 代替（AppKit 已用它做过换算，等价可读）。
        Logger.shared.raw(d)
        return e
    }
}

// MARK: - 自绘 Canvas
final class CanvasView: NSView {
    var dots: [CGPoint] = []
    override var isFlipped: Bool { false }
    // 关键：非激活窗口的首次点击是否被接受。默认 false → 事件会被吞掉用于激活窗口
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 0.96, alpha: 1).setFill()
        bounds.fill()
        NSColor(calibratedWhite: 0.8, alpha: 1).setStroke()
        NSBezierPath(rect: bounds).stroke()
        for (i, d) in dots.enumerated() {
            let c = i % 2 == 0 ? NSColor.systemBlue : NSColor.systemPurple
            c.setFill()
            NSBezierPath(ovalIn: NSRect(x: d.x - 5, y: d.y - 5, width: 10, height: 10)).fill()
        }
        let s = "Canvas: \(dots.count) dots" as NSString
        s.draw(at: NSPoint(x: 8, y: bounds.height - 22),
               withAttributes: [.font: NSFont.systemFont(ofSize: 11),
                                .foregroundColor: NSColor.secondaryLabelColor])
    }
    override func mouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        dots.append(p); needsDisplay = true
        Logger.shared.event("canvas.mouseDown", "canvas", p)
        Logger.shared.bump("canvas")
    }
    override func mouseUp(with e: NSEvent) {
        Logger.shared.event("canvas.mouseUp", "canvas", convert(e.locationInWindow, from: nil))
    }
}

// MARK: - 拖拽目标
final class DropView: NSView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    var highlighted = false { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        (highlighted ? NSColor.systemGreen.withAlphaComponent(0.25) : NSColor(calibratedWhite: 0.94, alpha: 1)).setFill()
        bounds.fill()
        NSColor(calibratedWhite: 0.75, alpha: 1).setStroke()
        let p = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6)
        p.lineWidth = 1; p.stroke()
        ("Drop here" as NSString).draw(at: NSPoint(x: 10, y: bounds.midY - 7),
            withAttributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
    }
    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.string])
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draggingEntered(_ s: NSDraggingInfo) -> NSDragOperation {
        highlighted = true; Logger.shared.event("drop.entered", "drop", nil); return .copy
    }
    override func draggingExited(_ s: NSDraggingInfo?) { highlighted = false }
    override func performDragOperation(_ s: NSDraggingInfo) -> Bool {
        highlighted = false
        Logger.shared.event("drop.perform", "drop", convert(s.draggingLocation, from: nil))
        Logger.shared.bump("drops")
        return true
    }
}

final class DragView: NSView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.systemOrange.withAlphaComponent(0.22).setFill()
        bounds.fill()
        NSColor.systemOrange.setStroke()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6).stroke()
        ("Drag me" as NSString).draw(at: NSPoint(x: 12, y: bounds.midY - 7),
            withAttributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.systemOrange])
    }
    override func mouseDown(with e: NSEvent) {
        Logger.shared.event("drag.mouseDown", "dragSource", convert(e.locationInWindow, from: nil))
    }
    override func mouseDragged(with e: NSEvent) {
        Logger.shared.bump("drags")
        let item = NSDraggingItem(pasteboardWriter: "wbcu-drag" as NSString)
        item.setDraggingFrame(bounds, contents: nil)
        beginDraggingSession(with: [item], event: e, source: self)
    }
}
extension DragView: NSDraggingSource {
    func draggingSession(_ s: NSDraggingSession, sourceOperationMaskFor c: NSDraggingContext) -> NSDragOperation { .copy }
}

final class FirstMouseWebView: WKWebView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - WKWebView 桥接
final class WebBridge: NSObject, WKScriptMessageHandler {
    func userContentController(_ u: WKUserContentController, didReceive m: WKScriptMessage) {
        let body = "\(m.body)"
        Logger.shared.event("web.\(body)", "web", nil)
        if body.hasPrefix("click") { Logger.shared.bump("web") }
    }
}

// MARK: - App Delegate
final class AppDelegate: NSObject, NSApplicationDelegate, NSTextFieldDelegate {
    var window: NSWindow!
    var counterLabel: NSTextField!
    var clickCount = 0
    let webBridge = WebBridge()
    var webView: WKWebView!
    var targets: [String: NSView] = [:]
    var secondWindow: NSWindow?
    /// Web 按钮在 WebView 里的 CSS 矩形（左上原点，y 向下）。
    /// 必须由 JS 实测出来：把整个 WKWebView 的中心当作按钮去点，
    /// 只会点到 body 空白处，然后被误判成「引擎点不动 WebKit」。
    var webBtnCSS = CGRect(x: 8, y: 8, width: 120, height: 32)

    func applicationDidFinishLaunching(_ n: Notification) {
        ensureDir()
        try? FileManager.default.removeItem(atPath: EVENTS)
        installEventMonitor()
        Logger.shared.event("app.launch", "app", nil)

        let rect = NSRect(x: 200, y: 120, width: 580, height: 700)
        window = NSWindow(contentRect: rect,
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "WBCU Lab Target"
        window.isReleasedWhenClosed = false

        let content = NSView(frame: NSRect(x: 0, y: 0, width: 580, height: 700))
        window.contentView = content

        var y: CGFloat = 640

        // 1) 普通按钮
        let b1 = NSButton(title: "普通按钮", target: self, action: #selector(plainClicked))
        b1.frame = NSRect(x: 20, y: y, width: 140, height: 32)
        b1.bezelStyle = .rounded
        content.addSubview(b1); targets["btnPlain"] = b1

        // 2) 计数器
        counterLabel = NSTextField(labelWithString: "count = 0")
        counterLabel.frame = NSRect(x: 180, y: y + 6, width: 120, height: 20)
        // 稳定标识：期望状态验证要靠它定位「状态元素」，不靠文本模糊匹配
        counterLabel.setAccessibilityIdentifier("countLabel")
        content.addSubview(counterLabel)
        let b2 = NSButton(title: "计数 +1", target: self, action: #selector(countClicked))
        b2.frame = NSRect(x: 300, y: y, width: 110, height: 32)
        b2.bezelStyle = .rounded
        content.addSubview(b2); targets["btnCount"] = b2

        // 3) 文本框
        y -= 52
        let tf = NSTextField(frame: NSRect(x: 20, y: y, width: 390, height: 24))
        tf.placeholderString = "文本输入框"
        tf.delegate = self
        content.addSubview(tf); targets["field"] = tf

        // 4) Canvas
        y -= 170
        let cv = CanvasView(frame: NSRect(x: 20, y: y, width: 250, height: 150))
        content.addSubview(cv); targets["canvas"] = cv

        // 5) WKWebView
        let cfg = WKWebViewConfiguration()
        cfg.userContentController.add(webBridge, name: "log")
        let wv = FirstMouseWebView(frame: NSRect(x: 290, y: y, width: 270, height: 150), configuration: cfg)
        content.addSubview(wv); webView = wv; targets["web"] = wv
        wv.loadHTMLString("""
        <html><body style="margin:0;font:13px -apple-system;background:#fafafa">
        <button id="b" style="margin:8px;width:120px;height:32px">Web 按钮</button>
        <div id="d" style="margin:8px;padding:6px;border:1px dashed #888;border-radius:6px"
             draggable="true">drag me</div>
        <script>
        const L = m => window.webkit.messageHandlers.log.postMessage(m);
        document.getElementById('b').addEventListener('click', () => L('click-single'));
        document.getElementById('b').addEventListener('dblclick', () => L('dblclick'));
        document.addEventListener('contextmenu', e => { e.preventDefault(); L('contextmenu'); });
        document.getElementById('d').addEventListener('dragstart', () => L('dragstart'));
        </script></body></html>
        """, baseURL: nil)
        // 6) 拖拽区
        y -= 80
        let src = DragView(frame: NSRect(x: 20, y: y, width: 120, height: 46))
        let dst = DropView(frame: NSRect(x: 300, y: y, width: 200, height: 46))
        content.addSubview(src); content.addSubview(dst); targets["dragSource"] = src; targets["drop"] = dst

        // 给每个控件一个稳定的 AX 标识，便于按名字精确定位（不靠坐标/文本）
        for (name, v) in targets { v.setAccessibilityIdentifier(name) }

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self.publishTargets() }
        Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { _ in self.publishTargets() }
    }

    /// 在主窗口上方开一个「同一应用的另一个窗口」，用来测「目标上方有本应用窗口」这一情形
    func openSecondWindow() {
        guard secondWindow == nil else { return }
        let f = window.frame
        let r = NSRect(x: f.minX + 40, y: f.maxY - 220, width: 240, height: 180)
        let w = NSWindow(contentRect: r, styleMask: [.titled, .closable],
                         backing: .buffered, defer: false)
        w.title = "Second"
        w.level = .floating
        let v = NSView(frame: NSRect(origin: .zero, size: r.size))
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.9).cgColor
        w.contentView = v
        w.orderFront(nil)
        secondWindow = w
        Logger.shared.event("secondWindow.open", "app", nil)
    }

    @objc func plainClicked() {
        Logger.shared.event("btnPlain.click", "btnPlain", nil)
        Logger.shared.bump("clicks")
    }

    @objc func countClicked() {
        clickCount += 1
        counterLabel.stringValue = "count = \(clickCount)"
        Logger.shared.event("btnCount.click", "btnCount", nil, "count=\(clickCount)")
        Logger.shared.bump("clicks")
    }

    func controlTextDidChange(_ obj: Notification) {
        if let tf = obj.object as? NSTextField {
            Logger.shared.setText(tf.stringValue)
            Logger.shared.event("field.change", "field", nil, tf.stringValue)
        }
    }

    /// 通过文件给夹具下命令（minimize / deminimize / hide / show）
    ///
    /// 为什么要这个通道：osascript 的 `set miniaturized` 对未声明脚本支持的 App 会直接报
    /// -10006，实测无法造出「真的最小化」状态；而引擎的 visible/minimized 判定必须对着
    /// 真实状态验证，不能靠猜。所以由夹具自己提供可控入口。
    func pollCommand() {
        let p = "\(LAB)/cmd"
        guard let raw = try? String(contentsOfFile: p, encoding: .utf8) else { return }
        try? FileManager.default.removeItem(atPath: p)
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "minimize": window.miniaturize(nil)
        case "deminimize": window.deminiaturize(nil)
        case "hide": window.orderOut(nil)
        case "show": window.makeKeyAndOrderFront(nil)
        case "secondWindow": openSecondWindow()
        case "closeSecond": secondWindow?.orderOut(nil); secondWindow = nil
        default: break
        }
        Logger.shared.event("cmd.applied", "app", nil, raw.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// 把每个控件的「CG 全局坐标矩形」发布出去（左上原点，与 CGEvent 一致）
    func publishTargets() {
        pollCommand()
        // 顺带校准 Web 按钮的 CSS 矩形（每次发布都刷一次，页面重排也不会失准）
        webView?.evaluateJavaScript("""
        (()=>{const b=document.getElementById('b');if(!b)return null;
        const r=b.getBoundingClientRect();return [r.x,r.y,r.width,r.height];})()
        """) { res, _ in
            if let a = res as? [Double], a.count == 4 {
                self.webBtnCSS = CGRect(x: a[0], y: a[1], width: a[2], height: a[3])
            }
        }
        guard let w = window, w.isVisible else { return }
        let screenH = NSScreen.screens.first?.frame.height ?? 0
        var out: [String: Any] = [:]
        // 窗口自身在 CG 坐标系下的 frame
        if let cgList = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(w.windowNumber)) as? [[String: Any]],
           let first = cgList.first,
           let bd = first[kCGWindowBounds as String] as? [String: Any] {
            out["windowCGFrame"] = bd
        }
        out["windowNumber"] = w.windowNumber
        out["pid"] = Int(ProcessInfo.processInfo.processIdentifier)
        out["contentHeight"] = w.contentView?.bounds.height ?? 0
        out["titleBarHeight"] = w.frame.height - (w.contentView?.bounds.height ?? 0)
        out["appActive"] = NSApp.isActive
        out["frontmost"] = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""

        var rects: [String: Any] = [:]
        for (name, v) in targets {
            guard let cv = v.superview else { continue }
            let r = cv.convert(v.frame, to: nil)          // → window base coords (bottom-left)
            let s = w.convertToScreen(r)                  // → screen coords (bottom-left origin)
            let cgX = s.minX
            let cgY = screenH - s.maxY
            rects[name] = ["x": cgX, "y": cgY, "w": s.width, "h": s.height,
                           "cx": cgX + s.width / 2, "cy": cgY + s.height / 2]
        }
        // Web 按钮：CSS 矩形（y 向下）→ 视图坐标（y 向上）→ 窗口 → 屏幕 → CG
        if let wv = webView, let sv = wv.superview {
            let vr = sv.convert(wv.frame, to: nil)          // 窗口坐标（左下原点）
            let cxWin = vr.minX + webBtnCSS.midX
            let cyWin = vr.maxY - webBtnCSS.midY
            let sp = w.convertPoint(toScreen: NSPoint(x: cxWin, y: cyWin))
            let cgX = sp.x
            let cgY = screenH - sp.y
            rects["webBtn"] = ["x": sp.x - webBtnCSS.width / 2,
                               "y": screenH - (sp.y + webBtnCSS.height / 2),
                               "w": webBtnCSS.width, "h": webBtnCSS.height,
                               "cx": cgX, "cy": cgY]
        }
        out["targets"] = rects
        if let d = try? JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys]) {
            try? d.write(to: URL(fileURLWithPath: TARGETS))
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
