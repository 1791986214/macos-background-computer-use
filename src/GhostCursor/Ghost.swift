import Foundation
import AppKit
import CoreGraphics
import Darwin

// ============================================================
// Agent Cursor —— 与物理鼠标完全解耦的「Agent 光标系统」
//
// 它不是第二个鼠标设备，也不是输入通道：
//   · 独立坐标系：锚定 目标 Window ID + 窗口局部坐标（窗口动，它跟着动）
//   · 独立状态机：idle / moving / pressing / ok / fail
//   · 独立动画：easeOutCubic 移动，不瞬移，让人跟得上
//   · 从不读取也不改变物理鼠标位置
//
// 三层协同但彼此独立：
//   AgentCursor(可视化)  ⇄  TargetedDispatcher(真正投递)  ⇄  Observer(AX/SCK 观察)
// 关掉可视化，投递照常；关掉观察，投递照常（只是无法验证）。
// ============================================================

let GHOST_SOCK = "/tmp/wbcu-ghost.sock"

enum CursorPhase: String {
    case idle, moving, pressing, ok, fail
}

// MARK: - 光标模型（唯一真源）
final class CursorModel {
    // 锚定：窗口 + 窗口局部坐标（左上原点）。不锚定时用全局坐标。
    var windowId: CGWindowID? = nil
    var anchorLocal: CGPoint = .zero
    var anchored = false

    var target: CGPoint = .zero       // 由锚点换算出的全局目标
    var display: CGPoint = .zero      // 当前动画位置
    var phase: CursorPhase = .idle
    var label: String = ""
    var visible = false

    var feedbackKind: CursorPhase? = nil
    var feedbackAt: Date? = nil
    var moveStartedAt: Date? = nil
    var moveFrom: CGPoint = .zero
    var moveDuration: Double = 0.24

    func windowFrame(_ id: CGWindowID) -> CGRect? {
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]],
              let d = list.first,
              let b = d[kCGWindowBounds as String] as? [String: Any] else { return nil }
        return CGRect(x: (b["X"] as? Double) ?? 0, y: (b["Y"] as? Double) ?? 0,
                      width: (b["Width"] as? Double) ?? 0, height: (b["Height"] as? Double) ?? 0)
    }

    /// 窗口移动/缩放后重新换算（每 100ms）
    func refreshAnchor() {
        guard anchored, let wid = windowId, let f = windowFrame(wid) else { return }
        target = CGPoint(x: f.minX + anchorLocal.x, y: f.minY + anchorLocal.y)
    }

    /// 60fps 动画推进
    func tick() {
        guard visible else { return }
        if let st = moveStartedAt {
            let t = min(1.0, Date().timeIntervalSince(st) / moveDuration)
            let e = 1 - pow(1 - t, 3)                       // easeOutCubic
            display = CGPoint(x: moveFrom.x + (target.x - moveFrom.x) * e,
                              y: moveFrom.y + (target.y - moveFrom.y) * e)
            if t >= 1 { moveStartedAt = nil; if phase == .moving { phase = .idle } }
        } else {
            display = target
        }
        if let at = feedbackAt, Date().timeIntervalSince(at) > 1.2 {
            feedbackAt = nil; feedbackKind = nil
            if phase == .ok || phase == .fail { phase = .idle }
        }
    }

    func goto(global p: CGPoint, animated: Bool, label text: String) {
        moveFrom = display; target = p
        anchored = false; windowId = nil
        visible = true
        phase = animated ? .moving : .idle
        moveStartedAt = animated ? Date() : nil
        if !animated { display = p }
        label = text
    }

    func goto(window: CGWindowID, local: CGPoint, animated: Bool, label text: String) {
        anchored = true; windowId = window; anchorLocal = local
        refreshAnchor()
        moveFrom = display; visible = true
        phase = animated ? .moving : .idle
        moveStartedAt = animated ? Date() : nil
        if !animated { display = target }
        label = text
    }

    func press(label text: String) {
        visible = true
        if let st = moveStartedAt, Date().timeIntervalSince(st) < moveDuration {
            display = target; moveStartedAt = nil
        }
        phase = .pressing
        if !text.isEmpty { label = text }
    }

    func feedback(_ ok: Bool, label text: String) {
        phase = ok ? .ok : .fail
        feedbackKind = phase
        feedbackAt = Date()
        if !text.isEmpty { label = text }
    }

    func hide() {
        visible = false; phase = .idle
        feedbackKind = nil; feedbackAt = nil
    }

    var snapshot: [String: Any] {
        ["visible": visible, "phase": phase.rawValue,
         "x": round(display.x), "y": round(display.y),
         "targetX": round(target.x), "targetY": round(target.y),
         "anchored": anchored, "windowId": windowId.map { Int($0) } ?? 0,
         "localX": round(anchorLocal.x), "localY": round(anchorLocal.y),
         "label": label]
    }
}

