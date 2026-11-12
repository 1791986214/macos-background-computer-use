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
//
// ── v0.4.2 的两个关键修正 ───────────────────────────────────
//
// ① 窗口尺寸：整屏透明面板 → 126×126 跟随小窗口
//    旧实现是 `contentRect: screen.frame`，一整块透明面板盖住整个屏幕。
//    透明不等于无感：它仍然是「用户前台窗口上方的一层全屏窗口」，
//    任何窗口级合成/录屏/窗口列表都能看到它，而且光标一动，
//    整屏区域都要重绘 —— 用户看到的就是「虚拟鼠标在我前台窗口飞来飞去」。
//    Codex 的 Software Cursor 实测是 126×126（layer 102）的小窗口，
//    只围着自己那一小块走。这里对齐这个尺寸。
//
// ② 可见性：只画在「目标窗口真切可见的地方」
//    窗口小了并不会自动解决遮挡 —— 如果目标窗口被你的前台窗口盖住，
//    小窗口照样会把光标画到你的窗口上面。所以每帧之前都要问一句：
//    这个点现在还归目标窗口吗？（TargetWindowVisibilityManager.pointVisible）
//    不归它 → 直接不画。宁可什么都看不见，也不在你眼前乱飞。
//
// ③ 空闲即隐藏：对齐 Codex 的 onscreen=false
//    动作结束后光标不该长期挂在屏幕上。1.8s 无命令就整窗隐藏。
// ============================================================

let GHOST_SOCK = "/tmp/wbcu-ghost.sock"

/// 跟随窗口尺寸：对齐 Codex Software Cursor 的实测值（126×126）
let GHOST_WIN_SIZE: CGFloat = 126
/// 光标尖端在跟随窗口内的固定位置（视图坐标，左上原点）
let GHOST_TIP = CGPoint(x: 24, y: 24)
/// 空闲多久后自动隐藏（秒）
let GHOST_IDLE_HIDE: Double = 1.8

enum CursorPhase: String {
    case idle, moving, pressing, ok, fail
}

// MARK: - 光标模型（唯一真源）
final class CursorModel {
    // 锚定：窗口 + 窗口局部坐标（左上原点）。不锚定时用全局坐标。
    var windowId: CGWindowID? = nil
    var anchorLocal: CGPoint = .zero
    var anchored = false
    /// 目标进程；可见性判断要用它来区分「本应用其它窗口」和「别人的窗口」
    var targetPid: pid_t = 0

    var target: CGPoint = .zero       // 由锚点换算出的全局目标
    var display: CGPoint = .zero      // 当前动画位置
    var phase: CursorPhase = .idle
    var label: String = ""
    var visible = false

    /// 目标点当前是否归目标窗口（被遮住 / 最小化 / 不在当前 Space → false）
    var suppressed = false
    /// 是否在前台（仅用于绘制时的弱化样式，不影响是否显示）
    var background = false

    var feedbackKind: CursorPhase? = nil
    var feedbackAt: Date? = nil
    var moveStartedAt: Date? = nil
    var moveFrom: CGPoint = .zero
    var moveDuration: Double = 0.24
    var lastTouchAt = Date()

    func touch() { lastTouchAt = Date() }

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
        // 空闲自动隐藏：动作结束后光标不该长期挂在屏幕上
        if phase == .idle, feedbackAt == nil,
           Date().timeIntervalSince(lastTouchAt) > GHOST_IDLE_HIDE {
            hide()
        }
    }

    func goto(global p: CGPoint, animated: Bool, label text: String, pid: pid_t = 0) {
        moveFrom = display; target = p
        anchored = false; windowId = nil; targetPid = pid
        visible = true
        phase = animated ? .moving : .idle
        moveStartedAt = animated ? Date() : nil
        if !animated { display = p }
        label = text
        touch()
    }

    func goto(window: CGWindowID, local: CGPoint, animated: Bool, label text: String, pid: pid_t = 0) {
        anchored = true; windowId = window; anchorLocal = local
        if pid > 0 { targetPid = pid }
        refreshAnchor()
        moveFrom = display; visible = true
        phase = animated ? .moving : .idle
        moveStartedAt = animated ? Date() : nil
        if !animated { display = target }
        label = text
        touch()
    }

    func press(label text: String) {
        visible = true
        if let st = moveStartedAt, Date().timeIntervalSince(st) < moveDuration {
            display = target; moveStartedAt = nil
        }
        phase = .pressing
        if !text.isEmpty { label = text }
        touch()
    }

    func feedback(_ ok: Bool, label text: String) {
        phase = ok ? .ok : .fail
        feedbackKind = phase
        feedbackAt = Date()
        if !text.isEmpty { label = text }
        touch()
    }

    func hide() {
        visible = false; phase = .idle
        feedbackKind = nil; feedbackAt = nil
        moveStartedAt = nil
    }

    var snapshot: [String: Any] {
        ["visible": visible, "phase": phase.rawValue,
         "x": round(display.x), "y": round(display.y),
         "targetX": round(target.x), "targetY": round(target.y),
         "anchored": anchored, "windowId": windowId.map { Int($0) } ?? 0,
         "localX": round(anchorLocal.x), "localY": round(anchorLocal.y),
         "suppressed": suppressed, "background": background,
         "label": label]
    }
}

