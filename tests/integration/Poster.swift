import Cocoa
import CoreGraphics
import Darwin

// ============================================================
// 后台事件投递实验器
// 对比：AX 语义操作 / 裸 postToPid / +字段51 / +51+58 /
//      +51+窗口局部坐标 / 混合 / 全局 HID（对照组）
// 判定标准：目标 UI 状态真的变了（读 state.json 计数），而不是「投递没报错」
// ============================================================

let LAB = "/tmp/wbcu-lab"

// 未文档化的 CoreGraphics 导出符号（不在公开头文件，但符号存在）
typealias SetWindowLocFn = @convention(c) (CGEvent, CGPoint) -> Void
let setWindowLocation: SetWindowLocFn? = {
    guard let p = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGEventSetWindowLocation") else { return nil }
    return unsafeBitCast(p, to: SetWindowLocFn.self)
}()

let F51 = CGEventField(rawValue: 51)!
let F58 = CGEventField(rawValue: 58)!
let F91 = CGEventField(rawValue: 91)!
let F92 = CGEventField(rawValue: 92)!

// ---------- 参数 ----------
var mode = "ax"
var target = "btnPlain"
var action = "click"
var cover: String? = nil
var primer = false
var jsonOut = false
var repeatCount = 1

var it = CommandLine.arguments.dropFirst().makeIterator()
while let a = it.next() {
    switch a {
    case "--mode": mode = it.next() ?? mode
    case "--target": target = it.next() ?? target
    case "--action": action = it.next() ?? action
    case "--cover": cover = it.next()
    case "--primer": primer = true
    case "--json": jsonOut = true
    case "--repeat": repeatCount = Int(it.next() ?? "1") ?? 1
    default: break
    }
}

func out(_ o: [String: Any]) {
    if jsonOut {
        if let d = try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]),
           let s = String(data: d, encoding: .utf8) { print(s) }
    }
}

// ---------- 读目标坐标 ----------
func loadJSON(_ path: String) -> [String: Any]? {
    guard let d = try? Data(contentsOf: URL(fileURLWithPath: path)),
          let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
    return o
}

guard let tinfo = loadJSON("\(LAB)/targets.json"),
      let targets = tinfo["targets"] as? [String: Any],
      let rect = targets[target] as? [String: Any],
      let cx = rect["cx"] as? Double, let cy = rect["cy"] as? Double,
      let rx = rect["x"] as? Double, let ry = rect["y"] as? Double,
      let winNum = tinfo["windowNumber"] as? Int,
      let winFrame = tinfo["windowCGFrame"] as? [String: Any],
      let wx = winFrame["X"] as? Double, let wy = winFrame["Y"] as? Double
else {
    FileHandle.standardError.write("读不到 \(LAB)/targets.json，Fixture 是否在运行？\n".data(using: .utf8)!)
    exit(2)
}

let point = CGPoint(x: cx, y: cy)
let localPoint = CGPoint(x: cx - wx, y: cy - wy)
let targetPid = (tinfo["pid"] as? Int) ?? 0

// ---------- 目标进程 pid ----------
func pidOfFixture() -> pid_t? {
    if targetPid > 0 { return pid_t(targetPid) }
    let apps = NSWorkspace.shared.runningApplications
    return apps.first(where: { $0.bundleIdentifier == "com.tencent.wbcu.lab" })?.processIdentifier
}
guard let pid = pidOfFixture() else {
    FileHandle.standardError.write("找不到 Fixture 进程\n".data(using: .utf8)!); exit(2)
}

// ---------- 状态快照 ----------
func stateSnap() -> [String: Any] { loadJSON("\(LAB)/state.json") ?? [:] }
func eventCount() -> Int {
    guard let s = try? String(contentsOfFile: "\(LAB)/events.jsonl", encoding: .utf8) else { return 0 }
    return s.split(separator: "\n").count
}
func newEvents(since n: Int) -> [[String: Any]] {
    guard let s = try? String(contentsOfFile: "\(LAB)/events.jsonl", encoding: .utf8) else { return [] }
    let lines = s.split(separator: "\n").dropFirst(n)
    return lines.compactMap { l in
        guard let d = l.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }
}
func mousePos() -> CGPoint {
    let p = NSEvent.mouseLocation
    let h = NSScreen.screens.first?.frame.height ?? 0
    return CGPoint(x: p.x, y: h - p.y)
}

let pointerDistBefore = hypot(mousePos().x - point.x, mousePos().y - point.y)
let before = stateSnap()
let evBefore = eventCount()
let mouseBefore = mousePos()
let frontBefore = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""

// ---------- 覆盖：把目标窗口压到别的窗口后面 ----------
if let c = cover {
    if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == c }) {
        app.activate(options: [.activateAllWindows])
        Thread.sleep(forTimeInterval: 0.7)
    }
}

// ---------- 投递 ----------
func postMouse(_ type: CGEventType, _ state: Int64 = 1) {
    guard let e = CGEvent(mouseEventSource: nil, mouseType: type,
                          mouseCursorPosition: point,
                          mouseButton: type == .rightMouseDown || type == .rightMouseUp ? .right : .left) else { return }
    e.setIntegerValueField(.mouseEventClickState, value: state)
    switch mode {
    case "bare":
        break
    case "w51":
        e.setIntegerValueField(F51, value: Int64(winNum))
    case "w51_91":
        e.setIntegerValueField(F51, value: Int64(winNum))
        e.setIntegerValueField(F91, value: Int64(winNum))
        e.setIntegerValueField(F92, value: Int64(winNum))
    case "w5158":
        e.setIntegerValueField(F51, value: Int64(winNum))
        e.setIntegerValueField(F58, value: 12345)
    case "w51local":
        e.setIntegerValueField(F51, value: Int64(winNum))
        setWindowLocation?(e, localPoint)
    case "w5158local":
        e.setIntegerValueField(F51, value: Int64(winNum))
        e.setIntegerValueField(F58, value: 12345)
        setWindowLocation?(e, localPoint)
    default:
        break
    }
    if mode == "hid" {
        e.post(tap: .cghidEventTap)
    } else {
        e.postToPid(pid)
    }
}

