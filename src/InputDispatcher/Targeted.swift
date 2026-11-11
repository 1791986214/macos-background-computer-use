import Foundation
import AppKit
import CoreGraphics
import Darwin

// ============================================================
// 进程级定向投递（Process-targeted dispatch）
//
// 与全局 HID 注入的本质区别：
//   CGEvent.post(tap:)      → 进入系统事件流，由 WindowServer 按光标位置派发
//   CGEvent.postToPid(pid)  → 直接塞进目标进程的事件队列
//
// 但裸投递对 AppKit/SwiftUI/WKWebView 都无效（本机实测 0/3）。
// 必须补上「窗口上下文」：事件字段 51（窗口号）+ 58，或窗口局部坐标。
// 51/58 未文档化，因此每次都要用「UI 是否真的变了」来验证，不能只看投递返回。
// ============================================================

typealias CGSetWindowLocFn = @convention(c) (CGEvent, CGPoint) -> Void

let cgSetWindowLocation: CGSetWindowLocFn? = {
    guard let p = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGEventSetWindowLocation") else { return nil }
    return unsafeBitCast(p, to: CGSetWindowLocFn.self)
}()

let EVFIELD_WINDOW_NUMBER = CGEventField(rawValue: 51)!     // 未文档化：目标窗口号
let EVFIELD_WINDOW_CONTEXT = CGEventField(rawValue: 58)!     // 未文档化：窗口上下文
let EVFIELD_WIN_UNDER_PTR = CGEventField(rawValue: 91)!      // kCGMouseEventWindowUnderMousePointer
let EVFIELD_WIN_HANDLER = CGEventField(rawValue: 92)!        // ...ThatCanHandleThisEvent

/// 定向点击：坐标点用「全局屏幕坐标（左上原点 point）」，内部换算成窗口局部坐标
func targetedClick(at globalPoint: CGPoint,
                   pid: pid_t,
                   windowId: CGWindowID,
                   windowFrame: CGRect,
                   button: String = "left",
                   clickCount: Int = 1) {
    let local = windowLocal(from: globalPoint, in: windowFrame)

    let (down, up, btn): (CGEventType, CGEventType, CGMouseButton) = {
        switch button.lowercased() {
        case "right", "r": return (.rightMouseDown, .rightMouseUp, .right)
        case "middle", "m": return (.otherMouseDown, .otherMouseUp, .center)
        default: return (.leftMouseDown, .leftMouseUp, .left)
        }
    }()

    func mk(_ type: CGEventType, _ state: Int64) -> CGEvent? {
        guard let e = CGEvent(mouseEventSource: nil, mouseType: type,
                              mouseCursorPosition: globalPoint, mouseButton: btn) else { return nil }
        e.setIntegerValueField(.mouseEventClickState, value: state)
        e.setIntegerValueField(EVFIELD_WINDOW_NUMBER, value: Int64(windowId))
        e.setIntegerValueField(EVFIELD_WINDOW_CONTEXT, value: 12345)
        e.setIntegerValueField(EVFIELD_WIN_UNDER_PTR, value: Int64(windowId))
        e.setIntegerValueField(EVFIELD_WIN_HANDLER, value: Int64(windowId))
        cgSetWindowLocation?(e, local)
        return e
    }

    // 预热：先投一个带窗口上下文的 mouseMoved。
    // 非激活窗口的第一次 mouseDown 常被系统吞掉用于「激活」，预热可避开这个坑。
    if let primer = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                            mouseCursorPosition: globalPoint, mouseButton: .left) {
        primer.setIntegerValueField(EVFIELD_WINDOW_NUMBER, value: Int64(windowId))
        primer.setIntegerValueField(EVFIELD_WINDOW_CONTEXT, value: 12345)
        cgSetWindowLocation?(primer, local)
        primer.postToPid(pid)
        usleep(35_000)
    }

    for i in 1...max(1, clickCount) {
        mk(down, Int64(i))?.postToPid(pid)
        usleep(28_000)
        mk(up, Int64(i))?.postToPid(pid)
        if i < clickCount { usleep(80_000) }
    }
}