// MARK: - 渲染（矢量绘制，与 Codex 同为代码绘制而非图片资源）
final class GhostView: NSView {
    var model: CursorModel!
    override var isFlipped: Bool { false }

    private func toView(_ p: CGPoint) -> CGPoint {
        let screenH = NSScreen.screens.first?.frame.height ?? 0
        return CGPoint(x: p.x, y: (screenH - p.y) - (window?.frame.minY ?? 0))
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let m = model, m.visible else { return }
        let p = toView(m.display)

        if let k = m.feedbackKind, let at = m.feedbackAt {
            let t = CGFloat(min(1.0, Date().timeIntervalSince(at) / 0.9))
            let radius = 9 + t * 30
            let color: NSColor = k == .ok ? .systemGreen : .systemRed
            color.withAlphaComponent((1 - t) * 0.75).setStroke()
            let ring = NSBezierPath(ovalIn: NSRect(x: p.x - radius, y: p.y - radius,
                                                   width: radius * 2, height: radius * 2))
            ring.lineWidth = 2.5
            ring.stroke()
        }
        if m.phase == .pressing {
            NSColor.systemPurple.withAlphaComponent(0.32).setFill()
            NSBezierPath(ovalIn: NSRect(x: p.x - 16, y: p.y - 16, width: 32, height: 32)).fill()
            NSColor.systemPurple.withAlphaComponent(0.5).setStroke()
            let r2 = NSBezierPath(ovalIn: NSRect(x: p.x - 11, y: p.y - 11, width: 22, height: 22))
            r2.lineWidth = 1.5; r2.stroke()
        }

        // 光晕
        NSColor.systemPurple.withAlphaComponent(0.18).setFill()
        NSBezierPath(ovalIn: NSRect(x: p.x - 10, y: p.y - 10, width: 20, height: 20)).fill()

        // 指针
        let arrow = NSBezierPath()
        arrow.move(to: NSPoint(x: p.x, y: p.y))
        arrow.line(to: NSPoint(x: p.x, y: p.y - 19))
        arrow.line(to: NSPoint(x: p.x + 4.6, y: p.y - 14.4))
        arrow.line(to: NSPoint(x: p.x + 7.4, y: p.y - 19.8))
        arrow.line(to: NSPoint(x: p.x + 10.4, y: p.y - 18.4))
        arrow.line(to: NSPoint(x: p.x + 7.6, y: p.y - 13.1))
        arrow.line(to: NSPoint(x: p.x + 12.8, y: p.y - 12.6))
        arrow.close()
        NSColor.white.withAlphaComponent(0.96).setFill()
        arrow.fill()
        let stroke: NSColor = m.phase == .fail ? .systemRed : (m.phase == .ok ? .systemGreen : .systemPurple)
        stroke.setStroke()
        arrow.lineWidth = 1.3
        arrow.lineJoinStyle = .round
        arrow.stroke()

        if !m.label.isEmpty {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 10, weight: .medium),
                .foregroundColor: NSColor.white
            ]
            let s = m.label as NSString
            let sz = s.size(withAttributes: attrs)
            let box = NSRect(x: p.x + 13, y: p.y - 16, width: sz.width + 10, height: sz.height + 4)
            stroke.withAlphaComponent(0.92).setFill()
            NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4).fill()
            s.draw(at: NSPoint(x: box.minX + 5, y: box.minY + 2), withAttributes: attrs)
        }
    }
}

final class GhostPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - 控制器
final class CursorController {
    let model = CursorModel()
    var panel: GhostPanel!
    var view: GhostView!
    var animTimer: Timer?
    var anchorTimer: Timer?