// MARK: - 渲染（矢量绘制，与 Codex 同为代码绘制而非图片资源）
//
// 视图是 flipped 的：坐标原点在左上、y 向下，和 CGEvent 的全局坐标一致，
// 于是「全局点 → 视图点」只需要减去窗口原点，不用翻 y。
final class GhostView: NSView {
    var model: CursorModel!
    /// 光标尖端在本视图中的位置（每帧由控制器按实际窗口原点算出）
    var anchor: CGPoint = .zero

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let m = model, m.visible, !m.suppressed else { return }
        let p = anchor
        let dim: CGFloat = m.background ? 0.72 : 1.0

        if let k = m.feedbackKind, let at = m.feedbackAt {
            let t = CGFloat(min(1.0, Date().timeIntervalSince(at) / 0.9))
            let radius = 9 + t * 26
            let color: NSColor = k == .ok ? .systemGreen : .systemRed
            color.withAlphaComponent((1 - t) * 0.75 * dim).setStroke()
            let ring = NSBezierPath(ovalIn: NSRect(x: p.x - radius, y: p.y - radius,
                                                   width: radius * 2, height: radius * 2))
            ring.lineWidth = 2.5
            ring.stroke()
        }
        if m.phase == .pressing {
            NSColor.systemPurple.withAlphaComponent(0.32 * dim).setFill()
            NSBezierPath(ovalIn: NSRect(x: p.x - 16, y: p.y - 16, width: 32, height: 32)).fill()
            NSColor.systemPurple.withAlphaComponent(0.5 * dim).setStroke()
            let r2 = NSBezierPath(ovalIn: NSRect(x: p.x - 11, y: p.y - 11, width: 22, height: 22))
            r2.lineWidth = 1.5; r2.stroke()
        }

        // 光晕
        NSColor.systemPurple.withAlphaComponent(0.18 * dim).setFill()
        NSBezierPath(ovalIn: NSRect(x: p.x - 10, y: p.y - 10, width: 20, height: 20)).fill()

        // 指针（flipped 视图：y 正方向向下，所以箭头朝下生长）
        let arrow = NSBezierPath()
        arrow.move(to: NSPoint(x: p.x, y: p.y))
        arrow.line(to: NSPoint(x: p.x, y: p.y + 19))
        arrow.line(to: NSPoint(x: p.x + 4.6, y: p.y + 14.4))
        arrow.line(to: NSPoint(x: p.x + 7.4, y: p.y + 19.8))
        arrow.line(to: NSPoint(x: p.x + 10.4, y: p.y + 18.4))
        arrow.line(to: NSPoint(x: p.x + 7.6, y: p.y + 13.1))
        arrow.line(to: NSPoint(x: p.x + 12.8, y: p.y + 12.6))
        arrow.close()
        NSColor.white.withAlphaComponent(0.96 * dim).setFill()
        arrow.fill()
        let stroke: NSColor = m.phase == .fail ? .systemRed : (m.phase == .ok ? .systemGreen : .systemPurple)
        stroke.withAlphaComponent(dim).setStroke()
        arrow.lineWidth = 1.3
        arrow.lineJoinStyle = .round
        arrow.stroke()

        if !m.label.isEmpty {
            // 标签必须画得进 126×126 的小窗口：超宽就截断，不做无边界扩张
            let avail = bounds.width - p.x - 14
            if avail > 24 {
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 10, weight: .medium),
                    .foregroundColor: NSColor.white.withAlphaComponent(dim)
                ]
                var s = m.label as NSString
                var w = s.size(withAttributes: attrs).width
                if w > avail - 10 {
                    while s.length > 1, w > avail - 10 {
                        s = (s.substring(to: s.length - 1) + "…") as NSString
                        w = s.size(withAttributes: attrs).width
                    }
                }
                let box = NSRect(x: p.x + 13, y: p.y + 4, width: min(w + 10, avail), height: 16)
                stroke.withAlphaComponent(0.92 * dim).setFill()
                NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4).fill()
                s.draw(in: NSRect(x: box.minX + 5, y: box.minY + 3, width: box.width - 10, height: 12),
                       withAttributes: attrs)
            }
        }
    }
}