/// 定向拖拽：Down → 若干 Dragged → Up，全部带窗口上下文
func targetedDrag(from a: CGPoint, to b: CGPoint,
                  pid: pid_t, windowId: CGWindowID, windowFrame: CGRect) {
    func mk(_ type: CGEventType, _ p: CGPoint) -> CGEvent? {
        guard let e = CGEvent(mouseEventSource: nil, mouseType: type,
                              mouseCursorPosition: p, mouseButton: .left) else { return nil }
        e.setIntegerValueField(.mouseEventClickState, value: 1)
        e.setIntegerValueField(EVFIELD_WINDOW_NUMBER, value: Int64(windowId))
        e.setIntegerValueField(EVFIELD_WINDOW_CONTEXT, value: 12345)
        cgSetWindowLocation?(e, windowLocal(from: p, in: windowFrame))
        return e
    }
    mk(.leftMouseDown, a)?.postToPid(pid)
    let steps = 16
    for i in 1...steps {
        let t = Double(i) / Double(steps)
        let p = CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
        mk(.leftMouseDragged, p)?.postToPid(pid)
        usleep(11_000)
    }
    mk(.leftMouseUp, b)?.postToPid(pid)
}

// MARK: - 结果验证器
//
// 投递成功 ≠ 操作成功。必须观察目标 UI 真的变了。
// 这里用「AX 树指纹」做前后对比：对同一 pid 取 (role|title|value|enabled) 的稳定摘要。

func axFingerprint(pid: pid_t, maxNodes: Int = 600) -> (hash: String, nodes: Int) {
    let snap = walkAX(pid: pid, maxDepth: 14, maxNodes: maxNodes, includeActions: false, skipMenuBar: true)
    var h = 5381
    for it in snap.items {
        for ch in (it.role + "|" + it.title + "|" + it.value + "|" + it.desc) .unicodeScalars {
            h = (h &* 33) &+ Int(ch.value & 0xFFFF)
        }
    }
    return (String(format: "%08x", h & 0xFFFFFFF), snap.items.count)
}

// MARK: - Agent Cursor 客户端（三层中的「可视化」层）
//
// 注意：这里只发命令、读状态，不参与投递。可视化层挂掉，投递照常。

let GHOST_SOCK_PATH = "/tmp/wbcu-ghost.sock"

func ghostDaemonAlive() -> Bool { FileManager.default.fileExists(atPath: GHOST_SOCK_PATH) }

/// 发一条命令并读取 daemon 回写的状态行（超时返回 nil）
@discardableResult
func ghostCall(_ payload: [String: Any], timeoutMs: Int = 900) -> [String: Any]? {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(GHOST_SOCK_PATH.utf8)
    withUnsafeMutablePointer(to: &addr.sun_path) { p in
        p.withMemoryRebound(to: CChar.self, capacity: 104) { dst in
            for (i, b) in bytes.enumerated() where i < 103 { dst[i] = CChar(bitPattern: b) }
        }
    }
    let size = socklen_t(MemoryLayout<sockaddr_un>.size)
    let rc = withUnsafePointer(to: &addr) { p in
        p.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, size) }
    }
    guard rc == 0 else { close(fd); return nil }

    if let d = try? JSONSerialization.data(withJSONObject: payload),
       let s = String(data: d, encoding: .utf8) {
        _ = (s + "\n").withCString { write(fd, $0, strlen($0)) }
    }

    // 非阻塞读，最多等 timeoutMs
    var tv = timeval(tv_sec: timeoutMs / 1000, tv_usec: Int32((timeoutMs % 1000) * 1000))
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    var buf = [UInt8](repeating: 0, count: 4096)
    let n = read(fd, &buf, buf.count)
    close(fd)
    guard n > 0, let obj = try? JSONSerialization.jsonObject(with: Data(buf[0..<n])) as? [String: Any] else { return nil }
    return obj
}

func ensureGhostDaemon() {
    if ghostDaemonAlive(), ghostCall(["op": "ping"], timeoutMs: 300) != nil { return }
    try? FileManager.default.removeItem(atPath: GHOST_SOCK_PATH)
    let exe = CommandLine.arguments[0]
    let path = exe.hasPrefix("/") ? exe : (FileManager.default.currentDirectoryPath + "/" + exe)
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = ["ghost", "daemon"]
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    try? p.run()
    for _ in 0..<50 {
        if ghostDaemonAlive(), ghostCall(["op": "ping"], timeoutMs: 300) != nil { return }
        usleep(50_000)
    }
}

