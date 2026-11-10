import Foundation
import AppKit
import CoreGraphics
import ScreenCaptureKit

// MARK: - 同步桥（把 async API 塞进 CLI 流程）
func awaitSync<T>(_ op: @escaping () async throws -> T) -> Result<T, Error> {
    let sem = DispatchSemaphore(value: 0)
    var result: Result<T, Error> = .failure(NSError(domain: "wbcu", code: -1))
    Task.detached {
        do { result = .success(try await op()) }
        catch { result = .failure(error) }
        sem.signal()
    }
    _ = sem.wait(timeout: .now() + 30)
    return result
}

func shareableContent(onScreenOnly: Bool) -> SCShareableContent? {
    switch awaitSync({ try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: onScreenOnly) }) {
    case .success(let c): return c
    case .failure(let e):
        FileHandle.standardError.write("SCShareableContent 失败: \(e)\n".data(using: .utf8)!)
        return nil
    }
}

// MARK: - 窗口（CGWindowList，含 layer/alpha，能看见系统合成窗口）
struct CGWin {
    var id: CGWindowID
    var pid: pid_t
    var owner: String
    var name: String
    var layer: Int
    var alpha: Double
    var bounds: CGRect
    var onScreen: Bool
}

func listCGWindows(onScreenOnly: Bool) -> [CGWin] {
    let opts: CGWindowListOption = onScreenOnly
        ? [.optionOnScreenOnly, .excludeDesktopElements]
        : [.optionAll, .excludeDesktopElements]
    guard let arr = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else { return [] }
    return arr.compactMap { d -> CGWin? in
        guard let id = d[kCGWindowNumber as String] as? Int,
              let pid = d[kCGWindowOwnerPID as String] as? Int else { return nil }
        let b = d[kCGWindowBounds as String] as? [String: Any] ?? [:]
        let rect = CGRect(x: (b["X"] as? Double) ?? 0, y: (b["Y"] as? Double) ?? 0,
                          width: (b["Width"] as? Double) ?? 0, height: (b["Height"] as? Double) ?? 0)
        return CGWin(
            id: CGWindowID(id),
            pid: pid_t(pid),
            owner: (d[kCGWindowOwnerName as String] as? String) ?? "",
            name: (d[kCGWindowName as String] as? String) ?? "",
            layer: (d[kCGWindowLayer as String] as? Int) ?? 0,
            alpha: (d[kCGWindowAlpha as String] as? Double) ?? 1,
            bounds: rect,
            onScreen: ((d[kCGWindowIsOnscreen as String] as? Bool) ?? false)
        )
    }
}

// MARK: - 应用发现
struct AppInfo {
    var pid: pid_t
    var bundleId: String
    var name: String
    var path: String
    var activationPolicy: String
    var isActive: Bool
    var isHidden: Bool
    var windowCount: Int
}

func runningApps(includeBackground: Bool) -> [AppInfo] {
    let cgWins = listCGWindows(onScreenOnly: true)
    return NSWorkspace.shared.runningApplications.compactMap { app -> AppInfo? in
        let policy: String
        switch app.activationPolicy {
        case .regular: policy = "regular"
        case .accessory: policy = "accessory"
        case .prohibited: policy = "prohibited"
        @unknown default: policy = "unknown"
        }
        if !includeBackground && policy == "prohibited" { return nil }
        if app.bundleIdentifier == nil && app.localizedName == nil { return nil }
        let wc = cgWins.filter { $0.pid == app.processIdentifier && $0.layer == 0 }.count
        return AppInfo(
            pid: app.processIdentifier,
            bundleId: app.bundleIdentifier ?? "",
            name: app.localizedName ?? "",
            path: app.bundleURL?.path ?? "",
            activationPolicy: policy,
            isActive: app.isActive,
            isHidden: app.isHidden,
            windowCount: wc
        )
    }.sorted { ($0.isActive ? 0 : 1, $0.name) < ($1.isActive ? 0 : 1, $1.name) }
}