/// 不抢焦点、不参与窗口循环、不接鼠标事件的小型跟随面板
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
    var visTimer: Timer?
    private var windowShown = false
    private var visOut: [String: Any] = [:]

    func setup() {
        panel = GhostPanel(contentRect: NSRect(x: 0, y: 0, width: GHOST_WIN_SIZE, height: GHOST_WIN_SIZE),
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
        panel.animationBehavior = .none

        view = GhostView(frame: NSRect(x: 0, y: 0, width: GHOST_WIN_SIZE, height: GHOST_WIN_SIZE))
        view.model = model
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = view

        animTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { _ in
            self.model.tick()
            self.present()
        }
        anchorTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            self.model.refreshAnchor()
        }
        // 可见性复查：目标被遮挡/被切到别的 Space 后，光标必须立刻消失。
        // 2Hz 足够（人工切窗口的动作远慢于这个频率），且只在光标可见时跑。
        visTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            guard self.model.visible else { return }
            self.refreshVisibility()
        }
    }

    /// 把光标渲染出来：定位小窗口 → 画 → 必要时隐藏整窗
    private func present() {
        guard model.visible, !model.suppressed else {
            if windowShown { panel.orderOut(nil); windowShown = false }
            return
        }
        positionWindow()
        view.needsDisplay = true
        // 走 CFRunLoopRun() 时不经过 NSApp 的绘制周期，
        // 只设 needsDisplay 不会真的重绘（实测：窗口在、坐标对、画布全透明）。
        // 所以每个 tick 主动 flush 一次。
        view.displayIfNeeded()
        if !windowShown { panel.orderFrontRegardless(); windowShown = true }
    }

    /// 小窗口跟随光标：窗口原点 = 全局点 − 尖端内偏移，并夹在「该点所属的显示器」内
    ///
    /// v0.4.2 的写法是 `NSScreen.screens.first` + 主屏宽高夹取 ——
    /// 目标在副屏（尤其负 X 的左侧屏）时，窗口会被夹回主屏，
    /// 于是「画的位置」和「点的位置」不是同一处。
    /// 现在按点选屏，坐标换算统一走 DisplayCoordinateTransformer。
    private func positionWindow() {
        let displays = DisplayCoordinateTransformer.liveDisplays()
        guard let disp = DisplayCoordinateTransformer.display(containingCG: model.display,
                                                             displays: displays),
              let primary = displays.first(where: { $0.isPrimary }) ?? displays.first else { return }
        let screenRect = disp.cgFrame
        var originCG = CGPoint(x: model.display.x - GHOST_TIP.x,
                               y: model.display.y - GHOST_TIP.y)
        // 夹取范围 = 该显示器的 CG 矩形（可负 X / 负 Y）
        let minX = screenRect.minX
        let maxX = screenRect.maxX - GHOST_WIN_SIZE
        let minY = screenRect.minY
        let maxY = screenRect.maxY - GHOST_WIN_SIZE
        originCG.x = max(minX, min(originCG.x, max(minX, maxX)))
        originCG.y = max(minY, min(originCG.y, max(minY, maxY)))
        // CG 矩形 → AppKit 原点（逐边翻转，用主屏高度）
        let appkitOrigin = CGPoint(x: originCG.x,
                                   y: primary.appKitFrame.height - (originCG.y + GHOST_WIN_SIZE))
        if panel.frame.origin != appkitOrigin {
            panel.setFrameOrigin(appkitOrigin)
        }
        // 尖端位置由「实际窗口原点」反推，夹屏后依然指向真实像素
        view.anchor = CGPoint(x: model.display.x - originCG.x,
                              y: model.display.y - originCG.y)
    }

    /// 目标点还归不归目标窗口？不归就整窗隐藏
    func refreshVisibility() -> Bool {
        guard model.anchored, let wid = model.windowId else {
            model.suppressed = false
            return true
        }
        let frame = model.windowFrame(wid)
        model.background = (model.targetPid > 0)
            ? (NSWorkspace.shared.frontmostApplication?.processIdentifier != model.targetPid)
            : false
        // 点必须在窗口矩形内，且未被更上层的窗口盖住
        let inside = frame.map { $0.contains(model.target) } ?? false
        let visible = inside && TargetWindowVisibilityManager.pointVisible(
            windowId: wid, point: model.target, selfPid: getpid())
        model.suppressed = !visible
        return visible
    }

    func handle(_ o: [String: Any]) -> [String: Any] {
        let op = (o["op"] as? String) ?? (o["cmd"] as? String) ?? ""
        let animated = (o["animate"] as? Bool) ?? true
        let label = (o["label"] as? String) ?? ""
        let pid = pid_t((o["pid"] as? Int) ?? 0)
        switch op {
        case "goto":
            if let wid = o["windowId"] as? Int, wid > 0,
               let lx = o["localX"] as? Double, let ly = o["localY"] as? Double {
                model.goto(window: CGWindowID(wid), local: CGPoint(x: lx, y: ly),
                           animated: animated, label: label, pid: pid)
                refreshVisibility()          // 先判可见，再决定画不画
            } else if let x = o["x"] as? Double, let y = o["y"] as? Double {
                model.goto(global: CGPoint(x: x, y: y), animated: animated, label: label, pid: pid)
                model.suppressed = false
            }
        case "move":
            if let x = o["x"] as? Double, let y = o["y"] as? Double {
                model.goto(global: CGPoint(x: x, y: y), animated: false, label: label, pid: pid)
                model.suppressed = false
            }
        case "press", "click":
            model.press(label: label)
        case "feedback":
            model.feedback((o["ok"] as? Bool) ?? true, label: label)
        case "hide":
            model.hide()
        case "vis":
            _ = refreshVisibility()
            if model.anchored, let wid = model.windowId, model.targetPid > 0 {
                visOut = TargetWindowVisibilityManager
                    .report(pid: model.targetPid, windowId: wid, point: model.target).dict
            }
        case "quit":
            model.hide()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { NSApp.terminate(nil) }
        default:
            break
        }
        // 立刻把窗口摆到新位置再返回状态：
        // 只靠 60fps 定时器的话，命令回包里带上的是「上一帧」的位置，
        // 于是「回包里说在 A、屏上其实在 B」，测试和排障都会被误导。
        present()
        var s = model.snapshot
        s["ok"] = true
        s["winW"] = GHOST_WIN_SIZE
        s["winH"] = GHOST_WIN_SIZE
        s["winX"] = round(panel.frame.minX)          // AppKit 坐标（左下原点）
        s["winY"] = round(panel.frame.minY)
        // CG 坐标（左上原点），测试与 CLI 一律用它，避免两套坐标系互相打架
        let primaryH = DisplayCoordinateTransformer
            .primaryHeight(DisplayCoordinateTransformer.liveDisplays())
        s["winCGX"] = round(panel.frame.minX)
        s["winCGY"] = round(primaryH - panel.frame.maxY)
        s["tipX"] = round(model.display.x)
        s["tipY"] = round(model.display.y)
        s["shown"] = windowShown
        s["windowNumber"] = panel.windowNumber
        if !visOut.isEmpty { s["visibility"] = visOut; visOut = [:] }
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
    // ⚠️ 这里不能随便改成 .prohibited。
    //
    // 覆盖层只需要「能画」，不需要「能激活」，所以默认保持 .accessory，
    // 但真正的「不抢前台」是由 ThirdHandOverlay.app 的 LSUIElement 身份保证的
    // （见 v0.4.1 结论：作为普通可激活进程 run() 会顶掉用户前台）。
    // 万一某些系统版本上画不出窗口，可用 WBCU_GHOST_POLICY=prohibited 回退。
    let policy = ProcessInfo.processInfo.environment["WBCU_GHOST_POLICY"] ?? "accessory"
    app.setActivationPolicy(policy == "prohibited" ? .prohibited : .accessory)
    app.isAutomaticCustomizeTouchBarMenuItemEnabled = false
    let controller = CursorController()
    let server = GhostServer(controller: controller)
    controller.setup()
    server.start()

    // 用 CFRunLoopRun() 而不是 app.run()：
    // app.run() 会走 NSApplication 的启动完成流程，其中包含「把自己变成活动应用」，
    // 于是用户的当前前台被顶掉（实测 WorkBuddy → wbcu）。
    // 结论（实测）：
    //   * 绕开 app.run() 用 CFRunLoopRun() → 不抢焦点，但 AppKit 绘制周期起不来，
    //     覆盖层永远透明（窗口在、坐标对、画面空）。
    //   * NSApp.deactivate() → 抢到的激活不会还回去，无效。
    //   * 在 CLI 里还原前台 → 太早，被 daemon 随后的激活覆盖（竞态）。
    // 所以：照常 run()，由 daemon 自己在启动完成后把前台还给用户原来的 App。
    if let raw = ProcessInfo.processInfo.environment["WBCU_GHOST_RESTORE_PID"],
       let restorePid = pid_t(raw) {
        for delay in [0.15, 0.45, 0.9] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard let app = NSRunningApplication(processIdentifier: restorePid),
                      !app.isTerminated else { return }
                if NSWorkspace.shared.frontmostApplication?.processIdentifier != restorePid {
                    app.activate(options: [])
                }
            }
        }
    }
    app.run()
}