func ghostGoto(window: CGWindowID, local: CGPoint, animated: Bool = true, label: String = "") -> [String: Any]? {
    ensureGhostDaemon()
    return ghostCall(["op": "goto", "windowId": Int(window), "localX": local.x, "localY": local.y,
                      "animate": animated, "label": label])
}

func ghostGoto(global p: CGPoint, animated: Bool = false, label: String = "") -> [String: Any]? {
    ensureGhostDaemon()
    return ghostCall(["op": "goto", "x": p.x, "y": p.y, "animate": animated, "label": label])
}

func ghostPress(_ label: String = "") -> [String: Any]? { ghostCall(["op": "press", "label": label]) }
func ghostFeedback(_ ok: Bool, _ label: String = "") -> [String: Any]? {
    ghostCall(["op": "feedback", "ok": ok, "label": label])
}
func ghostHide() { if ghostDaemonAlive() { ghostCall(["op": "hide"], timeoutMs: 300) } }

// MARK: - 一站式动作：光标 → 投递 → 观察 → 反馈
//
// 三层协同的唯一入口。任何一层不可用都降级而不是失败：
//   光标不可用 → 照常投递（只是看不见）
//   观察不可用 → 照常投递（只是无法验证）
// MARK: - 动作执行（v2：可控光标模式 + 事件驱动验证 + 分阶段计时）

struct ActionOptions {
    var showCursor = true
    /// fast  = 输入优先，动画并行（默认，延迟最低）
    /// normal= 短动画后投递，兼顾观感
    /// demo  = 完整动画后再投递，适合录屏/演示
    var cursorMode = "fast"
    var verify = true
    var allowAX = true
    var preResolved: AXUIElement? = nil      // 经验命中，跳过定位
    var observeElement: AXUIElement? = nil   // 已知「会变的元素」，走事件驱动验证
    /// 观测超时。UI 更新通常在 100ms 内；给 400ms 足够，
    /// 再长就变成「用固定睡眠换安心」，反而不如直接退回指纹对比。
    var observeTimeoutMs = 400
    /// 会话里上一次已知的整树指纹。用于「观测元素没变」时的兜底，
    /// 只扫一次树即可判断「别处有没有变」，比前后各扫一次省一半。
    var baselineFingerprint: String? = nil
}

struct ActionOutcome {
    var mode = "targeted"
    var escalated = false
    var axErr = ""
    var changed: Bool? = nil
    var verification = "not_requested"
    var via = ""
    var timing = StageTiming()
    var cursorInfo: [String: Any] = ["used": false]
    /// 本次动作后的整树指纹；调用方存回会话，供下一次做基线
    var fingerprintAfter: String? = nil
    /// 观测元素超时（说明这条经验不可靠），调用方应把它从经验里剔掉
    var observeStale = false
}

