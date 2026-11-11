import Foundation
import AppKit
import CoreGraphics
import ApplicationServices

// MARK: - 通用参数解析
struct Args {
    var positional: [String] = []
    var flags: Set<String> = []
    var opts: [String: String] = [:]

    static let boolFlags: Set<String> = [
        "json", "pretty", "recursive", "all", "prompt", "quiet", "verbose",
        "raw", "no-diff", "deep", "native", "exact", "allow-global", "ghost", "verify",
        "no-experience", "fast", "all", "observe-watch"
    ]

    init(_ argv: [String]) {
        var i = 0
        while i < argv.count {
            let t = argv[i]
            if t.hasPrefix("--") {
                var key = String(t.dropFirst(2))
                if key.isEmpty { i += 1; continue }
                if let eq = key.firstIndex(of: "=") {
                    opts[String(key[..<eq])] = String(key[key.index(after: eq)...])
                    i += 1
                    continue
                }
                if Args.boolFlags.contains(key) {
                    flags.insert(key)
                    i += 1
                    continue
                }
                // 有值则消费下一个 token
                if i + 1 < argv.count && !argv[i + 1].hasPrefix("--") {
                    opts[key] = argv[i + 1]
                    i += 2
                    continue
                }
                flags.insert(key)
                i += 1
            } else {
                positional.append(t)
                i += 1
            }
        }
    }

    func str(_ k: String) -> String? { opts[k] }
    func int(_ k: String) -> Int? { opts[k].flatMap { Int($0) } }
    func dbl(_ k: String) -> Double? { opts[k].flatMap { Double($0) } }
    func flag(_ k: String) -> Bool { flags.contains(k) }

    func requireInt(_ k: String) -> Int {
        guard let v = int(k) else { fail("缺少参数 --\(k)（整数）") }
        return v
    }
    func requireStr(_ k: String) -> String {
        guard let v = str(k) else { fail("缺少参数 --\(k)") }
        return v
    }
}

// MARK: - 输出
var gJSONMode = false
var gPretty = false

func emit(_ obj: Any) {
    var options: JSONSerialization.WritingOptions = [.sortedKeys, .withoutEscapingSlashes]
    if gPretty { options.insert(.prettyPrinted) }
    if let data = try? JSONSerialization.data(withJSONObject: obj, options: options),
       let s = String(data: data, encoding: .utf8) {
        print(s)
    } else {
        print("{\"ok\":false,\"error\":\"json_serialize_failed\"}")
    }
}

func emitText(_ s: String) { print(s) }

/// 建立与 WindowServer 的 CoreGraphics 会话连接。
/// 纯 CLI 进程若直接调用依赖 CGS 的 API（如 _AXUIElementGetWindow / SCScreenshotManager），
/// 会命中 CGS_REQUIRE_INIT 断言并 SIGABRT。触碰 NSApplication 与一次 CGWindowList 即可完成初始化。
func bootstrapWindowServer() {
    if NSApplication.shared.activationPolicy() != .prohibited {
        NSApplication.shared.setActivationPolicy(.prohibited)
    }
    _ = CGMainDisplayID()
    _ = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
}

func fail(_ msg: String, code: Int32 = 2) -> Never {
    if gJSONMode {
        emit(["ok": false, "error": msg])
    } else {
        FileHandle.standardError.write(("wbcu: " + msg + "\n").data(using: .utf8)!)
    }
    exit(code)
}

// MARK: - 工具目录
// MARK: - 坐标换算（窗口局部 ↔ 屏幕全局）
//
// 这个换算是后台点击的核心：投递给目标进程的必须是**窗口局部坐标**，
// 而 Ghost Cursor 定位、AX 元素定位用的都是**屏幕全局坐标**。
// 换算本身简单，但它同时出现在投递、光标、截图三处，必须只有一份实现。
// 注意：这里不做 Retina 缩放，因为 CGEvent/AX 都用 point（逻辑点），
// 只有像素级分析（截图）才涉及 scale，由 Capture 层自己处理。

func windowLocal(from global: CGPoint, in frame: CGRect) -> CGPoint {
    CGPoint(x: global.x - frame.minX, y: global.y - frame.minY)
}

func windowGlobal(from local: CGPoint, in frame: CGRect) -> CGPoint {
    CGPoint(x: frame.minX + local.x, y: frame.minY + local.y)
}

func stateDir() -> URL {
    let d = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".wbcu")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