func postKey(_ code: CGKeyCode, flags: CGEventFlags = []) {
    guard let d = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true),
          let u = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false) else { return }
    d.flags = flags; u.flags = flags
    if mode == "hid" { d.post(tap: .cghidEventTap); u.post(tap: .cghidEventTap) }
    else { d.postToPid(pid); u.postToPid(pid) }
}

var axError = ""

if mode == "ax" {
    // 按 AX 标识找元素，直接语义操作（不受遮挡影响）
    let appEl = AXUIElementCreateApplication(pid)
    var found: AXUIElement?
    func attr(_ el: AXUIElement, _ k: String) -> AnyObject? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, k as CFString, &v) == .success ? v : nil
    }
    func walk(_ el: AXUIElement, _ depth: Int) {
        if found != nil || depth > 14 { return }
        if (attr(el, "AXIdentifier") as? String) == target { found = el; return }
        if let kids = attr(el, kAXChildrenAttribute) as? [AXUIElement] {
            for k in kids { walk(k, depth + 1) }
        }
    }
    walk(appEl, 0)
    if let el = found {
        let r = AXUIElementPerformAction(el, kAXPressAction as CFString)
        if r != .success { axError = "AXPress err \(r.rawValue)" }
    } else {
        axError = "element not found by identifier"
    }
} else if mode == "key" {
    // 由 --target 传 keycode 组合，这里只处理几个固定组合
    switch target {
    case "cmd+a": postKey(0, flags: .maskCommand)
    case "cmd+c": postKey(8, flags: .maskCommand)
    case "cmd+n": postKey(45, flags: .maskCommand)
    case "cmd+w": postKey(13, flags: .maskCommand)
    case "return": postKey(36)
    case "escape": postKey(53)
    case "tab": postKey(48)
    default: postKey(0)
    }
} else {
    if primer {
        if let m = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left) {
            m.postToPid(pid)
        }
        Thread.sleep(forTimeInterval: 0.05)
    }
    for _ in 0..<repeatCount {
        if action == "click" {
            postMouse(.leftMouseDown); usleep(28_000); postMouse(.leftMouseUp)
        } else if action == "double" {
            for s in [Int64(1), 2] {
                postMouse(.leftMouseDown, s); usleep(28_000); postMouse(.leftMouseUp, s); usleep(80_000)
            }
        } else if action == "right" {
            postMouse(.rightMouseDown); usleep(28_000); postMouse(.rightMouseUp)
        }
        usleep(120_000)
    }
}

Thread.sleep(forTimeInterval: 0.5)

// ---------- 判定 ----------
let after = stateSnap()
let newEv = newEvents(since: evBefore)
let mouseAfter = mousePos()
let frontAfter = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""

func delta(_ k: String) -> Int {
    (after[k] as? Int ?? 0) - (before[k] as? Int ?? 0)
}

var observed = false
switch target {
case "btnPlain", "btnCount": observed = delta("clicks") > 0
case "canvas": observed = delta("canvasClicks") > 0
case "web": observed = delta("webClicks") > 0
case "drop": observed = delta("drops") > 0
case "field": observed = (after["text"] as? String ?? "") != (before["text"] as? String ?? "")
default: observed = !newEv.isEmpty
}

let appActiveAtEvent = newEv.first?["appActive"] as? Bool
let kinds = newEv.map { ($0["kind"] as? String) ?? "?" }

let result: [String: Any] = [
    "mode": mode, "target": target, "action": action,
    "covered": cover != nil,
    "posted": true,
    "uiObserved": observed,
    "uiDelta": delta(target == "canvas" ? "canvasClicks" : (target == "web" ? "webClicks" : (target == "drop" ? "drops" : "clicks"))),
    "events": kinds,
    "appActiveAtEvent": appActiveAtEvent.map { $0 } ?? NSNull(),
    "mouseMoved": Int(hypot(mouseAfter.x - mouseBefore.x, mouseAfter.y - mouseBefore.y)),
    "pointerDistanceAtPost": Int(pointerDistBefore),
    "frontmostChanged": frontBefore != frontAfter,
    "frontBefore": frontBefore, "frontAfter": frontAfter,
    "axError": axError
]

if jsonOut {
    out(result)
} else {
    let mark = observed ? "OK  " : "FAIL"
    let evs = kinds.isEmpty ? "-" : kinds.prefix(3).joined(separator: ",")
    print(String(format: "%-5@ %-14@ %-13@ ui=%-3d ev=%-32@ active=%-5@ mouseΔ=%-3d front%@",
                 mark as NSString, mode as NSString, target as NSString,
                 delta(target == "canvas" ? "canvasClicks" : (target == "web" ? "webClicks" : (target == "drop" ? "drops" : "clicks"))),
                 evs as NSString,
                 (appActiveAtEvent == true ? "TRUE" : (appActiveAtEvent == false ? "false" : "?")) as NSString,
                 Int(hypot(mouseAfter.x - mouseBefore.x, mouseAfter.y - mouseBefore.y)),
                 (frontBefore == frontAfter ? " same" : " CHANGED") as NSString))
    print(String(format: "      指针距目标 %d px  前台 %@", Int(pointerDistBefore), frontBefore as NSString))
}
exit(observed ? 0 : 1)
