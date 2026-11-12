import Foundation
import AppKit
import CoreGraphics
import ApplicationServices

// MARK: - 键码表（US 布局物理键位）
let keyCodes: [String: CGKeyCode] = [
    "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
    "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
    "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "equal": 24, "=": 24,
    "9": 25, "7": 26, "minus": 27, "-": 27, "8": 28, "0": 29, "rightbracket": 30, "]": 30,
    "o": 31, "u": 32, "leftbracket": 33, "[": 33, "i": 34, "p": 35,
    "Return": 36, "return": 36, "Enter": 36, "enter": 36,
    "l": 37, "j": 38, "quote": 39, "'": 39, "k": 40, "semicolon": 41, ";": 41,
    "backslash": 42, "\\": 42, "comma": 43, ",": 43, "slash": 44, "/": 44,
    "n": 45, "m": 46, "period": 47, ".": 47,
    "Tab": 48, "tab": 48, "Space": 49, "space": 49, "grave": 50, "`": 50,
    "BackSpace": 51, "backspace": 51, "Escape": 53, "esc": 53,
    "Right": 124, "Left": 123, "Down": 125, "Up": 126,
    "Home": 115, "End": 119, "Page_Up": 116, "PageUp": 116, "Page_Down": 121, "PageDown": 121,
    "Delete": 117, "ForwardDelete": 117,
    "F1": 122, "F2": 120, "F3": 99, "F4": 118, "F5": 96, "F6": 97,
    "F7": 98, "F8": 100, "F9": 101, "F10": 109, "F11": 103, "F12": 111,
    "KP_0": 82, "KP_1": 83, "KP_2": 84, "KP_3": 85, "KP_4": 86,
    "KP_5": 87, "KP_6": 88, "KP_7": 89, "KP_8": 91, "KP_9": 92,
    "KP_Enter": 76, "KP_Decimal": 65, "KP_Add": 69, "KP_Subtract": 78,
    "KP_Multiply": 67, "KP_Divide": 75
]

struct KeyCombo {
    var flags: CGEventFlags
    var keyCode: CGKeyCode
}

func parseKeyCombo(_ spec: String) -> KeyCombo? {
    let parts = spec.split(separator: "+").map { String($0).trimmingCharacters(in: .whitespaces) }
    guard !parts.isEmpty else { return nil }
    var flags: CGEventFlags = []
    for p in parts.dropLast() {
        switch p.lowercased() {
        case "cmd", "command", "super", "meta", "⌘": flags.insert(.maskCommand)
        case "shift", "⇧": flags.insert(.maskShift)
        case "alt", "opt", "option", "⌥": flags.insert(.maskAlternate)
        case "ctrl", "control", "⌃": flags.insert(.maskControl)
        case "fn": flags.insert(.maskSecondaryFn)
        default: return nil
        }
    }
    var last = parts.last!
    // 支持 "super+shift+A" 这种大写字母
    if last.count == 1 { last = last.lowercased() }
    guard let code = keyCodes[last] else { return nil }
    return KeyCombo(flags: flags, keyCode: code)
}

// MARK: - 事件源
let hidSource = CGEventSource(stateID: .hidSystemState)
let combinedSource = CGEventSource(stateID: .combinedSessionState)

/// 零干扰护栏：设置 WBCU_NO_HID_MOUSE=1 后，任何真实鼠标注入都会直接失败。
/// 用来在「不许碰用户鼠标」的任务里做结构性保证 —— 不是靠自觉，是代码路径被切断。
let hidMouseForbidden = ProcessInfo.processInfo.environment["WBCU_NO_HID_MOUSE"] == "1"

func assertHIDMouseAllowed(_ what: String) {
    if hidMouseForbidden {
        fail("本会话已禁用 HID 鼠标事件（WBCU_NO_HID_MOUSE=1），拒绝执行：\(what)。请改用 ax-act / ax-set / key / type 等后台通道。", code: 4)
    }
}

