import Cocoa
import CoreGraphics

// ============================================================
// 遮挡/前台夹具（Cover）
//
// 它只做一件事：成为一个「别的 App」并把窗口摆在指定位置。
// 用它可以把被测目标的窗口状态切成三档，彼此不混淆：
//   ① 前台          —— 不启动 Cover
//   ② 后台但不遮挡  —— Cover 激活，窗口摆在远离目标的位置
//   ③ 后台且被遮挡  —— Cover 激活，窗口正好压在目标上
//
// 参数：--rect x,y,w,h   （CG 全局坐标，左上原点，与 CGEvent 一致）
//      --label 文本
// ============================================================

var cgRect = CGRect(x: 40, y: 40, width: 320, height: 220)
var label = "Cover"

var args = Array(CommandLine.arguments.dropFirst())
var i = 0
while i < args.count {
    switch args[i] {
    case "--rect":
        i += 1
        if i < args.count {
            let p = args[i].split(separator: ",").compactMap { Double($0) }
            if p.count == 4 { cgRect = CGRect(x: p[0], y: p[1], width: p[2], height: p[3]) }
        }
    case "--label":
        i += 1
        if i < args.count { label = args[i] }
    default:
        break
    }
    i += 1
}

final class CoverDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!

    func applicationDidFinishLaunching(_ n: Notification) {
        let screenH = NSScreen.screens.first?.frame.height ?? 0
        // CG（左上原点）→ AppKit（左下原点）
        let frame = NSRect(x: cgRect.minX,
                           y: screenH - cgRect.maxY,
                           width: cgRect.width,
                           height: cgRect.height)
        window = NSWindow(contentRect: frame,
                          styleMask: [.titled, .closable],
                          backing: .buffered, defer: false)
        window.title = label
        window.level = .normal
        window.isReleasedWhenClosed = false
        let v = NSView(frame: NSRect(origin: .zero, size: frame.size))
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.systemGray.withAlphaComponent(0.98).cgColor
        let t = NSTextField(labelWithString: label)
        t.frame = NSRect(x: 16, y: frame.height - 40, width: frame.width - 32, height: 20)
        t.textColor = .white
        v.addSubview(t)
        window.contentView = v
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // 把实际摆位回报出来，避免测试只靠假设
        let report: [String: Any] = [
            "pid": Int(ProcessInfo.processInfo.processIdentifier),
            "windowNumber": window.windowNumber,
            "frame": ["x": frame.minX, "y": frame.minY, "w": frame.width, "h": frame.height],
            "cgRect": ["x": cgRect.minX, "y": cgRect.minY, "w": cgRect.width, "h": cgRect.height],
            "label": label
        ]
        if let d = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? d.write(to: URL(fileURLWithPath: "/tmp/wbcu-lab/cover.json"))
        }
    }
}

let app = NSApplication.shared
let delegate = CoverDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