func cmdApps(_ args: Args) {
    gJSONMode = args.flag("json")
    gPretty = args.flag("pretty")
    let apps = runningApps(includeBackground: args.flag("all"))
    if gJSONMode {
        emit(["ok": true, "count": apps.count, "apps": apps.map { a -> [String: Any] in
            ["pid": Int(a.pid), "bundleId": a.bundleId, "name": a.name, "path": a.path,
             "policy": a.activationPolicy, "active": a.isActive, "hidden": a.isHidden,
             "windows": a.windowCount]
        }])
    } else {
        var lines = ["PID    窗口  状态   应用"]
        for a in apps {
            let st = a.isActive ? "●前台" : (a.isHidden ? "隐藏 " : "后台 ")
            lines.append(String(format: "%-6d %-5d %@ %@  [%@]", a.pid, a.windowCount, st, a.name, a.bundleId))
        }
        emitText(lines.joined(separator: "\n"))
    }
    exit(0)
}

// MARK: - 窗口发现
struct WinInfo {
    var id: CGWindowID
    var pid: pid_t
    var app: String
    var title: String
    var bounds: CGRect
    var layer: Int
    var onScreen: Bool
}

func windowsFor(pid: pid_t?, onScreenOnly: Bool, includeSystemChrome: Bool) -> [WinInfo] {
    let cg = listCGWindows(onScreenOnly: onScreenOnly)
    var out: [WinInfo] = []
    // 以 ScreenCaptureKit 为主（capture 可用性以此为准）
    var sckMap: [CGWindowID: (String, String, CGRect)] = [:]
    if let content = shareableContent(onScreenOnly: onScreenOnly) {
        for w in content.windows {
            sckMap[w.windowID] = (w.owningApplication?.applicationName ?? "",
                                  w.title ?? "",
                                  w.frame)
        }
    }
    for w in cg {
        if let p = pid, w.pid != p { continue }
        if !includeSystemChrome && w.layer != 0 { continue }
        if w.bounds.width < 40 || w.bounds.height < 40 { continue }
        let sck = sckMap[w.id]
        out.append(WinInfo(
            id: w.id,
            pid: w.pid,
            app: sck?.0.isEmpty == false ? sck!.0 : w.owner,
            title: (sck?.1.isEmpty == false ? sck!.1 : w.name),
            bounds: sck?.2 ?? w.bounds,
            layer: w.layer,
            onScreen: w.onScreen
        ))
    }
    // SCK 有但 CGWindowList 因权限看不到标题的，补上
    for (id, v) in sckMap where !out.contains(where: { $0.id == id }) {
        let cgPid = cg.first(where: { $0.id == id })?.pid ?? 0
        if let p = pid, cgPid != p { continue }
        out.append(WinInfo(id: id, pid: cgPid, app: v.0, title: v.1, bounds: v.2, layer: 0, onScreen: true))
    }
    return out.sorted { $0.bounds.minY < $1.bounds.minY }
}

func cmdWindows(_ args: Args) {
    gJSONMode = args.flag("json")
    gPretty = args.flag("pretty")
    var target: pid_t? = nil
    if let t = args.str("app") {
        guard let app = findRunningApp(t) else { fail("找不到应用: \(t)") }
        target = app.processIdentifier
    }
    if let p = args.int("pid") { target = pid_t(p) }
    let wins = windowsFor(pid: target, onScreenOnly: !args.flag("all"), includeSystemChrome: args.flag("all"))
    if gJSONMode {
        emit(["ok": true, "count": wins.count, "windows": wins.map { w -> [String: Any] in
            ["windowId": Int(w.id), "pid": Int(w.pid), "app": w.app, "title": w.title,
             "x": w.bounds.minX, "y": w.bounds.minY, "w": w.bounds.width, "h": w.bounds.height,
             "layer": w.layer, "onScreen": w.onScreen]
        }])
    } else {
        var lines = ["WINDOWID  PID    层  应用 / 标题"]
        for w in wins {
            lines.append(String(format: "%-9d %-6d %-3d %@ — %@  (%.0f,%.0f %.0fx%.0f)",
                                Int(w.id), Int(w.pid), w.layer, w.app, w.title,
                                w.bounds.minX, w.bounds.minY, w.bounds.width, w.bounds.height))
        }
        emitText(lines.joined(separator: "\n"))
    }
    exit(0)
}

