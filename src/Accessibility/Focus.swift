import Foundation
import AppKit
import ApplicationServices

// ============================================================
// FocusProbe —— 焦点状态取证
//
// 「不抢前台」只看 frontmostApplication 不够：
// 应用还是前台，但 key window / 第一响应者被换掉，用户会立刻感觉到
// （打字跑进别的窗口、快捷键失效）。这里把焦点相关的三个层级都读出来：
//   · App 级：是否 active
//   · Window 级：AXFocusedWindow / AXMainWindow
//   · 元素级：AXFocusedUIElement（真正的第一响应者）
// ============================================================

struct FocusState {
    var appActive = false
    var keyWindowId: CGWindowID? = nil
    var keyWindowTitle = ""
    var mainWindowId: CGWindowID? = nil
    var focusedRole = ""
    var focusedIdentifier = ""
    var focusedTitle = ""
    var focusedValue = ""
    var readable = false

    var dict: [String: Any] {
        ["appActive": appActive,
         "keyWindowId": keyWindowId.map { Int($0) } ?? 0,
         "keyWindowTitle": keyWindowTitle,
         "mainWindowId": mainWindowId.map { Int($0) } ?? 0,
         "focusedRole": focusedRole,
         "focusedIdentifier": focusedIdentifier,
         "focusedTitle": focusedTitle,
         "focusedValue": focusedValue,
         "readable": readable]
    }

    /// 两份焦点状态是否「同一处」——只看身份，不看具体值变化（值变了不算焦点迁移）
    func sameFocus(as other: FocusState) -> Bool {
        guard readable, other.readable else { return false }
        return appActive == other.appActive
            && keyWindowId == other.keyWindowId
            && focusedRole == other.focusedRole
            && focusedIdentifier == other.focusedIdentifier
    }
}

enum FocusProbe {
    static func read(pid: pid_t) -> FocusState {
        var s = FocusState()
        s.appActive = NSRunningApplication(processIdentifier: pid)?.isActive ?? false
        let app = appElement(pid)

        // 只发一次 IPC：拿 AXFocusedUIElement，再从它反推所属窗口。
        // 之前分别查 AXFocusedWindow / AXMainWindow / AXFocusedUIElement，
        // 每次点击多花 50ms（实测 P50 focus=53.8ms），却只多拿到一个 mainWindowId。
        if let f = axAttr(app, kAXFocusedUIElementAttribute) {
            let el = f as! AXUIElement
            s.focusedRole = axStr(el, kAXRoleAttribute) ?? ""
            s.focusedIdentifier = axStr(el, "AXIdentifier") ?? ""
            s.focusedTitle = axStr(el, kAXTitleAttribute) ?? ""
            s.keyWindowId = cgWindowId(of: el)      // 本地符号，无 IPC
            s.mainWindowId = s.keyWindowId
            s.readable = true
        }
        return s
    }

    /// 系统级：当前真正持有键盘焦点的应用与元素
    static func readFrontmost() -> (pid: pid_t, bundle: String, name: String) {
        let a = NSWorkspace.shared.frontmostApplication
        return (a?.processIdentifier ?? -1,
                a?.bundleIdentifier ?? "",
                a?.localizedName ?? "")
    }
}
