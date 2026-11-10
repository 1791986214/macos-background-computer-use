import Foundation
import AppKit
import CoreGraphics

// MARK: - 环境探针（用于证明「没有打扰用户」）
//
// 零干扰判据有两条：
//   1) 鼠标指针没有移动过（HID 通道没被占用）
//   2) 前台应用没有切换（焦点没有被抢）

func currentMousePoint() -> CGPoint {
    let p = NSEvent.mouseLocation                    // 左下原点
    let screenH = NSScreen.screens.first?.frame.height ?? 0
    return CGPoint(x: p.x, y: screenH - p.y)         // 转左上原点，与 AX/CG 坐标一致
}

func frontmostAppInfo() -> [String: Any] {
    guard let app = NSWorkspace.shared.frontmostApplication else { return [:] }
    return [
        "pid": Int(app.processIdentifier),
        "name": app.localizedName ?? "",
        "bundleId": app.bundleIdentifier ?? ""
    ]
}

func cmdMousePos(_ args: Args) {
    gJSONMode = args.flag("json")
    let p = currentMousePoint()
    if gJSONMode {
        emit(["ok": true, "x": p.x, "y": p.y, "frontmost": frontmostAppInfo()])
    } else {
        emitText(String(format: "鼠标 (%.0f, %.0f)  前台: %@",
                        p.x, p.y, (frontmostAppInfo()["name"] as? String) ?? "?"))
    }
    exit(0)
}

// MARK: - 用户活跃度探针
//
// 用来区分「引擎抢了焦点」和「用户自己动了鼠标/键盘」。
// 判定依据：距上一次真实 HID 输入的时间。我们自己投递的事件走 postToPid，
// 不进全局事件流，所以不会污染这个读数。
func secondsSinceLastUserInput() -> Double {
    CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .init(rawValue: ~0)!)
}

func cmdIdle(_ args: Args) {
    gJSONMode = args.flag("json")
    let idle = secondsSinceLastUserInput()
    let p = currentMousePoint()
    let front = frontmostAppInfo()
    var out: [String: Any] = [
        "ok": true,
        "secondsSinceLastInput": idle,
        "userActiveWithinSecond": idle < 1.0,
        "mouse": ["x": p.x, "y": p.y],
        "frontmost": front
    ]
    if let pid = front["pid"] as? Int {
        out["frontmostIsSelf"] = (pid_t(pid) == getpid())
    }
    if gJSONMode { emit(out) }
    else {
        emitText(String(format: "距上次用户输入 %.2fs  鼠标 (%.0f,%.0f)  前台 %@%@",
                        idle, p.x, p.y, (front["name"] as? String) ?? "?",
                        idle < 1.0 ? "  ⚠️ 用户正在操作" : ""))
    }
    exit(0)
}