func performAgentAction(global point: CGPoint,
                        pid: pid_t,
                        windowId: CGWindowID,
                        windowFrame: CGRect,
                        label: String,
                        options: ActionOptions) -> ActionOutcome {
    let tStart = nowNs()
    var out = ActionOutcome()
    let local = windowLocal(from: point, in: windowFrame)

    // ---- ① 定位目标元素 ----
    var tMark = nowNs()
    var element = options.preResolved
    if element == nil, options.allowAX {
        element = findPressableElement(pid: pid, at: point)
    }
    out.timing.resolve = msSince(tMark)

    // ---- ② 光标动画（与输入解耦）----
    // 关键改动：旧实现先等 260ms 动画再发点击，把「给人看」的成本压进了关键路径。
    // 现在 fast 模式先投递、动画并行跑，视觉层永远不阻塞执行层。
    if options.showCursor {
        if let st = ghostGoto(window: windowId, local: local, animated: true, label: label) {
            out.cursorInfo = ["used": true, "anchored": st["anchored"] ?? false,
                              "windowId": st["windowId"] ?? 0, "phase": st["phase"] ?? ""]
        }
        tMark = nowNs()
        switch options.cursorMode {
        case "demo":   usleep(260_000)      // 完整动画
        case "normal": usleep(90_000)       // 只等个起势
        default:       break                // fast：不等
        }
        out.timing.cursor = msSince(tMark)
    }

    // ---- ③ 投递输入 ----
    tMark = nowNs()
    var fpBefore: (String, Int)? = nil
    if options.verify && options.observeElement == nil {
        // 只有走指纹兜底时才需要先扫一遍树
        fpBefore = axFingerprint(pid: pid)
    }

    if let el = element {
        let r = AXUIElementPerformAction(el, kAXPressAction as CFString)
        if r == .success { out.mode = "ax" } else { out.axErr = axErrorName(r) }
    }

    if out.mode != "ax" {
        targetedClick(at: point, pid: pid, windowId: windowId,
                      windowFrame: windowFrame, button: "left", clickCount: 1)
        out.escalated = (!options.allowAX || element == nil) ? false : true
        out.mode = "targeted"
    }
    if options.showCursor { _ = ghostPress(label) }
    out.timing.dispatch = msSince(tMark)

    // ---- ④ 验证 ----
    // 两级策略：
    //   ① 已知「会变的元素」→ 盯它（20~60ms）
    //   ② 没变 / 不知道盯谁 → 整树指纹兜底
    // 兜底是必须的：只盯一个元素会把「别处变了」误判成「什么都没变」。
    tMark = nowNs()
    if options.verify {
        var resolved = false
        if let obs = options.observeElement {
            let w = waitForElementChange(pid: pid, element: obs, timeoutMs: options.observeTimeoutMs)
            if w.changed {
                out.changed = true
                out.via = w.via
                resolved = true
            } else {
                out.via = "observe-timeout"
                out.observeStale = true
            }
        }
        if !resolved {
            let after = axFingerprint(pid: pid)
            out.fingerprintAfter = after.hash
            if let base = options.baselineFingerprint, !base.isEmpty {
                out.changed = after.hash != base
                out.via = out.via == "observe-timeout" ? "observe-timeout+fingerprint" : "fingerprint"
            } else if let before = fpBefore {
                out.changed = after.hash != before.0
                out.via = "fingerprint"
            }
        }
        out.verification = out.changed == nil ? "not_requested"
            : (out.changed! ? "changed" : "no_observable_change")
    }
    out.timing.verify = msSince(tMark)

    if options.showCursor {
        _ = ghostFeedback(out.changed ?? true, out.changed == false ? "no change" : label)
    }
    out.timing.total = msSince(tStart)
    return out
}

// MARK: - 兼容别名（旧命令名）
func ghostMove(_ p: CGPoint) { _ = ghostGoto(global: p, animated: false) }
func ghostClick(_ p: CGPoint, _ label: String) {
    _ = ghostGoto(global: p, animated: false, label: label)
    _ = ghostPress(label)
}

// MARK: - 按坐标在目标应用内找可 AX 按下的元素
//
// 系统级 hit-test 返回「该点最上层」的元素，遮挡时会返回遮挡者的元素。
// 后台点击必须**在目标应用自己的树里**找。
func findPressableElement(pid: pid_t, at point: CGPoint) -> AXUIElement? {
    var best: (el: AXUIElement, area: CGFloat)? = nil
    var visited = 0
    func visit(_ el: AXUIElement, _ depth: Int) {
        if visited > 4000 || depth > 16 { return }
        visited += 1
        if let pos = axPoint(el, kAXPositionAttribute), let size = axSize(el, kAXSizeAttribute) {
            let rect = CGRect(origin: pos, size: size)
            if rect.contains(point), size.width > 0, size.height > 0 {
                let acts = axActions(el)
                if acts.contains(kAXPressAction as String) || acts.contains("AXConfirm") {
                    let area = size.width * size.height
                    if best == nil || area < best!.area { best = (el, area) }
                }
            }
        }
        for k in axChildren(el) { visit(k, depth + 1) }
    }
    visit(appElement(pid), 0)
    return best?.el
}