func postEvent(_ e: CGEvent, pid: pid_t?) {
    if let p = pid {
        e.postToPid(p)
    } else {
        e.post(tap: .cghidEventTap)
    }
}

// MARK: - 鼠标
func mousePointFromArgs(_ args: Args) -> CGPoint {
    guard let x = args.dbl("x"), let y = args.dbl("y") else {
        // 支持 --at "12,34"
        if let at = args.str("at") {
            let p = at.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            if p.count == 2 { return CGPoint(x: p[0], y: p[1]) }
        }
        fail("需要 --x --y（屏幕坐标，左上原点，单位 point）")
    }
    return CGPoint(x: x, y: y)
}

func mouseEvent(_ type: CGEventType, _ p: CGPoint, button: CGMouseButton, clickState: Int64 = 1, windowId: CGWindowID? = nil) -> CGEvent? {
    guard let e = CGEvent(mouseEventSource: hidSource, mouseType: type, mouseCursorPosition: p, mouseButton: button) else { return nil }
    e.setIntegerValueField(.mouseEventClickState, value: clickState)
    if let w = windowId {
        e.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(w))
        e.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(w))
    }
    return e
}

func moveMouse(_ p: CGPoint, pid: pid_t?) {
    assertHIDMouseAllowed("moveMouse")
    if let e = mouseEvent(.mouseMoved, p, button: .left) { postEvent(e, pid: pid) }
}

func clickMouse(at p: CGPoint, button: String, count: Int, pid: pid_t?, windowId: CGWindowID?) {
    assertHIDMouseAllowed("clickMouse")
    let (down, up, btn): (CGEventType, CGEventType, CGMouseButton) = {
        switch button.lowercased() {
        case "right", "r": return (.rightMouseDown, .rightMouseUp, .right)
        case "middle", "m": return (.otherMouseDown, .otherMouseUp, .center)
        default: return (.leftMouseDown, .leftMouseUp, .left)
        }
    }()
    // 先把指针移过去（真实 HID 移动，便于视觉/悬停效果）
    if pid == nil { moveMouse(p, pid: nil) }
    for i in 1...max(1, count) {
        if let d = mouseEvent(down, p, button: btn, clickState: Int64(i), windowId: windowId) { postEvent(d, pid: pid) }
        usleep(12_000)
        if let u = mouseEvent(up, p, button: btn, clickState: Int64(i), windowId: windowId) { postEvent(u, pid: pid) }
        if i < count { usleep(45_000) }
    }
}

func dragMouse(from a: CGPoint, to b: CGPoint, pid: pid_t?, windowId: CGWindowID?) {
    assertHIDMouseAllowed("dragMouse")
    moveMouse(a, pid: pid)
    usleep(60_000)
    if let d = mouseEvent(.leftMouseDown, a, button: .left, windowId: windowId) { postEvent(d, pid: pid) }
    let steps = 18
    for i in 1...steps {
        let t = Double(i) / Double(steps)
        let p = CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
        if let m = mouseEvent(.leftMouseDragged, p, button: .left, windowId: windowId) { postEvent(m, pid: pid) }
        usleep(9_000)
    }
    if let u = mouseEvent(.leftMouseUp, b, button: .left, windowId: windowId) { postEvent(u, pid: pid) }
}

func scrollMouse(dx: Int32, dy: Int32, at p: CGPoint?, pid: pid_t?) {
    assertHIDMouseAllowed("scrollMouse")
    if let p = p { moveMouse(p, pid: pid); usleep(20_000) }
    guard let e = CGEvent(scrollWheelEvent2Source: hidSource, units: .line, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0) else { return }
    postEvent(e, pid: pid)
}

// MARK: - 键盘
func pressKeyCombo(_ combo: KeyCombo, pid: pid_t?) {
    guard let down = CGEvent(keyboardEventSource: hidSource, virtualKey: combo.keyCode, keyDown: true),
          let up = CGEvent(keyboardEventSource: hidSource, virtualKey: combo.keyCode, keyDown: false) else { return }
    down.flags = combo.flags
    up.flags = combo.flags
    postEvent(down, pid: pid)
    usleep(8_000)
    postEvent(up, pid: pid)
}