func tmpDir() -> URL {
    let d = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("wbcu")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

// MARK: - AX 基础封装
func axAttr(_ el: AXUIElement, _ name: String) -> AnyObject? {
    var v: CFTypeRef?
    let err = AXUIElementCopyAttributeValue(el, name as CFString, &v)
    guard err == .success else { return nil }
    return v
}

func axStr(_ el: AXUIElement, _ name: String) -> String? {
    if let s = axAttr(el, name) as? String, !s.isEmpty { return s }
    return nil
}

func axChildren(_ el: AXUIElement) -> [AXUIElement] {
    var out: [AXUIElement] = []
    var values: CFArray?
    if AXUIElementCopyAttributeValues(el, kAXChildrenAttribute as CFString, 0, 512, &values) == .success,
       let arr = values as? [AXUIElement] {
        out = arr
        if arr.count >= 512 {
            var start = 512
            while true {
                var more: CFArray?
                if AXUIElementCopyAttributeValues(el, kAXChildrenAttribute as CFString, start, 512, &more) == .success,
                   let m = more as? [AXUIElement], !m.isEmpty {
                    out.append(contentsOf: m)
                    start += m.count
                } else { break }
            }
        }
        return out
    }
    if let arr = axAttr(el, kAXChildrenAttribute) as? [AXUIElement] { return arr }
    return []
}

func axPoint(_ el: AXUIElement, _ name: String) -> CGPoint? {
    guard let v = axAttr(el, name) else { return nil }
    let axv = v as! AXValue
    guard AXValueGetType(axv) == .cgPoint else { return nil }
    var p = CGPoint.zero
    return AXValueGetValue(axv, .cgPoint, &p) ? p : nil
}

func axSize(_ el: AXUIElement, _ name: String) -> CGSize? {
    guard let v = axAttr(el, name) else { return nil }
    let axv = v as! AXValue
    guard AXValueGetType(axv) == .cgSize else { return nil }
    var s = CGSize.zero
    return AXValueGetValue(axv, .cgSize, &s) ? s : nil
}

func axActions(_ el: AXUIElement) -> [String] {
    var names: CFArray?
    guard AXUIElementCopyActionNames(el, &names) == .success, let a = names as? [String] else { return [] }
    // 系统偶尔把自定义动作描述混进来（多行 "Name:...Target:..."），过滤掉
    return a.filter { s in
        s.count < 64 && !s.contains("\n") && s.hasPrefix("AX")
    }
}

func axPid(_ el: AXUIElement) -> pid_t {
    var pid: pid_t = 0
    AXUIElementGetPid(el, &pid)
    return pid
}

// 私有符号（仅用于 AX→CGWindowID 映射，有公开回退路径）
typealias AXGetWindowFn = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError

let axGetWindowSym: AXGetWindowFn? = {
    guard let p = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementGetWindow") else { return nil }
    return unsafeBitCast(p, to: AXGetWindowFn.self)
}()

func cgWindowId(of el: AXUIElement) -> CGWindowID? {
    guard let fn = axGetWindowSym else { return nil }
    var wid: CGWindowID = 0
    return fn(el, &wid) == .success && wid != 0 ? wid : nil
}

// MARK: - 便捷构造
func appElement(_ pid: pid_t) -> AXUIElement { AXUIElementCreateApplication(pid) }

func windowsOf(_ pid: pid_t) -> [AXUIElement] {
    guard let arr = axAttr(appElement(pid), kAXWindowsAttribute) as? [AXUIElement] else { return [] }
    return arr
}

func findRunningApp(_ token: String) -> NSRunningApplication? {
    let apps = NSWorkspace.shared.runningApplications
    if let pid = Int32(token) {
        return apps.first { $0.processIdentifier == pid }
    }
    let lower = token.lowercased()
    // bundle id 形态（含点）只做精确匹配，避免 "Safari" 误撞 SafariPlatformSupport.Helper
    if lower.contains(".") {
        if let byBundle = apps.first(where: { ($0.bundleIdentifier ?? "").lowercased() == lower }) { return byBundle }
        if let byPath = apps.first(where: { ($0.bundleURL?.path ?? "").lowercased() == lower }) { return byPath }
        return nil
    }
    // 普通名字：精确名 → 精确 bundle 最后段 → 名字包含
    if let byName = apps.first(where: { ($0.localizedName ?? "").lowercased() == lower }) { return byName }
    if let byBundleTail = apps.first(where: {
        (($0.bundleIdentifier ?? "").lowercased().split(separator: ".").last.map(String.init) ?? "") == lower
    }) { return byBundleTail }
    if let byPrefix = apps.first(where: {
        let n = ($0.localizedName ?? "").lowercased()
        return n.contains(lower) && !n.contains("helper")
    }) { return byPrefix }
    return nil
}