// MARK: - ghost 子命令
func cmdGhost(_ args: Args) {
    gJSONMode = args.flag("json")
    let sub = args.positional.first ?? "status"
    switch sub {
    case "daemon":
        runGhostDaemon()
        exit(0)
    case "start":
        ensureGhostDaemon()
        emitText("✅ Agent Cursor 已就绪 (\(GHOST_SOCK_PATH))")
        exit(0)
    case "move", "goto":
        let r = ghostGoto(global: CGPoint(x: args.dbl("x") ?? 0, y: args.dbl("y") ?? 0),
                          animated: args.flag("animate"), label: args.str("label") ?? "")
        if gJSONMode { emit(r ?? ["ok": false]) } else { emitText("✅ cursor → (\(args.dbl("x") ?? 0), \(args.dbl("y") ?? 0))") }
        exit(0)
    case "click":
        _ = ghostPress(args.str("label") ?? "click")
        if gJSONMode { emit(["ok": true]) } else { emitText("✅ cursor press") }
        exit(0)
    case "feedback":
        let ok = args.str("ok") != "0" && !args.flag("fail")
        _ = ghostFeedback(ok, args.str("label") ?? "")
        if gJSONMode { emit(["ok": true]) } else { emitText(ok ? "✅ feedback ok" : "✅ feedback fail") }
        exit(0)
    case "hide":
        ghostHide()
        if gJSONMode { emit(["ok": true]) } else { emitText("✅ cursor hidden") }
        exit(0)
    case "stop":
        _ = ghostCall(["op": "quit"], timeoutMs: 500)
        try? FileManager.default.removeItem(atPath: GHOST_SOCK_PATH)
        emitText("✅ Agent Cursor daemon 已停止")
        exit(0)
    default:
        let st = ghostCall(["op": "state"], timeoutMs: 400)
        if gJSONMode { emit(st ?? ["ok": true, "alive": ghostDaemonAlive()]) }
        else if let s = st { emitText("cursor: \(s)") }
        else { emitText("Agent Cursor daemon: \(ghostDaemonAlive() ? "运行中" : "未启动")") }
        exit(0)
    }
}

// MARK: - 一站式动作命令
func cmdAct(_ args: Args) {
    gJSONMode = args.flag("json")
    gPretty = args.flag("pretty")
    let p = mousePointFromArgs(args)
    var (pid, wid) = inputTarget(args)
    let label = args.str("label") ?? "click"
    let showCursor = !args.flag("no-ghost")
    let verify = !args.flag("no-verify")
    let allowAX = (args.str("mode") ?? "auto") != "targeted"

    var winFrame: CGRect? = nil
    let allWins = listCGWindows(onScreenOnly: false)
    if let w = wid, let rec = allWins.first(where: { $0.id == w }) {
        winFrame = rec.bounds; pid = rec.pid
    } else if let pd = pid, let best = allWins.filter({ $0.pid == pd && $0.bounds.contains(p) })
        .min(by: { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }) {
        wid = best.id; winFrame = best.bounds
    }
    guard let pd = pid, let w = wid, let f = winFrame else {
        fail("找不到目标窗口：用 --window <id> 或 --app <bundleId>", code: 5)
    }
    enforceGuard(pid: pd, action: "act")

    var opts = ActionOptions()
    opts.showCursor = showCursor
    opts.verify = verify
    opts.allowAX = allowAX
    opts.cursorMode = (args.str("ghost-mode") ?? "fast").lowercased()
    let outcome = performAgentAction(global: p, pid: pd, windowId: w, windowFrame: f,
                                     label: label, options: opts)
    let loc = windowLocal(from: p, in: f)
    var res: [String: Any] = [
        "ok": true, "mode": outcome.mode, "escalatedFromAX": outcome.escalated,
        "axError": outcome.axErr, "windowId": Int(w), "pid": Int(pd),
        "global": ["x": p.x, "y": p.y], "windowLocal": ["x": loc.x, "y": loc.y],
        "cursor": outcome.cursorInfo, "verification": outcome.verification,
        "verifyVia": outcome.via, "timing": outcome.timing.dict(), "pointerMoved": false
    ]
    if let c = outcome.changed { res["uiChanged"] = c }
    if gJSONMode { emit(res) }
    else {
        let cur = (outcome.cursorInfo["used"] as? Bool) ?? false
        emitText("✅ \(outcome.mode) @(\(Int(p.x)),\(Int(p.y)))  cursor=\(cur ? "shown" : "off")  "
                 + "verify=\(outcome.verification)  \(Int(outcome.timing.total))ms")
    }
    exit(0)
}