func typeText(_ text: String, pid: pid_t?, perCharDelayUs: UInt32 = 3_000) {
    // 用 unicode 事件，支持中文/emoji
    let chars = Array(text.utf16)
    var i = 0
    while i < chars.count {
        let chunk = Array(chars[i..<min(i + 16, chars.count)])
        guard let down = CGEvent(keyboardEventSource: hidSource, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: hidSource, virtualKey: 0, keyDown: false) else { return }
        var c = chunk
        down.keyboardSetUnicodeString(stringLength: c.count, unicodeString: &c)
        up.keyboardSetUnicodeString(stringLength: c.count, unicodeString: &c)
        postEvent(down, pid: pid)
        postEvent(up, pid: pid)
        i += chunk.count
        usleep(perCharDelayUs)
    }
}

// MARK: - 命令
func inputTarget(_ args: Args) -> (pid: pid_t?, windowId: CGWindowID?) {
    var pid: pid_t? = nil
    var wid: CGWindowID? = nil
    if let p = args.int("pid") { pid = pid_t(p) }
    else if let a = args.str("app") {
        guard let app = findRunningApp(a) else { fail("找不到应用: \(a)") }
        pid = app.processIdentifier
    }
    if let w = args.int("window") { wid = CGWindowID(w) }
    return (pid, wid)
}

func cmdClick(_ args: Args) {
    gJSONMode = args.flag("json")
    gPretty = args.flag("pretty")
    let p = mousePointFromArgs(args)
    var (pid, wid) = inputTarget(args)
    let button = args.str("button") ?? "left"
    let count = args.int("count") ?? 1
    let mode = (args.str("mode") ?? "auto").lowercased()
    let verify = args.flag("verify")
    let wantGhost = args.flag("ghost") || ProcessInfo.processInfo.environment["WBCU_GHOST"] == "1"

    // ---- 解析目标窗口（坐标落在哪个窗口）----
    var winFrame: CGRect? = nil
    let allWins = listCGWindows(onScreenOnly: false)
    if let w = wid, let rec = allWins.first(where: { $0.id == w }) {
        winFrame = rec.bounds
        if pid == nil { pid = rec.pid }
    } else if let pd = pid {
        // 该 pid 名下包含此点的最小窗口
        let cands = allWins.filter { $0.pid == pd && $0.bounds.contains(p) }
        if let best = cands.min(by: { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }) {
            wid = best.id; winFrame = best.bounds
        }
    }

    enforceGuard(pid: pid ?? 0, action: "click")
    if wantGhost { ghostMove(p); usleep(120_000) }

    var usedMode = "targeted"
    var axAction = ""
    let fpBefore = verify ? axFingerprint(pid: pid ?? 0) : ("", 0)

    // ---- 策略 1：AX 语义（可用则优先，天然支持后台与遮挡）----
    if mode == "ax" || mode == "auto", let pd = pid,
       let el = findPressableElement(pid: pd, at: p) {
        let r = AXUIElementPerformAction(el, kAXPressAction as CFString)
        if r == .success { usedMode = "ax"; axAction = kAXPressAction as String }
    }

    // ---- 策略 2：进程级定向投递 ----
    var escalated = false
    func doTargeted() {
        guard let pd = pid, let w = wid, let f = winFrame else { return }
        targetedClick(at: p, pid: pd, windowId: w, windowFrame: f, button: button, clickCount: count)
    }
    if usedMode == "ax" {
        if verify {
            usleep(220_000)
            let fpAfter = axFingerprint(pid: pid ?? 0)
            if fpAfter.hash == fpBefore.0 && mode == "auto" {
                // AX 没产生可见变化 → 自动升级到定向事件
                doTargeted(); usedMode = "targeted"; escalated = true
            }
        }
    } else if mode != "global" {
        guard wid != nil, winFrame != nil else {
            fail("找不到包含该点的目标窗口；坐标点击请用 --window <id> 指定，或加 --allow-global 走全局注入", code: 5)
        }
        doTargeted(); usedMode = "targeted"
    }

    // ---- 策略 3：全局 HID（必须显式批准，绝不静默兜底）----
    if mode == "global" {
        guard args.flag("allow-global") else {
            fail("全局鼠标注入会移动用户真实指针，必须显式加 --allow-global 才会执行", code: 6)
        }
        clickMouse(at: p, button: button, count: count, pid: nil, windowId: wid)
        usedMode = "global"
    }

    if wantGhost { ghostClick(p, usedMode) }

    var changed: Bool? = nil
    if verify {
        usleep(260_000)
        let fpAfter = axFingerprint(pid: pid ?? 0)
        changed = fpAfter.hash != fpBefore.0
    }

    let res: [String: Any] = [
        "ok": true, "action": "click", "mode": usedMode, "escalatedFromAX": escalated,
        "x": p.x, "y": p.y, "button": button, "count": count,
        "pid": pid.map { Int($0) } ?? 0,
        "windowId": wid.map { Int($0) } ?? 0,
        "axAction": axAction,
        "uiChanged": changed.map { $0 } ?? NSNull(),
        "verification": changed == nil ? "not_requested"
            : (changed! ? "changed" : "no_observable_change"),
        "pointerMoved": false
    ]
    if gJSONMode { emit(res) }
    else {
        var line = "✅ \(usedMode) click \(button)x\(count) @(\(Int(p.x)),\(Int(p.y)))"
        if let pd = pid { line += " → pid \(pd)" }
        if escalated { line += "  (AX 无变化已自动升级)" }
        if let c = changed { line += c ? "  UI 已变化" : "  ⚠️ UI 未见变化" }
        emitText(line)
    }
    exit(0)
}

