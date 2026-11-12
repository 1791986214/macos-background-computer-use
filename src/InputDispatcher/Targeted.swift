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

/// 找覆盖层 bundle 的可执行文件（不存在就回退到当前二进制）
func ghostOverlayBundleExecutable() -> String? {
    let candidates = [
        FileManager.default.currentDirectoryPath + "/build/ThirdHandOverlay.app/Contents/MacOS/wbcu",
        NSHomeDirectory() + "/.local/share/wbcu/ThirdHandOverlay.app/Contents/MacOS/wbcu"
    ]
    for c in candidates where FileManager.default.isExecutableFile(atPath: c) { return c }
    return nil
}

func ensureGhostDaemon() {
    if ghostDaemonAlive(), ghostCall(["op": "ping"], timeoutMs: 300) != nil { return }
    // 记下用户当前的前台 App，通过环境变量交给 daemon：
    // daemon 是个 NSApplication，启动完成后会被系统激活（前台变成 wbcu）。
    // 由 daemon 自己在「启动完成」之后还原前台，顺序才确定 ——
    // 在 CLI 这边还原会因为时机太早而被 daemon 随后的激活覆盖（实测竞态）。
    let frontBefore = NSWorkspace.shared.frontmostApplication
    try? FileManager.default.removeItem(atPath: GHOST_SOCK_PATH)
    // 优先用 LSUIElement bundle 里的可执行文件：
    // 它是「代理型 App」，NSApp.run() 渲染窗口但不会把自己激活，从根上不抢前台。
    let bundleExe = ghostOverlayBundleExecutable()
    let exe = bundleExe ?? CommandLine.arguments[0]
    let path = exe.hasPrefix("/") ? exe : (FileManager.default.currentDirectoryPath + "/" + exe)
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = ["ghost", "daemon"]
    var env = ProcessInfo.processInfo.environment
    if let pid = frontBefore?.processIdentifier, pid != getpid() {
        env["WBCU_GHOST_RESTORE_PID"] = String(pid)
    }
    p.environment = env
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    try? p.run()
    for _ in 0..<50 {
        if ghostDaemonAlive(), ghostCall(["op": "ping"], timeoutMs: 300) != nil {
            // 前台还原由 daemon 自己完成（见 runGhostDaemon），这里只等它就绪
            return
        }
        usleep(50_000)
    }
}

