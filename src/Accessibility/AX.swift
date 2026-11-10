import Foundation
import AppKit
import ApplicationServices

// MARK: - AX 快照模型
struct AXItem {
    var index: Int
    var path: [Int]
    var depth: Int
    var role: String
    var subrole: String
    var title: String
    var desc: String
    var value: String
    var identifier: String
    var pos: CGPoint?
    var size: CGSize?
    var enabled: Bool
    var actions: [String]
    var childCount: Int
}

struct AXSnapshot {
    var pid: pid_t
    var items: [AXItem]
    var truncated: Bool
    var elapsedMs: Int
}

let ignoreAttrValueRoles: Set<String> = [
    "AXScrollBar", "AXSplitter", "AXMenuBar", "AXMenuBarItem", "AXStaticText"
]

/// 去掉值里的零宽/方向控制符（Calculator 等 App 会在数字里插 U+200E）
func cleanText(_ s: String) -> String {
    let junk: Set<Unicode.Scalar> = ["\u{200E}", "\u{200F}", "\u{200B}", "\u{202A}", "\u{202C}", "\u{00A0}"]
    var out = String.UnicodeScalarView()
    for u in s.unicodeScalars where !junk.contains(u) { out.append(u) }
    return String(out).trimmingCharacters(in: .whitespaces)
}

/// 统一的子节点枚举顺序（walk 与 index→element 回查必须共用，否则索引错位）
func childrenForWalk(_ el: AXUIElement, depth: Int, skipMenuBar: Bool) -> [AXUIElement] {
    var kids = axChildren(el)
    if skipMenuBar && depth == 0 {
        kids = kids.filter { (axStr($0, kAXRoleAttribute) ?? "") != "AXMenuBar" }
        kids.sort { a, b in
            (axStr(a, kAXRoleAttribute) == "AXWindow" ? 0 : 1) < (axStr(b, kAXRoleAttribute) == "AXWindow" ? 0 : 1)
        }
    }
    return kids
}

func walkAX(pid: pid_t, maxDepth: Int, maxNodes: Int, includeActions: Bool,
            skipMenuBar: Bool = true) -> AXSnapshot {
    let t0 = Date()
    var items: [AXItem] = []
    var truncated = false
    let root = appElement(pid)

    func visit(_ el: AXUIElement, path: [Int], depth: Int) {
        if items.count >= maxNodes { truncated = true; return }
        let role = axStr(el, kAXRoleAttribute) ?? "?"
        let subrole = axStr(el, kAXSubroleAttribute) ?? ""
        var valueStr = ""
        if let v = axAttr(el, kAXValueAttribute) {
            if let s = v as? String { valueStr = cleanText(s) }
            else if let n = v as? NSNumber { valueStr = n.stringValue }
        }
        let item = AXItem(
            index: items.count,
            path: path,
            depth: depth,
            role: role,
            subrole: subrole,
            title: axStr(el, kAXTitleAttribute) ?? "",
            desc: axStr(el, kAXDescriptionAttribute) ?? axStr(el, "AXRoleDescription") ?? "",
            value: valueStr.count > 300 ? String(valueStr.prefix(300)) + "…" : valueStr,
            identifier: axStr(el, "AXIdentifier") ?? "",
            pos: axPoint(el, kAXPositionAttribute),
            size: axSize(el, kAXSizeAttribute),
            enabled: (axAttr(el, kAXEnabledAttribute) as? Bool) ?? true,
            actions: includeActions ? axActions(el) : [],
            childCount: 0
        )
        items.append(item)
        guard depth < maxDepth else { return }
        let kids = childrenForWalk(el, depth: depth, skipMenuBar: skipMenuBar)
        items[items.count - 1].childCount = kids.count
        for (i, k) in kids.enumerated() {
            visit(k, path: path + [i], depth: depth + 1)
            if items.count >= maxNodes { truncated = true; break }
        }
    }

    visit(root, path: [], depth: 0)
    return AXSnapshot(pid: pid, items: items, truncated: truncated,
                      elapsedMs: Int(Date().timeIntervalSince(t0) * 1000))
}