    func setup() {
        guard let screen = NSScreen.screens.first else { return }
        panel = GhostPanel(contentRect: screen.frame,
                           styleMask: [.borderless, .nonactivatingPanel],
                           backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        // 层级对齐 Codex 的 Software Cursor（实测 layer=102 ≈ popUpMenu+1）：
        // 能盖住所有普通窗口与菜单，但不去盖系统 HUD / 通知中心 / 输入法候选。
        panel.level = NSWindow.Level(rawValue: 102)
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false

        view = GhostView(frame: screen.frame)
        view.model = model
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = view
        panel.orderFrontRegardless()

        animTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { _ in
            self.model.tick()
            self.view.needsDisplay = true
        }
        anchorTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            self.model.refreshAnchor()
        }
    }

    func handle(_ o: [String: Any]) -> [String: Any] {
        let op = (o["op"] as? String) ?? (o["cmd"] as? String) ?? ""
        let animated = (o["animate"] as? Bool) ?? true
        let label = (o["label"] as? String) ?? ""
        switch op {
        case "goto":
            if let wid = o["windowId"] as? Int, wid > 0,
               let lx = o["localX"] as? Double, let ly = o["localY"] as? Double {
                model.goto(window: CGWindowID(wid), local: CGPoint(x: lx, y: ly), animated: animated, label: label)
            } else if let x = o["x"] as? Double, let y = o["y"] as? Double {
                model.goto(global: CGPoint(x: x, y: y), animated: animated, label: label)
            }
        case "move":
            if let x = o["x"] as? Double, let y = o["y"] as? Double {
                model.goto(global: CGPoint(x: x, y: y), animated: false, label: label)
            }
        case "press", "click":
            model.press(label: label)
        case "feedback":
            model.feedback((o["ok"] as? Bool) ?? true, label: label)
        case "hide":
            model.hide()
        case "quit":
            model.hide()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { NSApp.terminate(nil) }
        default:
            break
        }
        var s = model.snapshot
        s["ok"] = true
        return s
    }
}

// MARK: - Socket（每条命令回一行 JSON 状态）
final class GhostServer {
    let controller: CursorController
    var listenFD: Int32 = -1

    init(controller: CursorController) { self.controller = controller }

    func start() {
        unlink(GHOST_SOCK)
        listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFD >= 0 else { return }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(GHOST_SOCK.utf8)
        withUnsafeMutablePointer(to: &addr.sun_path) { p in
            p.withMemoryRebound(to: CChar.self, capacity: 104) { dst in
                for (i, b) in pathBytes.enumerated() where i < 103 { dst[i] = CChar(bitPattern: b) }
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let ok = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listenFD, $0, size) }
        }
        guard ok == 0, listen(listenFD, 8) == 0 else { return }
        DispatchQueue.global(qos: .userInitiated).async { self.acceptLoop() }
    }

    private func acceptLoop() {
        while true {
            let fd = accept(listenFD, nil, nil)
            if fd < 0 { break }
            DispatchQueue.global().async {
                var buf = [UInt8](repeating: 0, count: 4096)
                var acc = Data()
                while true {
                    let n = read(fd, &buf, buf.count)
                    if n <= 0 { break }
                    acc.append(contentsOf: buf[0..<n])
                    while let nl = acc.firstIndex(of: 0x0A) {
                        let line = acc.subdata(in: acc.startIndex..<nl)
                        acc.removeSubrange(acc.startIndex...nl)
                        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
                        var reply: [String: Any] = [:]
                        let sem = DispatchSemaphore(value: 0)
                        DispatchQueue.main.async {
                            reply = self.controller.handle(obj)
                            sem.signal()
                        }
                        _ = sem.wait(timeout: .now() + 1.0)
                        if let d = try? JSONSerialization.data(withJSONObject: reply, options: [.sortedKeys]),
                           let s = String(data: d, encoding: .utf8) {
                            _ = (s + "\n").withCString { write(fd, $0, strlen($0)) }
                        }
                    }
                }
                close(fd)
            }
        }
    }
}

func runGhostDaemon() {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let controller = CursorController()
    let server = GhostServer(controller: controller)
    controller.setup()
    server.start()
    app.run()
}