func ghostGoto(window: CGWindowID, local: CGPoint, animated: Bool = true,
               label: String = "", pid: pid_t = 0) -> [String: Any]? {
    ensureGhostDaemon()
    var payload: [String: Any] = ["op": "goto", "windowId": Int(window),
                                  "localX": local.x, "localY": local.y,
                                  "animate": animated, "label": label]
    // 把目标 pid 一起给 daemon：它要用这个 pid 判断「目标现在是不是前台」，
    // 以及这个点有没有被别人的窗口盖住 —— 决定画不画光标。
    if pid > 0 { payload["pid"] = Int(pid) }
    return ghostCall(payload)
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
    /// v0.4.3：显式期望。「做对了没有」由它裁决，而不是靠「UI 变没变」猜。
    var expectation: StateExpectation? = nil
    /// 目标应用的 bundleId（兼容层按应用退让，需要它）
    var appBundle = ""
    /// 是否做焦点取证。每次 AX IPC 实测 ~27ms，两次就是 54ms，
    /// 属于诊断而非必需 —— 默认关闭，并发/隔离类测试用 `--focus-check` 打开。
    var trackFocus = false
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

    // ── v0.4.2 新增：把「投递」和「成功」彻底分开 ──────────────
    /// 事件的最终裁决。false 表示「我不认为这件事做成了」，调用方必须如实上报。
    var ok = true
    /// 事件是否真的进了目标进程（投递层的事）
    var delivered = false
    /// 没做成的具体原因；空串表示没有失败
    var failureReason = ""
    /// 动手之前目标窗口处于什么状态
    var visibility = VisibilityReport()
    /// 用户的当前前台 App 有没有被顶掉。
    /// nil = 动作期间检测到真实硬件输入 → 变化归属不明，不做断言（不是失败）
    var frontAppPreserved: Bool? = true
    /// 物理鼠标有没有被挪动。nil 同上
    var physicalCursorPreserved: Bool? = true
    /// 动作窗口内是否有真实硬件输入（用于解释上面两个 nil）
    var userInputDuringAction = false
    var frontBefore = ""
    var frontAfter = ""

    // ── v0.4.3：期望状态验证 + 焦点取证 ──────────────────────
    /// 四分类结论：success / already_satisfied / failure / inconclusive
    var verifyReport: VerifyReport? = nil
    /// 与 verifyReport.result 同义的短名，便于 CLI 直接打
    var result = "inconclusive"
    var focusBefore: FocusState? = nil
    var focusAfter: FocusState? = nil
    /// 目标应用的 keyWindow 有没有被我们改掉
    /// 目标 keyWindow/第一响应者是否保持。nil = 未做焦点取证（不宣称）
    var targetFocusPreserved: Bool? = nil
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

    // ---- ⓪ 先记录「不该被我改变的东西」----
    // 这两条是硬约束：用户的物理鼠标、用户的当前前台 App。
    // 任何一个被动过，都要在结果里如实标出来，而不是让它悄悄发生。
    let frontAppBefore = NSWorkspace.shared.frontmostApplication
    let mouseBefore = CGEvent(source: nil)?.location ?? .zero
    out.frontBefore = frontAppBefore?.bundleIdentifier ?? ""

    // ---- ① 目标窗口现在是什么状态 ----
    // 只做一次窗口列表快照（O(n)），不做高频轮询。
    let tVis = nowNs()
    out.visibility = TargetWindowVisibilityManager.report(
        pid: pid, windowId: windowId, point: point,
        frontPid: frontAppBefore?.processIdentifier)
    out.timing.visibility = msSince(tVis)

    // ---- ①b 焦点取证：用户的键盘焦点有没有被动过 ----
    // 只看 frontmostApp 不够：应用还在前台，但 key window / 第一响应者被换掉，
    // 用户立刻就能感觉到（打字跑进别的窗口）。
    let tFocus = nowNs()
    if options.trackFocus { out.focusBefore = FocusProbe.read(pid: pid) }

    // ---- ①c 兼容层：这个应用该不该「AX 优先」 ----
    // 未验证的 macOS 大版本、或连续投递失败 3 次被降级过的应用，
    // 一律先试 AXPress（可验证），坐标投递只作兜底。
    let allowAXNow = options.allowAX || EventFieldCompat.preferAX(app: options.appBundle)

    // ---- ①d 期望状态的前置读数 ----
    // 必须在投递之前读，否则「本来就满足」和「点了才满足」分不开。
    var preState: ElementReadout? = nil
    if let exp = options.expectation, exp.value != nil {
        let (pre, _) = ExpectedStateVerifier.locate(pid: pid, hint: exp.elementHint)
        preState = pre
    }
    out.timing.focus = msSince(tFocus)

    // ---- ② 定位目标元素 ----
    var tMark = nowNs()
    var element = options.preResolved
    if element == nil, allowAXNow {
        element = findPressableElement(pid: pid, at: point)
    }
    out.timing.resolve = msSince(tMark)

    // ---- ② 光标动画（与输入解耦）----
    // 关键改动：旧实现先等 260ms 动画再发点击，把「给人看」的成本压进了关键路径。
    // 现在 fast 模式先投递、动画并行跑，视觉层永远不阻塞执行层。
    if options.showCursor {
        if let st = ghostGoto(window: windowId, local: local, animated: true, label: label, pid: pid) {
            out.cursorInfo = ["used": true, "anchored": st["anchored"] ?? false,
                              "windowId": st["windowId"] ?? 0, "phase": st["phase"] ?? "",
                              "suppressed": st["suppressed"] ?? false,
                              "winW": st["winW"] ?? 0, "winH": st["winH"] ?? 0]
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
    // 指纹要在计时之外扫：它是「验证」的成本，不该算进「投递」。
    // 有显式期望时干脆不扫整树 —— 状态元素的前后读数已经能判断变化，省 60~90ms。
    var fpBefore: (String, Int)? = nil
    let hasExplicitExpect = !(options.expectation?.value ?? "").isEmpty
    let needFingerprint = options.verify && options.observeElement == nil
        && !hasExplicitExpect && options.baselineFingerprint == nil
    if needFingerprint { fpBefore = axFingerprint(pid: pid) }
    tMark = nowNs()

    if let el = element {
        let r = AXUIElementPerformAction(el, kAXPressAction as CFString)
        if r == .success { out.mode = "ax"; out.delivered = true } else { out.axErr = axErrorName(r) }
    }

    if out.mode != "ax" {
        // 坐标投递是「进程级」的：事件直接进目标进程的事件队列，
        // 由事件自带的窗口号决定落到哪个窗口 —— 因此目标窗口被别的应用盖住
        // 并不会让事件落到遮挡者身上（实测：完全遮挡下仍能点中）。
        // 这条结论只在 AppKit 原生控件上成立；WKWebView 一类自建事件管线的
        // 视图不保证，所以真正算不算成功一律以「UI 有没有变」为准。
        targetedClick(at: point, pid: pid, windowId: windowId,
                      windowFrame: windowFrame, button: "left", clickCount: 1)
        out.escalated = (!options.allowAX || element == nil) ? false : true
        out.mode = "targeted"
        out.delivered = true
    }
    out.timing.dispatch = msSince(tMark)
    // 光标按下反馈是「可视化」动作，走 socket 到 daemon，实测 50~70ms。
    // 它不属于输入路径，不能算进 dispatch —— 否则每次点击都被虚报成慢 70ms。
    if options.showCursor { _ = ghostPress(label) }

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
        if !resolved, hasExplicitExpect, let pre = preState, pre.found {
            // 有显式期望：重读一次状态元素判断「有没有变」，不扫整树（省 60~90ms）
            let now = ExpectedStateVerifier.readPath(pid: pid, path: pre.path)
            out.changed = now.found && ExpectedStateVerifier.normalize(now.stateValue)
                != ExpectedStateVerifier.normalize(pre.stateValue)
            out.via = "ax-state-diff"
            resolved = true
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

        // ④b 期望状态裁决：有显式期望时，它覆盖「变没变」这条弱判据。
        //     这才是「点 7 看是不是 7」——变了但不是 7，就是失败。
        if let exp = options.expectation {
            var pre = preState ?? ElementReadout(found: false)
            var actual = ElementReadout(found: false)
            if pre.found, let want = exp.value, !want.isEmpty {
                let (a, waited) = ExpectedStateVerifier.waitFor(
                    pid: pid, path: pre.path, expected: want,
                    mode: exp.match, timeoutMs: exp.maxWaitMs)
                actual = a
                if waited > 0 { out.via = out.via.isEmpty ? "ax-state" : out.via + "+ax-state" }
            } else if pre.found {
                // 只给了「变了」类期望：读一次当前值作为 actual
                actual = ExpectedStateVerifier.readPath(pid: pid, path: pre.path)
            }
            // 前置状态在投递前读过；若没读到，说明状态元素定位失败 → 如实标 inconclusive
            if !pre.found { pre = ElementReadout(found: false) }
            out.verifyReport = ExpectedStateVerifier.evaluate(
                expectation: exp, pre: pre, actual: actual,
                changed: out.changed, delivered: out.delivered,
                failureReason: out.changed == false ? failureReasonFor(out) : "",
                targetDesc: "\(options.appBundle)#\(windowId)@(\(Int(point.x)),\(Int(point.y)))",
                actionDesc: "\(out.mode)\(out.escalated ? "(escalated)" : "")")
        }
    }
    out.timing.verify = msSince(tMark)

    // ---- ⑤ 裁决 ----
    // v0.4.3：裁决权交给 ExpectedStateVerifier，四分类：
    //   success / already_satisfied / failure / inconclusive
    // 老的「变了就算成功、没变就算失败」只在没有显式期望时作为弱判据存在，
    // 且「没变」现在给的是 inconclusive —— 因为幂等操作本来就该没变化。
    if out.verifyReport == nil {
        var pre = ElementReadout(found: false)
        var actual = ElementReadout(found: false)
        if let exp = options.expectation, preState?.found == true {
            pre = preState!
            actual = ExpectedStateVerifier.readPath(pid: pid, path: pre.path)
        }
        out.verifyReport = ExpectedStateVerifier.evaluate(
            expectation: options.expectation ?? StateExpectation(),
            pre: pre, actual: actual, changed: out.changed, delivered: out.delivered,
            failureReason: out.changed == false ? failureReasonFor(out) : "",
            targetDesc: "\(options.appBundle)#\(windowId)@(\(Int(point.x)),\(Int(point.y)))",
            actionDesc: out.mode)
    }
    out.result = out.verifyReport?.result.rawValue ?? "inconclusive"
    out.ok = out.verifyReport?.result.ok ?? false
    if !out.ok && out.failureReason.isEmpty {
        out.failureReason = out.changed == false ? failureReasonFor(out)
            : (out.delivered ? "verification_inconclusive" : "not_delivered")
    }

    // ---- ⑥ 焦点自检：目标的 keyWindow 有没有被我们改掉 ----
    if options.trackFocus {
        out.focusAfter = FocusProbe.read(pid: pid)
        if let b = out.focusBefore, let a = out.focusAfter, b.readable, a.readable {
            out.targetFocusPreserved = (b.keyWindowId == a.keyWindowId)
                && (b.focusedRole == a.focusedRole)
                && (b.focusedIdentifier == a.focusedIdentifier)
        }
    }

    // ---- ⑦ 兼容层记账：坐标投递到底靠不靠得住 ----
    if out.mode == "targeted", !options.appBundle.isEmpty {
        let good = (out.result == "success")
        EventFieldCompat.record(app: options.appBundle, targetedVerified: good)
    }

    // ---- ⑥ 硬约束自检：有没有动到不该动的东西 ----
    out.frontAfter = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
    let mouseAfter = CGEvent(source: nil)?.location ?? .zero
    let moved = hypot(mouseAfter.x - mouseBefore.x, mouseAfter.y - mouseBefore.y)
    let elapsedSec = out.timing.total > 0 ? out.timing.total / 1000 : 0.2

    // 动作窗口内有没有**真实硬件**输入？
    // 有的话，「鼠标动了」「前台变了」都可能只是用户自己在动/在切 ——
    // 这时候断言「是我动的」是错的，断言「不是我动的」也无从证明。
    // 我们的合成事件走 postToPid，不进 HID 流，所以这个探针只统计真实输入。
    let sinceMove = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .mouseMoved)
    let sinceClick = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .leftMouseDown)
    let sinceKey = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .keyDown)
    let userBusy = min(sinceMove, sinceClick, sinceKey) < elapsedSec + 0.05
    out.userInputDuringAction = userBusy

    if userBusy {
        // 归属不明：不宣称「保持」，也不宣称「破坏」
        out.frontAppPreserved = (out.frontBefore == out.frontAfter) ? true : nil
        out.physicalCursorPreserved = moved < 1.5 ? true : nil
    } else {
        out.frontAppPreserved = (out.frontBefore == out.frontAfter)
        out.physicalCursorPreserved = moved < 1.5
    }

    if options.showCursor {
        _ = ghostFeedback(out.changed ?? true, out.changed == false ? "no change" : label)
    }
    out.timing.total = msSince(tStart)
    return out
}