func renderAX(_ snap: AXSnapshot, maxNodes: Int, showActions: Bool) -> String {
    var lines: [String] = []
    for it in snap.items.prefix(maxNodes) {
        let indent = String(repeating: "  ", count: it.depth)
        var parts: [String] = ["\(it.index)", it.role]
        if !it.subrole.isEmpty { parts.append("(\(it.subrole))") }
        if !it.title.isEmpty { parts.append("\"\(it.title)\"") }
        if !it.value.isEmpty { parts.append("value=\"\(it.value)\"") }
        if !it.desc.isEmpty { parts.append("desc=\"\(it.desc)\"") }
        if !it.identifier.isEmpty { parts.append("id=\(it.identifier)") }
        if let p = it.pos, let s = it.size {
            parts.append(String(format: "@(%.0f,%.0f %.0fx%.0f)", p.x, p.y, s.width, s.height))
        }
        if !it.enabled { parts.append("disabled") }
        if showActions && !it.actions.isEmpty { parts.append("[\(it.actions.joined(separator: ","))]") }
        lines.append(indent + parts.joined(separator: " "))
    }
    if snap.truncated { lines.append("… (已截断)") }
    return lines.joined(separator: "\n")
}

func snapshotFile(_ pid: pid_t) -> URL {
    stateDir().appendingPathComponent("snap-\(pid).json")
}

func saveSnapshot(_ snap: AXSnapshot) {
    let arr: [[String: Any]] = snap.items.map { it in
        ["index": it.index, "path": it.path, "role": it.role, "title": it.title]
    }
    if let data = try? JSONSerialization.data(withJSONObject: arr) {
        try? data.write(to: snapshotFile(snap.pid))
    }
}

func loadSnapshotPaths(_ pid: pid_t) -> [[Int]]? {
    guard let data = try? Data(contentsOf: snapshotFile(pid)),
          let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
    return arr.compactMap { d -> [Int]? in
        guard let p = d["path"] as? [Int] else { return nil }
        return p
    }
}

func elementAt(pid: pid_t, path: [Int], skipMenuBar: Bool = true) -> AXUIElement? {
    var el = appElement(pid)
    for (depth, idx) in path.enumerated() {
        let kids = childrenForWalk(el, depth: depth, skipMenuBar: skipMenuBar)
        guard idx >= 0, idx < kids.count else { return nil }
        el = kids[idx]
    }
    return el
}

// MARK: - 命令：tree
func cmdAXTree(_ args: Args) {
    gJSONMode = args.flag("json")
    gPretty = args.flag("pretty")
    let pid = resolvePid(args)
    let maxDepth = args.int("depth") ?? 12
    let maxNodes = args.int("max") ?? 2000
    let snap = walkAX(pid: pid, maxDepth: maxDepth, maxNodes: maxNodes, includeActions: !args.flag("no-actions"),
                      skipMenuBar: !args.flag("menubar"))
    saveSnapshot(snap)
    if gJSONMode {
        emit(["ok": true, "pid": Int(pid), "count": snap.items.count, "truncated": snap.truncated,
              "elapsedMs": snap.elapsedMs,
              "items": snap.items.map { it -> [String: Any] in
                  var d: [String: Any] = ["index": it.index, "depth": it.depth, "role": it.role,
                                          "path": it.path.map { $0 }]
                  if !it.subrole.isEmpty { d["subrole"] = it.subrole }
                  if !it.title.isEmpty { d["title"] = it.title }
                  if !it.value.isEmpty { d["value"] = it.value }
                  if !it.desc.isEmpty { d["desc"] = it.desc }
                  if !it.identifier.isEmpty { d["identifier"] = it.identifier }
                  if let p = it.pos { d["x"] = p.x; d["y"] = p.y }
                  if let s = it.size { d["w"] = s.width; d["h"] = s.height }
                  if !it.enabled { d["enabled"] = false }
                  if !it.actions.isEmpty { d["actions"] = it.actions }
                  d["children"] = it.childCount
                  return d
              }])
    } else {
        emitText(renderAX(snap, maxNodes: maxNodes, showActions: !args.flag("no-actions")))
        if args.flag("verbose") {
            FileHandle.standardError.write("nodes=\(snap.items.count) elapsed=\(snap.elapsedMs)ms\n".data(using: .utf8)!)
        }
    }
    exit(0)
}

