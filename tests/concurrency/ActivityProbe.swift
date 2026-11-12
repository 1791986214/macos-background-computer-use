import Cocoa
import CoreGraphics
import ApplicationServices
import Foundation

// ============================================================
// ActivityProbe —— 真实用户活动时间线记录器
//
// 用来回答一个「只看 frontmostApp 回答不了」的问题：
// **前台发生变化时，到底是用户自己切走的，还是 Third Hand 抢的？**
//
// 做法：
//   · 装一个 listen-only 的 CGEvent tap，记录用户真实的鼠标/键盘事件（含时间戳）
//   · 同时 100ms 采样一次前台应用与鼠标位置
//   · 全部写成 JSONL，交给分析器做归因：
//       前台变化前 400ms 内有用户输入 → 归因 user
//       没有任何用户输入却变了         → 归因 agent（这是要抓的）
//
// 只监听，不拦截、不修改、不注入任何事件。
// ============================================================

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/wbcu-activity.jsonl"
let seconds = CommandLine.arguments.count > 2 ? (Double(CommandLine.arguments[2]) ?? 20) : 20

var fh: FileHandle?
FileManager.default.createFile(atPath: outPath, contents: nil)
fh = FileHandle(forWritingAtPath: outPath)

let lock = NSLock()
var start = Date()

func write(_ d: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: d, options: [.sortedKeys]) else { return }
    lock.lock(); defer { lock.unlock() }
    fh?.seekToEndOfFile()
    fh?.write(data)
    fh?.write("\n".data(using: .utf8)!)
}

func frontInfo() -> (pid: Int, bundle: String, name: String) {
    let a = NSWorkspace.shared.frontmostApplication
    return (Int(a?.processIdentifier ?? -1), a?.bundleIdentifier ?? "", a?.localizedName ?? "")
}

func mouseCG() -> CGPoint {
    CGEvent(source: nil)?.location ?? .zero
}

// ---------- 事件 tap ----------
let mask: CGEventMask = (1 << CGEventType.mouseMoved.rawValue)
    | (1 << CGEventType.leftMouseDown.rawValue)
    | (1 << CGEventType.leftMouseUp.rawValue)
    | (1 << CGEventType.rightMouseDown.rawValue)
    | (1 << CGEventType.rightMouseUp.rawValue)
    | (1 << CGEventType.scrollWheel.rawValue)
    | (1 << CGEventType.keyDown.rawValue)
    | (1 << CGEventType.flagsChanged.rawValue)

let kinds: [CGEventType: String] = [
    .mouseMoved: "mouseMoved", .leftMouseDown: "leftMouseDown", .leftMouseUp: "leftMouseUp",
    .rightMouseDown: "rightMouseDown", .rightMouseUp: "rightMouseUp",
    .scrollWheel: "scroll", .keyDown: "keyDown", .flagsChanged: "flagsChanged"
]

let callback: CGEventTapCallBack = { _, type, event, _ in
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput { return nil }
    let ts = Date().timeIntervalSince1970
    let loc = event.location
    let f = frontInfo()
    var d: [String: Any] = [
        "ts": ts,
        "kind": "input",
        "type": kinds[type] ?? "other_\(type.rawValue)",
        "x": loc.x, "y": loc.y,
        "frontPid": f.pid, "frontBundle": f.bundle, "frontName": f.name,
        "eventNumber": event.getIntegerValueField(.mouseEventNumber),
        // 合成事件（注入）的来源 pid；真实用户事件为 0
        "sourcePid": event.getIntegerValueField(.eventSourceUnixProcessID)
    ]
    if type == .keyDown {
        d["keycode"] = event.getIntegerValueField(.keyboardEventKeycode)
    }
    write(d)
    return nil   // listen-only：不吞事件
}

let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                            options: .listenOnly, eventsOfInterest: mask,
                            callback: callback, userInfo: nil)

if let tap = tap {
    let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
    CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
} else {
    write(["ts": Date().timeIntervalSince1970, "kind": "error",
           "message": "无法创建事件 tap（缺辅助功能授权？）；只能记录前台采样"])
}

// ---------- 前台采样 ----------
let timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
    let f = frontInfo()
    let m = mouseCG()
    write(["ts": Date().timeIntervalSince1970, "kind": "sample",
           "frontPid": f.pid, "frontBundle": f.bundle, "frontName": f.name,
           "mx": m.x, "my": m.y, "elapsed": Date().timeIntervalSince(start)])
}

write(["ts": Date().timeIntervalSince1970, "kind": "begin",
       "seconds": seconds, "tapOK": tap != nil, "pid": Int(getpid())])

let deadline = Date().addingTimeInterval(seconds)
while Date() < deadline {
    RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
}
timer.invalidate()
write(["ts": Date().timeIntervalSince1970, "kind": "end", "elapsed": Date().timeIntervalSince(start)])
fh?.closeFile()
exit(0)