func cmdMove(_ args: Args) {
    gJSONMode = args.flag("json")
    let p = mousePointFromArgs(args)
    moveMouse(p, pid: nil)
    if gJSONMode { emit(["ok": true, "x": p.x, "y": p.y]) } else { emitText("✅ move @(\(Int(p.x)),\(Int(p.y)))") }
    exit(0)
}

func cmdDrag(_ args: Args) {
    gJSONMode = args.flag("json")
    guard let x1 = args.dbl("x1"), let y1 = args.dbl("y1"),
          let x2 = args.dbl("x2"), let y2 = args.dbl("y2") else { fail("需要 --x1 --y1 --x2 --y2") }
    var (pid, wid) = inputTarget(args)
    let mode = (args.str("mode") ?? "targeted").lowercased()
    let a = CGPoint(x: x1, y: y1), b = CGPoint(x: x2, y: y2)

    // 先解析窗口与真实 pid（--window 时 pid 来自窗口归属），再做授权检查
    var winFrame: CGRect? = nil
    let allWins = listCGWindows(onScreenOnly: false)
    if let w = wid, let rec = allWins.first(where: { $0.id == w }) {
        winFrame = rec.bounds; pid = rec.pid
    } else if let pd = pid, let best = allWins.filter({ $0.pid == pd && $0.bounds.contains(a) })
        .min(by: { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }) {
        wid = best.id; winFrame = best.bounds
    }
    enforceGuard(pid: pid ?? 0, action: "drag")
    let wantGhost = args.flag("ghost") || ProcessInfo.processInfo.environment["WBCU_GHOST"] == "1"
    if wantGhost { ghostMove(a); usleep(100_000) }

    var used = "targeted"
    if mode == "global" {
        guard args.flag("allow-global") else { fail("全局拖拽会移动真实指针，需 --allow-global", code: 6) }
        dragMouse(from: a, to: b, pid: nil, windowId: wid); used = "global"
    } else if let pd = pid, let w = wid, let f = winFrame {
        targetedDrag(from: a, to: b, pid: pd, windowId: w, windowFrame: f)
    } else {
        fail("找不到目标窗口；用 --window <id> 指定，或加 --allow-global", code: 5)
    }
    if wantGhost { ghostClick(b, "drag") }
    if gJSONMode { emit(["ok": true, "mode": used, "from": [x1, y1], "to": [x2, y2]]) }
    else { emitText("✅ \(used) drag (\(Int(x1)),\(Int(y1))) → (\(Int(x2)),\(Int(y2)))") }
    exit(0)
}