// MARK: - 命令：find
func cmdAXFind(_ args: Args) {
    gJSONMode = args.flag("json")
    gPretty = args.flag("pretty")
    let pid = resolvePid(args)
    let text = (args.str("text") ?? "").lowercased()
    let roleFilter = args.str("role")?.lowercased()
    let actionFilter = args.str("action")?.lowercased()
    let exact = args.flag("exact")
    guard !text.isEmpty || roleFilter != nil || actionFilter != nil else { fail("至少给 --text / --role / --action 之一") }
    let snap = walkAX(pid: pid, maxDepth: args.int("depth") ?? 15, maxNodes: args.int("max") ?? 4000, includeActions: true,
                      skipMenuBar: !args.flag("menubar"))
    saveSnapshot(snap)  // find 也写快照，保证后续 --index 与本次结果同源
    let hits = snap.items.filter { it in
        if let r = roleFilter, !it.role.lowercased().contains(r) && !it.subrole.lowercased().contains(r) { return false }
        if let a = actionFilter, !it.actions.contains(where: { $0.lowercased().contains(a) }) { return false }
        if !text.isEmpty {
            if exact {
                // 精确模式：identifier / desc / title 任一完全相等才算命中，避免 "9" 撞 "99"
                let cands = [it.identifier, it.desc, it.title, it.value].map { $0.lowercased() }
                if !cands.contains(text) { return false }
            } else {
                let hay = [it.title, it.value, it.desc, it.identifier, it.role, it.subrole].joined(separator: " ").lowercased()
                if !hay.contains(text) { return false }
            }
        }
        return true
    }
    if gJSONMode {
        emit(["ok": true, "count": hits.count, "hits": hits.map { it -> [String: Any] in
            ["index": it.index, "path": it.path, "role": it.role, "subrole": it.subrole,
             "title": it.title, "value": it.value, "desc": it.desc, "actions": it.actions]
        }])
    } else {
        if hits.isEmpty { emitText("(无匹配)") }
        for it in hits.prefix(80) {
            let posStr = it.pos.map { String(format: "@(%.0f,%.0f)", $0.x, $0.y) } ?? ""
            let v = it.value.isEmpty ? "" : " value=\"\(it.value)\""
            emitText("[\(it.index)] path=\(it.path.map(String.init).joined(separator: "/")) \(it.role) \"\(it.title)\"\(v) \(posStr) \(it.actions.isEmpty ? "" : "actions=\(it.actions)")")
        }
    }
    exit(0)
}

// MARK: - 命令：act / set
func resolveElement(_ args: Args, pid: pid_t) -> AXUIElement {
    if let idx = args.int("index") {
        guard let paths = loadSnapshotPaths(pid), idx >= 0, idx < paths.count else {
            fail("快照里没有 index=\(idx)，先跑一次 ax-tree")
        }
        guard let el = elementAt(pid: pid, path: paths[idx]) else { fail("index=\(idx) 对应元素已失效，重新 ax-tree") }
        return el
    }
    if let p = args.str("path") {
        let path = p.split(separator: "/").compactMap { Int($0) }
        guard let el = elementAt(pid: pid, path: path) else { fail("path 无效: \(p)") }
        return el
    }
    if let wid = args.int("window") {
        for w in windowsOf(pid) where cgWindowId(of: w) == CGWindowID(wid) { return w }
        fail("找不到窗口 \(wid)")
    }
    if let all = axAttr(appElement(pid), kAXWindowsAttribute) as? [AXUIElement], let w = all.first {
        return w
    }
    return appElement(pid)
}

func cmdAXAct(_ args: Args) {
    gJSONMode = args.flag("json")
    let pid = resolvePid(args)
    let el = resolveElement(args, pid: pid)
    let action = args.str("action") ?? kAXPressAction as String
    enforceGuard(pid: pid, action: "ax-act \(action)")
    let err = AXUIElementPerformAction(el, action as CFString)
    let role = axStr(el, kAXRoleAttribute) ?? "?"
    let available = axActions(el)
    if gJSONMode {
        emit(["ok": err == .success, "action": action, "role": role,
              "error": err == .success ? "" : axErrorName(err), "availableActions": available])
    } else {
        emitText(err == .success ? "✅ \(action) on \(role)"
                 : "❌ \(action) 失败: \(axErrorName(err))  可用: \(available)")
    }
    exit(err == .success ? 0 : 1)
}

func cmdAXSet(_ args: Args) {
    gJSONMode = args.flag("json")
    let pid = resolvePid(args)
    let el = resolveElement(args, pid: pid)
    let attr = args.str("attr") ?? kAXValueAttribute as String
    enforceGuard(pid: pid, action: "ax-set \(attr)")
    let value = args.str("value") ?? ""
    var err: AXError
    if attr == kAXValueAttribute as String {
        // 先试 String，失败再试 数字
        err = AXUIElementSetAttributeValue(el, attr as CFString, value as CFString)
        if err == .illegalArgument || err == .failure, let d = Double(value) {
            err = AXUIElementSetAttributeValue(el, attr as CFString, NSNumber(value: d))
        }
    } else if attr == kAXPositionAttribute as String || attr == kAXSizeAttribute as String {
        fail("位置/尺寸请用 ax-move / ax-resize")
    } else {
        err = AXUIElementSetAttributeValue(el, attr as CFString, value as CFString)
    }
    if gJSONMode {
        emit(["ok": err == .success, "attr": attr, "error": err == .success ? "" : axErrorName(err)])
    } else {
        emitText(err == .success ? "✅ \(attr) = \(value)" : "❌ 设置失败: \(axErrorName(err))")
    }
    exit(err == .success ? 0 : 1)
}