/// 窗口 → 进程
func pidForWindow(_ id: CGWindowID) -> pid_t? {
    listCGWindows(onScreenOnly: false).first(where: { $0.id == id })?.pid
}

/// 屏幕点 → 该点上的元素所属进程（用于坐标点击时判断目标应用）
func pidAtPoint(_ p: CGPoint) -> pid_t? {
    let sys = AXUIElementCreateSystemWide()
    var el: AXUIElement?
    guard AXUIElementCopyElementAtPosition(sys, Float(p.x), Float(p.y), &el) == .success,
          let e = el else { return nil }
    let pid = axPid(e)
    return pid > 0 ? pid : nil
}

/// 为目标应用选出「主窗口」。
/// 关键：窗口共享指示器在 macOS 26+ 会以独立 AXWindow(subrole=AXDialog, title="Window")
/// 出现在 kAXWindows 数组里，且可能排在真窗口之前 —— 必须显式排除，否则截到的会是一个 66x20 的胶囊。

/// 纯函数：从 CGWindowList 记录里选出「主窗口」。
///
/// 之所以单独抽出来，是因为它是**安全相关**的判据：
/// macOS 26 起，窗口级捕获会在目标 App 的 AX/CG 窗口列表里插入一个
/// ~66x20 的共享指示器（AXDialog + WindowSharingSessionButton）。
/// 若把它当成主窗口，点击/截图会全部落到那个胶囊上。
/// 抽成纯函数后可以脱离 GUI 做单元测试（见 tests/unit）。
func pickMainWindowRecord(_ cands: [CGWin], pid: pid_t,
                          minWidth: CGFloat = 120, minHeight: CGFloat = 60) -> CGWin? {
    let usable = cands.filter {
        $0.pid == pid && $0.layer == 0 &&
        $0.bounds.width >= minWidth && $0.bounds.height >= minHeight &&
        !$0.name.contains("WindowSharingSessionButton")
    }
    return usable.max { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }
}

func mainWindowId(for pid: pid_t) -> CGWindowID? {
    func area(_ el: AXUIElement) -> CGFloat {
        guard let s = axSize(el, kAXSizeAttribute) else { return 0 }
        return s.width * s.height
    }
    func isIndicatorish(_ el: AXUIElement) -> Bool {
        let subrole = axStr(el, kAXSubroleAttribute) ?? ""
        let title = axStr(el, kAXTitleAttribute) ?? ""
        if subrole.contains("Dialog") { return true }
        if title.contains("WindowSharingSessionButton") { return true }
        // 尺寸异常小（<120x60）的顶层窗口基本是系统附属控件
        if let s = axSize(el, kAXSizeAttribute), s.width < 120 || s.height < 60 { return true }
        // 名字是 "Window" 且不含内容
        if title == "Window" && axChildren(el).count <= 1 { return true }
        return false
    }

    // 1) 优先：AXStandardWindow 里面积最大的那个
    let candidates = windowsOf(pid).filter { !isIndicatorish($0) }
    let sorted = candidates.sorted { area($0) > area($1) }
    for w in sorted {
        let subrole = axStr(w, kAXSubroleAttribute) ?? ""
        if subrole.contains("Standard") || subrole.isEmpty {
            if let wid = cgWindowId(of: w) { return wid }
        }
    }
    if let w = sorted.first, let wid = cgWindowId(of: w) { return wid }

    // 2) 回退：CGWindowList 里该 pid 最大的 layer==0 窗口（同一套判据，可单测）
    return pickMainWindowRecord(listCGWindows(onScreenOnly: true), pid: pid)?.id
}