func cmdScroll(_ args: Args) {
    gJSONMode = args.flag("json")
    let dx = Int32(args.int("dx") ?? 0)
    let dy = Int32(args.int("dy") ?? args.int("pages").map { $0 * 5 } ?? -3)
    let (pid, _) = inputTarget(args)
    if let p = pid { enforceGuard(pid: p, action: "scroll") }
    var p: CGPoint? = nil
    if let x = args.dbl("x"), let y = args.dbl("y") { p = CGPoint(x: x, y: y) }
    scrollMouse(dx: dx, dy: dy, at: p, pid: pid)
    if gJSONMode { emit(["ok": true, "dx": dx, "dy": dy]) } else { emitText("✅ scroll dx=\(dx) dy=\(dy)") }
    exit(0)
}

func cmdKey(_ args: Args) {
    gJSONMode = args.flag("json")
    let spec = args.str("combo") ?? args.str("key") ?? args.positional.first ?? ""
    guard let combo = parseKeyCombo(spec) else { fail("无法解析按键: \(spec)（示例: cmd+shift+g / Return / super+c）") }
    let (pid, _) = inputTarget(args)
    enforceGuard(pid: pid ?? 0, action: "key \(spec)")
    let repeatCount = args.int("repeat") ?? 1
    for _ in 0..<max(1, repeatCount) {
        pressKeyCombo(combo, pid: pid)
        usleep(30_000)
    }
    if gJSONMode { emit(["ok": true, "combo": spec, "target": pid.map { Int($0) } ?? 0, "repeat": repeatCount]) }
    else { emitText("✅ key \(spec)\(pid != nil ? " → pid \(pid!)" : " (前台)")") }
    exit(0)
}

func cmdType(_ args: Args) {
    gJSONMode = args.flag("json")
    let text = args.str("text") ?? args.positional.joined(separator: " ")
    guard !text.isEmpty else { fail("需要 --text") }
    let (pid, _) = inputTarget(args)
    enforceGuard(pid: pid ?? 0, action: "type")
    typeText(text, pid: pid)
    if gJSONMode { emit(["ok": true, "chars": text.count, "target": pid.map { Int($0) } ?? 0]) }
    else { emitText("✅ typed \(text.count) chars\(pid != nil ? " → pid \(pid!)" : "")") }
    exit(0)
}

// MARK: - 启动应用（不抢前台）