func axErrorName(_ e: AXError) -> String {
    switch e {
    case .success: return "success"
    case .failure: return "failure"
    case .illegalArgument: return "illegalArgument"
    case .invalidUIElement: return "invalidUIElement"
    case .invalidUIElementObserver: return "invalidUIElementObserver"
    case .cannotComplete: return "cannotComplete"
    case .attributeUnsupported: return "attributeUnsupported"
    case .actionUnsupported: return "actionUnsupported"
    case .notificationUnsupported: return "notificationUnsupported"
    case .notImplemented: return "notImplemented"
    case .notificationAlreadyRegistered: return "notificationAlreadyRegistered"
    case .notificationNotRegistered: return "notificationNotRegistered"
    case .apiDisabled: return "apiDisabled(未授权辅助功能)"
    case .noValue: return "noValue"
    case .parameterizedAttributeUnsupported: return "parameterizedAttributeUnsupported"
    case .notEnoughPrecision: return "notEnoughPrecision"
    @unknown default: return "unknown(\(e.rawValue))"
    }
}

/// 命中测试：屏幕点 → UI 元素
func cmdAXHit(_ args: Args) {
    gJSONMode = args.flag("json")
    let x = args.dbl("x") ?? 0
    let y = args.dbl("y") ?? 0
    let sys = AXUIElementCreateSystemWide()
    var el: AXUIElement?
    let err = AXUIElementCopyElementAtPosition(sys, Float(x), Float(y), &el)
    guard err == .success, let e = el else {
        if gJSONMode { emit(["ok": false, "error": axErrorName(err)]) } else { emitText("无元素: \(axErrorName(err))") }
        exit(1)
    }
    let info: [String: Any] = [
        "ok": true, "role": axStr(e, kAXRoleAttribute) ?? "", "subrole": axStr(e, kAXSubroleAttribute) ?? "",
        "title": axStr(e, kAXTitleAttribute) ?? "", "desc": axStr(e, kAXDescriptionAttribute) ?? "",
        "value": (axAttr(e, kAXValueAttribute) as? String) ?? "",
        "pid": Int(axPid(e)), "actions": axActions(e)
    ]
    if gJSONMode { emit(info) } else {
        emitText("\(info["role"] ?? "") \"\(info["title"] ?? "")\" pid=\(info["pid"] ?? 0) actions=\(info["actions"] ?? [])")
    }
    exit(0)
}

func resolvePid(_ args: Args) -> pid_t {
    if let p = args.int("pid") { return pid_t(p) }
    if let t = args.str("app") {
        guard let app = findRunningApp(t) else { fail("找不到应用: \(t)") }
        return app.processIdentifier
    }
    // 前台 App
    if let front = NSWorkspace.shared.frontmostApplication { return front.processIdentifier }
    fail("需要 --pid 或 --app")
}

// MARK: - 命令：app-state（Codex 风格：截图 + AX 文本摘要）
func cmdAppState(_ args: Args) {
    gJSONMode = args.flag("json")
    gPretty = args.flag("pretty")
    let pid = resolvePid(args)
    let maxNodes = args.int("max") ?? 900
    let snap = walkAX(pid: pid, maxDepth: args.int("depth") ?? 14, maxNodes: maxNodes, includeActions: true,
                      skipMenuBar: !args.flag("menubar"))
    saveSnapshot(snap)
    let text = renderAX(snap, maxNodes: maxNodes, showActions: true)

    if let wid = args.int("window") ?? mainWindowId(for: pid).map({ Int($0) }) {
        let fm = FileManager.default
        let outURL = tmpDir().appendingPathComponent("appstate-\(pid)-\(Int(Date().timeIntervalSince1970)).png")
        if captureWindowOnce(windowId: CGWindowID(wid), maxWidth: args.int("max-width"), to: outURL) {
            let size = (try? fm.attributesOfItem(atPath: outURL.path)[.size] as? Int) ?? 0
            if gJSONMode {
                emit(["ok": true, "pid": Int(pid), "app": findRunningApp("\(pid)")?.localizedName ?? "",
                      "windowId": wid, "screenshot": outURL.path, "screenshotBytes": size ?? 0,
                      "axText": text, "nodeCount": snap.items.count])
            } else {
                emitText(text)
                emitText("\n[截图] \(outURL.path)")
            }
            exit(0)
        }
    }
    if gJSONMode {
        emit(["ok": true, "pid": Int(pid), "axText": text, "nodeCount": snap.items.count, "screenshot": NSNull()])
    } else {
        emitText(text)
    }
    exit(0)
}