/// 没做成的时候把「为什么」说清楚，而不是返回一个含糊的 ok
func failureReasonFor(_ out: ActionOutcome) -> String {
    let v = out.visibility
    if v.state == .minimized { return "target_minimized" }
    if v.state == .offScreen { return "target_off_screen" }
    if v.state == .unknown { return "target_window_gone" }
    if out.mode == "ax" { return "ax_press_no_observable_change" }
    if !v.targetIsAppFrontWindow { return "targeted_window_not_key_no_effect" }
    if !v.targetIsFrontApp { return "targeted_background_no_effect" }
    return "targeted_no_observable_change"
}

// MARK: - 统一结果报告
//
// 一次动作的输出必须是「可审计的事实」，而不是一句 ok。
// 字段语义：
//   delivered              事件有没有真的进目标进程
//   verified               UI 有没有真的变（null = 没要求验证）
//   ok                     我的最终裁决 = verified，未验证时退化为 delivered
//   method                 ax / targeted
//   failureReason          没做成的原因（ok=false 时非空）
//   frontAppPreserved      用户前台有没有被顶掉
//   physicalCursorPreserved 物理鼠标有没有被挪动
func actionReport(_ o: ActionOutcome, windowId: CGWindowID, pid: pid_t,
                  point: CGPoint, frame: CGRect) -> [String: Any] {
    let loc = windowLocal(from: point, in: frame)
    var r: [String: Any] = [
        "ok": o.ok,
        "delivered": o.delivered,
        "verified": o.changed.map { $0 as Any } ?? NSNull(),
        "method": o.mode,
        "mode": o.mode,                       // 兼容旧字段名
        "failureReason": o.failureReason,
        "targetWindowId": Int(windowId),
        "targetPid": Int(pid),
        "windowId": Int(windowId),            // 兼容旧字段名
        "pid": Int(pid),                      // 兼容旧字段名
        "escalatedFromAX": o.escalated,
        "axError": o.axErr,
        "global": ["x": point.x, "y": point.y],
        "windowLocal": ["x": loc.x, "y": loc.y],
        "cursor": o.cursorInfo,
        "verification": o.verification,
        "verifyVia": o.via,
        "visibility": o.visibility.dict,
        "frontBefore": o.frontBefore,
        "frontAfter": o.frontAfter,
        "physicalCursorPreserved": o.physicalCursorPreserved.map { $0 as Any } ?? NSNull(),
        "frontAppPreserved": o.frontAppPreserved.map { $0 as Any } ?? NSNull(),
        "userInputDuringAction": o.userInputDuringAction,
        "pointerMoved": o.physicalCursorPreserved == false,
        "result": o.result,                   // success / already_satisfied / failure / inconclusive
        "targetFocusPreserved": o.targetFocusPreserved.map { $0 as Any } ?? NSNull(),
        "timing": o.timing.dict()
    ]
    if let c = o.changed { r["uiChanged"] = c }
    if let f = o.focusBefore { r["focusBefore"] = f.dict }
    if let f = o.focusAfter { r["focusAfter"] = f.dict }
    if let rep = o.verifyReport { r["verificationReport"] = rep.dict }
    return r
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

// MARK: - 可见性查询命令（`wbcu vis`）
//
// 单独暴露出来，是为了让回归测试能直接问「这个点现在归谁」，
// 而不必通过一次真实点击去反推。它只读，不做任何改变。
func cmdVis(_ args: Args) {
    gJSONMode = args.flag("json")
    var (pid, wid) = inputTarget(args)
    let x = args.dbl("x"), y = args.dbl("y")
    guard let w = wid else { fail("需要 --window <id>", code: 5) }
    let all = listCGWindows(onScreenOnly: false)
    guard let rec = all.first(where: { $0.id == w }) else { fail("找不到窗口 \(w)", code: 5) }
    if pid == nil { pid = rec.pid }
    guard let pd = pid else { fail("无法确定目标 pid", code: 5) }
    let pt: CGPoint? = (x != nil && y != nil) ? CGPoint(x: x!, y: y!) : nil
    let r = TargetWindowVisibilityManager.report(pid: pd, windowId: w, point: pt)
    var res = r.dict
    res["ok"] = true
    res["windowId"] = Int(w)
    res["pid"] = Int(pd)
    res["human"] = TargetWindowVisibilityManager.humanNote(r)
    res["windowFrame"] = ["x": rec.bounds.minX, "y": rec.bounds.minY,
                          "w": rec.bounds.width, "h": rec.bounds.height]
    if gJSONMode { emit(res) } else {
        emitText("窗口 \(w) (\(rec.owner)) → \(r.state.rawValue)：\(res["human"] ?? "")"
                 + (pt != nil ? "  点(\(Int(x!)),\(Int(y!))) 可见=\(r.pointVisible)" : ""))
    }
    exit(0)
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
        // 支持窗口锚定模式：--window <id> --localX --localY
        // （锚定才是生产路径；之前 CLI 只暴露全局模式，测试想验锚定行为只能绕道 act）
        var r: [String: Any]? = nil
        if let wid = args.int("window"), wid > 0,
           let lx = args.dbl("localX"), let ly = args.dbl("localY") {
            let p = pidForWindow(CGWindowID(wid)) ?? 0
            r = ghostGoto(window: CGWindowID(wid), local: CGPoint(x: lx, y: ly),
                          animated: args.flag("animate"), label: args.str("label") ?? "",
                          pid: p)
        } else {
            r = ghostGoto(global: CGPoint(x: args.dbl("x") ?? 0, y: args.dbl("y") ?? 0),
                          animated: args.flag("animate"), label: args.str("label") ?? "")
        }
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
    opts.appBundle = NSRunningApplication(processIdentifier: pd)?.bundleIdentifier ?? ""
    opts.trackFocus = args.flag("focus-check")
    // 显式期望：`--expect 7 --expect-el role:AXStaticText`
    // 给了它，「成功」就是「真的变成 7」，而不是「有东西变了」
    if let ev = args.str("expect") {
        var e = StateExpectation.parse(match: args.str("match"), value: ev,
                                       hint: args.str("expect-el"))
        e.idempotent = args.flag("idempotent") ? true : nil
        e.maxWaitMs = args.int("expect-timeout") ?? 600
        opts.expectation = e
    }
    let outcome = performAgentAction(global: p, pid: pd, windowId: w, windowFrame: f,
                                     label: label, options: opts)
    let res = actionReport(outcome, windowId: w, pid: pd, point: p, frame: f)
    if gJSONMode { emit(res) }
    else {
        let cur = (outcome.cursorInfo["used"] as? Bool) ?? false
        let mark = outcome.ok ? "✅" : "❌"
        emitText("\(mark) \(outcome.mode) @(\(Int(p.x)),\(Int(p.y)))  cursor=\(cur ? "shown" : "off")  "
                 + "result=\(outcome.result)  verify=\(outcome.verification)  \(Int(outcome.timing.total))ms"
                 + (outcome.failureReason.isEmpty ? "" : "  原因=\(outcome.failureReason)"))
        if let rep = outcome.verifyReport, !rep.notes.isEmpty {
            emitText("   期望=\(rep.expectedDesc)  \(rep.notes.joined(separator: "；"))")
        }
        if !outcome.visibility.note.isEmpty {
            emitText("   窗口状态：\(TargetWindowVisibilityManager.humanNote(outcome.visibility))")
        }
    }
    // 没做成就不返回 0：让调用方（脚本 / Skill / 上层 Agent）无法把失败当成功
    exit(outcome.ok ? 0 : 3)
}