/// `wbcu launch --app <bundleId|名称>`
///
/// 存在的理由只有一个：**首次打开目标应用时不要抢用户的前台**。
/// Agent 最自然的行为是 `open -a Calculator` —— 那条命令必然把 Calculator 顶到最前。
/// 这里用 NSWorkspace.OpenConfiguration.activates = false，从 API 层面就说清楚
/// 「我要它启动，但不要它上前台」，不是启动完再偷偷切回去。
///
/// 已经在运行 → 直接返回，不做任何激活。
func cmdLaunch(_ args: Args) {
    gJSONMode = args.flag("json")
    guard let token = args.str("app") else { fail("需要 --app <bundleId|名称>") }

    // 已在运行：什么都不做。这一步是「避免重复启动」的关键，
    // 因为重复 `open -a` 会把窗口重新带到前台。
    if let running = findRunningApp(token) {
        let out: [String: Any] = ["ok": true, "launched": false, "alreadyRunning": true,
                                  "pid": Int(running.processIdentifier),
                                  "name": running.localizedName ?? "",
                                  "bundleId": running.bundleIdentifier ?? "",
                                  "activated": false]
        if gJSONMode { emit(out) }
        else { emitText("· \(running.localizedName ?? token) 已在运行（pid \(running.processIdentifier)），未激活") }
        exit(0)
    }

    var url: URL? = NSWorkspace.shared.urlForApplication(withBundleIdentifier: token)
    if url == nil {
        // 允许传应用名
        let candidates = ["/System/Applications/\(token).app",
                          "/Applications/\(token).app",
                          NSHomeDirectory() + "/Applications/\(token).app"]
        url = candidates.map { URL(fileURLWithPath: $0) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }
    if url == nil { url = NSWorkspace.shared.urlForApplication(toOpen: URL(fileURLWithPath: token)) }
    guard let appURL = url else { fail("找不到应用: \(token)") }

    let cfg = NSWorkspace.OpenConfiguration()
    // 核心：不激活。用户说的「首次可以显示，但别抢前台」就落在这个开关上。
    cfg.activates = args.flag("foreground")
    cfg.addsToRecentItems = false
    cfg.createsNewApplicationInstance = false

    var resultPid: pid_t = 0
    var errMsg = ""
    let sem = DispatchSemaphore(value: 0)
    NSWorkspace.shared.openApplication(at: appURL, configuration: cfg) { app, err in
        if let app { resultPid = app.processIdentifier }
        if let err { errMsg = err.localizedDescription }
        sem.signal()
    }
    _ = sem.wait(timeout: .now() + 8)

    let out: [String: Any] = ["ok": resultPid > 0, "launched": resultPid > 0,
                              "alreadyRunning": false, "pid": Int(resultPid),
                              "name": appURL.deletingPathExtension().lastPathComponent,
                              "activated": args.flag("foreground"),
                              "error": errMsg]
    if gJSONMode { emit(out) }
    else if resultPid > 0 {
        emitText(args.flag("foreground")
                 ? "✅ 已启动并激活 \(out["name"] ?? "")（pid \(resultPid)）"
                 : "✅ 已后台启动 \(out["name"] ?? "")（pid \(resultPid)），未抢前台")
    } else {
        emitText("❌ 启动失败: \(errMsg)")
    }
    exit(resultPid > 0 ? 0 : 1)
}

// MARK: - 应用激活 / 窗口移动
func cmdActivate(_ args: Args) {
    gJSONMode = args.flag("json")
    guard let t = args.str("app") ?? args.str("pid") else { fail("需要 --app 或 --pid") }
    guard let app = findRunningApp(t) else { fail("找不到应用: \(t)") }
    let ok = app.activate(options: [.activateAllWindows])
    if gJSONMode { emit(["ok": ok, "pid": Int(app.processIdentifier), "name": app.localizedName ?? ""]) }
    else { emitText(ok ? "✅ 已激活 \(app.localizedName ?? "")" : "❌ 激活失败") }
    exit(ok ? 0 : 1)
}

func cmdWindowMove(_ args: Args) {
    gJSONMode = args.flag("json")
    let pid = resolvePid(args)
    guard let win = windowsOf(pid).first else { fail("应用没有窗口") }
    if let x = args.dbl("x"), let y = args.dbl("y") {
        var p = CGPoint(x: x, y: y)
        if let v = AXValueCreate(.cgPoint, &p) {
            let e = AXUIElementSetAttributeValue(win, kAXPositionAttribute as CFString, v)
            if e != .success { fail("设置位置失败: \(axErrorName(e))") }
        }
    }
    if let w = args.dbl("w"), let h = args.dbl("h") {
        var s = CGSize(width: w, height: h)
        if let v = AXValueCreate(.cgSize, &s) {
            let e = AXUIElementSetAttributeValue(win, kAXSizeAttribute as CFString, v)
            if e != .success { fail("设置尺寸失败: \(axErrorName(e))") }
        }
    }
    let pos = axPoint(win, kAXPositionAttribute) ?? .zero
    let size = axSize(win, kAXSizeAttribute) ?? .zero
    if gJSONMode { emit(["ok": true, "x": pos.x, "y": pos.y, "w": size.width, "h": size.height]) }
    else { emitText("✅ 窗口 @(\(Int(pos.x)),\(Int(pos.y))) \(Int(size.width))x\(Int(size.height)))") }
    exit(0)
}
