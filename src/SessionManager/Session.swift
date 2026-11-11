import Foundation
import AppKit
import CoreGraphics
import ApplicationServices

// MARK: - 会话层（MacBackgroundSession）
//
// 目标：把「窗口捕获 / UI 识别 / 后台投递 / 虚拟光标 / 结果验证」串成一个
// 可复用、可持久、可断言的会话对象，任何 WorkBuddy 工作流都通过同一套入口调用，
// 不必各自重写后台点击逻辑。
//
// 设计取舍：
//   * 不常驻 daemon —— 状态落盘到 ~/.wbcu/sessions/<id>.json，
//     每次子命令重新加载。崩溃/超时不会留下半死进程，也不会丢会话。
//   * 每个命令独立进程 → 天然具备错误隔离，单条命令挂掉不影响会话。
//   * Ghost Cursor 仍是独立 daemon（可视化层），会话只负责通知它去哪。

struct CUError {
    static let permissionDenied = "permission_denied"
    static let windowNotFound = "window_not_found"
    static let targetGone = "target_gone"
    static let noPressableElement = "no_pressable_element"
    static let unsupportedBackgroundClick = "unsupported_background_click"
    static let noObservableChange = "no_observable_change"
    static let sessionNotFound = "session_not_found"
    static let badRequest = "bad_request"
}

// MARK: - 会话状态

struct SessionState {
    var id: String
    var bundleId: String
    var appName: String
    var pid: pid_t
    var windowId: CGWindowID
    var windowFrame: CGRect
    var createdAt: Double
    var ghostEnabled: Bool
    var captureCount: Int
    var actionCount: Int
    var lastFingerprint: String
    var lastVerification: String

    func toDict() -> [String: Any] {
        [
            "id": id,
            "bundleId": bundleId,
            "appName": appName,
            "pid": Int(pid),
            "windowId": Int(windowId),
            "windowFrame": ["x": windowFrame.minX, "y": windowFrame.minY,
                            "w": windowFrame.width, "h": windowFrame.height],
            "createdAt": createdAt,
            "ageSeconds": Int(Date().timeIntervalSince1970 - createdAt),
            "ghostEnabled": ghostEnabled,
            "captureCount": captureCount,
            "actionCount": actionCount,
            "lastVerification": lastVerification
        ]
    }

    static func from(_ d: [String: Any]) -> SessionState? {
        guard let id = d["id"] as? String,
              let bid = d["bundleId"] as? String,
              let pid = d["pid"] as? Int,
              let wid = d["windowId"] as? Int,
              let f = d["windowFrame"] as? [String: Any] else { return nil }
        let frame = CGRect(x: (f["x"] as? Double) ?? 0, y: (f["y"] as? Double) ?? 0,
                           width: (f["w"] as? Double) ?? 0, height: (f["h"] as? Double) ?? 0)
        return SessionState(
            id: id, bundleId: bid,
            appName: (d["appName"] as? String) ?? bid,
            pid: pid_t(pid), windowId: CGWindowID(wid), windowFrame: frame,
            createdAt: (d["createdAt"] as? Double) ?? Date().timeIntervalSince1970,
            ghostEnabled: (d["ghostEnabled"] as? Bool) ?? true,
            captureCount: (d["captureCount"] as? Int) ?? 0,
            actionCount: (d["actionCount"] as? Int) ?? 0,
            lastFingerprint: (d["lastFingerprint"] as? String) ?? "",
            lastVerification: (d["lastVerification"] as? String) ?? "not_requested"
        )
    }
}

func sessionsDir() -> URL {
    let d = stateDir().appendingPathComponent("sessions")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

func sessionPath(_ id: String) -> URL { sessionsDir().appendingPathComponent("\(id).json") }

func saveSession(_ s: SessionState) {
    if let d = try? JSONSerialization.data(withJSONObject: s.toDict(), options: [.prettyPrinted, .sortedKeys]) {
        try? d.write(to: sessionPath(s.id))
    }
}

func loadSession(_ id: String) -> SessionState? {
    guard let d = try? Data(contentsOf: sessionPath(id)),
          let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
    return SessionState.from(o)
}

func allSessions() -> [SessionState] {
    let urls = (try? FileManager.default.contentsOfDirectory(at: sessionsDir(),
                includingPropertiesForKeys: nil)) ?? []
    return urls.filter { $0.pathExtension == "json" }.compactMap { u -> SessionState? in
        guard let d = try? Data(contentsOf: u),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        return SessionState.from(o)
    }.sorted { $0.createdAt < $1.createdAt }
}

// MARK: - 目标解析与存活检查

/// 目标进程是否还活着、窗口是否还在（决定 target_gone）
func sessionTargetAlive(_ s: SessionState) -> Bool {
    guard let app = NSRunningApplication(processIdentifier: s.pid), !app.isTerminated else { return false }
    let wins = listCGWindows(onScreenOnly: false)
    return wins.contains { $0.id == s.windowId && $0.pid == s.pid }
}

/// 窗口移动/缩放后刷新 frame（Ghost 跟随与坐标换算都依赖它）
func refreshSessionWindow(_ s: inout SessionState) -> Bool {
    guard let rec = listCGWindows(onScreenOnly: false).first(where: { $0.id == s.windowId }) else { return false }
    s.windowFrame = rec.bounds
    s.pid = rec.pid
    return true
}

/// 找到某 app 的主窗口（排除共享指示器那种 AXDialog 附属窗）
func resolveMainWindow(pid: pid_t) -> (CGWindowID, CGRect)? {
    if let wid = mainWindowId(for: pid),
       let rec = listCGWindows(onScreenOnly: false).first(where: { $0.id == wid }) {
        return (wid, rec.bounds)
    }
    guard let best = pickMainWindowRecord(listCGWindows(onScreenOnly: false), pid: pid)
    else { return nil }
    return (best.id, best.bounds)
}

/// 会话内按 index 取元素：必须复用与 ax-tree 相同的快照路径
func sessionElement(_ s: SessionState, index: Int) -> AXUIElement? {
    guard let paths = loadSnapshotPaths(s.pid), index >= 0, index < paths.count else { return nil }
    return elementAt(pid: s.pid, path: paths[index])
}

/// 读取整个 AX 树里的所有非空文本值（用于 --expect 断言）
func sessionTextValues(_ s: SessionState, maxNodes: Int = 800) -> [String] {
    let snap = walkAX(pid: s.pid, maxDepth: 12, maxNodes: maxNodes, includeActions: false, skipMenuBar: true)
    return snap.items.compactMap { it in
        let v = it.value.trimmingCharacters(in: .whitespacesAndNewlines)
        return v.isEmpty ? nil : v
    }
}

// MARK: - 会话命令

func cmdSession(_ args: Args) {
    gJSONMode = args.flag("json")
    gPretty = args.flag("pretty")
    let sub = args.positional.first ?? "list"

    switch sub {
    case "start": sessionStart(args)
    case "list":  sessionList()
    case "state": sessionState(args)
    case "capture": sessionCapture(args)
    case "inspect": sessionInspect(args)
    case "click": sessionClick(args)
    case "type":  sessionType(args)
    case "key":   sessionKey(args)
    case "cursor": sessionCursor(args)
    case "verify": sessionVerify(args)
    case "end":   sessionEnd(args)
    default:
        emitText("""
        wbcu session <start|list|state|capture|inspect|click|type|key|cursor|verify|end>

        示例：
          wbcu session start --app com.apple.calculator
          wbcu session capture --id s1 --out /tmp/w.png
          wbcu session inspect --id s1 --max 40
          wbcu session click   --id s1 --x 300 --y 400 --label "7"
          wbcu session click   --id s1 --text "全部清除" --exact
          wbcu session verify  --id s1 --expect 15
          wbcu session end     --id s1
        """)
        exit(0)
    }
}

private func needSession(_ args: Args) -> SessionState {
    guard let id = args.str("id") else {
        emitError(CUError.badRequest, "缺少 --id（先用 wbcu session start）")
    }
    guard var s = loadSession(id) else {
        emitError(CUError.sessionNotFound, "会话不存在: \(id)")
    }
    if !sessionTargetAlive(s) {
        if !refreshSessionWindow(&s) {
            emitError(CUError.targetGone, "目标应用或窗口已消失（pid \(s.pid), window \(s.windowId)）")
        }
    }
    _ = refreshSessionWindow(&s)
    return s
}

func emitError(_ code: String, _ msg: String, extra: [String: Any] = [:]) -> Never {
    var out: [String: Any] = ["ok": false, "error": code, "message": msg]
    for (k, v) in extra { out[k] = v }
    if gJSONMode { emit(out) } else { emitText("❌ [\(code)] \(msg)") }
    exit(code == CUError.permissionDenied ? 3 : 1)
}

// MARK: start

private func sessionStart(_ args: Args) {
    let p = currentPermissions()
    guard p.accessibility else {
        emitError(CUError.permissionDenied,
                  "辅助功能（Accessibility）未授权，无法读取/操作目标应用。请先 wbcu perm --prompt 并在系统设置中允许。")
    }
    // 只做 UI 读取不需要屏幕录制；要 capture 才需要。这里不强制，但记入 ableToCapture。
    guard let token = args.str("app") ?? args.str("pid") else {
        emitError(CUError.badRequest, "需要 --app <bundleId|名称|pid>")
    }
    guard let app = findRunningApp(token) else {
        emitError(CUError.windowNotFound, "应用未运行: \(token)")
    }
    let pid = app.processIdentifier
    enforceGuard(pid: pid, action: "session start")

    var wid: CGWindowID
    var frame: CGRect
    if let explicit = args.int("window") {
        guard let rec = listCGWindows(onScreenOnly: false).first(where: { $0.id == CGWindowID(explicit) }) else {
            emitError(CUError.windowNotFound, "窗口不存在: \(explicit)")
        }
        wid = CGWindowID(explicit); frame = rec.bounds
        if rec.pid != pid { emitError(CUError.badRequest, "窗口 \(explicit) 不属于 pid \(pid)") }
    } else {
        guard let r = resolveMainWindow(pid: pid) else {
            emitError(CUError.windowNotFound, "pid \(pid) 没有可用主窗口（可能全是 AXDialog / 未上屏）")
        }
        wid = r.0; frame = r.1
    }

    let id = "s\(Int(Date().timeIntervalSince1970 * 1000) % 100000)"
    let ghost = !args.flag("no-ghost")
    var s = SessionState(id: id, bundleId: app.bundleIdentifier ?? token,
                         appName: app.localizedName ?? token,
                         pid: pid, windowId: wid, windowFrame: frame,
                         createdAt: Date().timeIntervalSince1970,
                         ghostEnabled: ghost, captureCount: 0, actionCount: 0,
                         lastFingerprint: axFingerprint(pid: pid).hash,
                         lastVerification: "not_requested")
    if ghost { ensureGhostDaemon() }
    saveSession(s)

    let out: [String: Any] = [
        "ok": true, "session": s.toDict(),
        "permissions": ["accessibility": p.accessibility, "screenRecording": p.screenRecording,
                        "postEvent": p.postEvent],
        "ableToCapture": p.screenRecording,
        "note": "会话已建立；后续用 --id \(id) 复用同一引擎，不必重复解析窗口。"
    ]
    if gJSONMode { emit(out) } else {
        emitText("✅ 会话 \(id) → \(s.appName) (\(s.bundleId)) pid \(pid) window \(wid) \(Int(frame.width))x\(Int(frame.height))")
        emitText("   后续：wbcu session inspect --id \(id)")
        if !p.screenRecording { emitText("   ⚠️ 屏幕录制未授权：capture 会失败，但 AX 操作仍可用") }
    }
    exit(0)
}

// MARK: list / state

private func sessionList() {
    let list = allSessions()
    let out: [String: Any] = ["ok": true, "count": list.count, "sessions": list.map { $0.toDict() }]
    if gJSONMode { emit(out) } else if list.isEmpty { emitText("（无活动会话）") }
    else {
        for s in list {
            let alive = sessionTargetAlive(s) ? "alive" : "gone"
            emitText("\(s.id)  \(s.appName)  pid \(s.pid)  win \(s.windowId)  \(alive)  age \(Int(Date().timeIntervalSince1970 - s.createdAt))s")
        }
    }
    exit(0)
}

private func sessionState(_ args: Args) {
    var s = needSession(args)
    _ = refreshSessionWindow(&s)
    saveSession(s)
    let out: [String: Any] = [
        "ok": true, "session": s.toDict(),
        "targetAlive": sessionTargetAlive(s),
        "targetActive": NSRunningApplication(processIdentifier: s.pid)?.isActive ?? false,
        "fingerprint": axFingerprint(pid: s.pid).hash,
        "cursorDaemon": ghostDaemonAlive()
    ]
    if gJSONMode { emit(out) } else {
        emitText("会话 \(s.id)  \(s.appName)  pid \(s.pid)  win \(s.windowId)")
        emitText("  窗口 \(Int(s.windowFrame.minX)),\(Int(s.windowFrame.minY)) \(Int(s.windowFrame.width))x\(Int(s.windowFrame.height))")
        emitText("  操作 \(s.actionCount) 次  截图 \(s.captureCount) 次  最近验证 \(s.lastVerification)")
    }
    exit(0)
}

// MARK: capture

private func sessionCapture(_ args: Args) {
    var s = needSession(args)
    let perms = currentPermissions()
    guard perms.screenRecording else {
        emitError(CUError.permissionDenied, "屏幕录制未授权，无法捕获窗口画面")
    }
    _ = refreshSessionWindow(&s)
    let outPath = args.str("out") ?? tmpDir().appendingPathComponent("cap-\(s.id).png").path
    let url = URL(fileURLWithPath: outPath)
    guard captureWindowOnce(windowId: s.windowId, maxWidth: args.int("max-width"), to: url) else {
        emitError("capture_failed", "窗口捕获失败（window \(s.windowId)），可能窗口已关闭或权限不足")
    }
    s.captureCount += 1
    saveSession(s)
    var size = ""
    if let src = CGImageSourceCreateWithURL(url as CFURL, nil),
       let img = CGImageSourceCreateImageAtIndex(src, 0, nil) {
        size = "\(img.width)x\(img.height)"
    }
    let out: [String: Any] = ["ok": true, "path": outPath, "pixels": size,
                              "windowLocalOrigin": ["x": s.windowFrame.minX, "y": s.windowFrame.minY],
                              "session": s.id]
    if gJSONMode { emit(out) } else { emitText("✅ 捕获 \(s.windowId) → \(outPath)  \(size)") }
    exit(0)
}

// MARK: inspect

private func sessionInspect(_ args: Args) {
    let s = needSession(args)
    let depth = args.int("depth") ?? 12
    let maxN = args.int("max") ?? 200
    let snap = walkAX(pid: s.pid, maxDepth: depth, maxNodes: maxN * 2,
                      includeActions: true, skipMenuBar: !args.flag("menubar"))
    saveSnapshot(snap)
    if gJSONMode {
        let items = snap.items.prefix(maxN).map { it -> [String: Any] in
            var d: [String: Any] = ["index": it.index, "role": it.role, "path": it.path]
            if !it.title.isEmpty { d["title"] = it.title }
            if !it.value.isEmpty { d["value"] = it.value }
            if !it.desc.isEmpty { d["desc"] = it.desc }
            if !it.identifier.isEmpty { d["identifier"] = it.identifier }
            if let p = it.pos, let sz = it.size {
                d["x"] = p.x; d["y"] = p.y; d["w"] = sz.width; d["h"] = sz.height
            }
            if !it.actions.isEmpty { d["actions"] = it.actions }
            return d
        }
        emit(["ok": true, "session": s.id, "count": snap.items.count, "items": Array(items)])
    } else {
        emitText(renderAX(snap, maxNodes: maxN, showActions: true))
    }
    exit(0)
}

// MARK: click

private func sessionClick(_ args: Args) {
    var s = needSession(args)
    _ = refreshSessionWindow(&s)

    let showCursor = !args.flag("no-ghost") && s.ghostEnabled
    let verify = !args.flag("no-verify")
    let label = args.str("label") ?? "click"
    let cursorMode = (args.str("ghost-mode") ?? "fast").lowercased()
    let useExperience = !args.flag("no-experience")
    let tStart = nowNs()

    var point: CGPoint
    var targetDesc: [String: Any] = [:]
    var preResolved: AXUIElement? = nil
    var prePath: [Int]? = nil
    var learnLabel = ""
    var learnRole = ""
    var learnIdentifier = ""
    var observeEl: AXUIElement? = nil
    var observePath: [Int]? = nil
    var snapBefore: AXSnapshot? = nil
    var expStatus = "disabled"
    var resolveMs = 0.0

    // ---------- 1) 定位目标 ----------
    let tResolve = nowNs()
    if let idx = args.int("element") {
        guard let el = sessionElement(s, index: idx) else {
            emitError(CUError.noPressableElement, "index \(idx) 无效：先跑 wbcu session inspect 重新取快照")
        }
        preResolved = el
        if let paths = loadSnapshotPaths(s.pid), idx < paths.count { prePath = paths[idx] }
        learnRole = axStr(el, kAXRoleAttribute) ?? ""
        learnIdentifier = axStr(el, "AXIdentifier") ?? ""
        learnLabel = axStr(el, kAXTitleAttribute) ?? axStr(el, kAXDescriptionAttribute) ?? ""
        expStatus = "explicit"
        if let p = axPoint(el, kAXPositionAttribute), let sz = axSize(el, kAXSizeAttribute) {
            point = CGPoint(x: p.x + sz.width / 2, y: p.y + sz.height / 2)
        } else {
            emitError(CUError.noPressableElement, "元素 \(idx) 没有坐标")
        }
        targetDesc = ["element": idx]

    } else if let text = args.str("text") {
        learnLabel = text
        // 先看经验库：命中就 O(depth) 回查，跳过整树遍历
        if useExperience, let hit = expLookup(app: s.bundleId, pid: s.pid, intent: "click", label: text) {
            preResolved = hit.element
            prePath = hit.entry.path
            learnRole = hit.entry.role
            learnIdentifier = hit.entry.identifier
            expStatus = "hit(\(hit.entry.status))"
            resolveMs = hit.resolveMs
            // 事件驱动验证默认关闭：
            // 实测（Calculator，macOS 26.6）学到的观测元素常落在「上个表达式」上，
            // 只在表达式提交时变化，普通按键必然超时；而单次指纹遍历只要 ~10ms。
            // 所以默认走指纹，需要时用 --observe-watch 显式开启。
            if args.flag("observe-watch"),
               let op = hit.entry.observePath, let el = elementAt(pid: s.pid, path: op) {
                observeEl = el; observePath = op
            }
            // 命中路径也要给出坐标：AXPress 不需要它，但 targeted 兜底与光标定位要
            if let p = axPoint(hit.element, kAXPositionAttribute),
               let sz = axSize(hit.element, kAXSizeAttribute) {
                point = CGPoint(x: p.x + sz.width / 2, y: p.y + sz.height / 2)
            } else {
                point = CGPoint(x: s.windowFrame.midX, y: s.windowFrame.midY)
            }
        } else {
            expStatus = (useExperience && expStats(app: s.bundleId).entries > 0) ? "miss" : "cold"
            let snap = walkAX(pid: s.pid, maxDepth: 14, maxNodes: 2000,
                              includeActions: true, skipMenuBar: true)
            saveSnapshot(snap)
            let exact = args.flag("exact")
            let needle = text.lowercased()
            let hit = snap.items.first { it in
                let cands = [it.title, it.value, it.desc, it.identifier].map { $0.lowercased() }
                return exact ? cands.contains(needle) : cands.joined(separator: " ").contains(needle)
            }
            guard let h = hit else {
                emitError(CUError.noPressableElement, "没找到文本为「\(text)」的元素")
            }
            learnRole = h.role
            learnIdentifier = h.identifier
            if learnLabel.isEmpty { learnLabel = h.title.isEmpty ? h.desc : h.title }
            snapBefore = snap
            if let el = elementAt(pid: s.pid, path: h.path) { preResolved = el; prePath = h.path }
            guard let pos = h.pos, let sz = h.size else {
                emitError(CUError.noPressableElement, "元素没有坐标")
            }
            point = CGPoint(x: pos.x + sz.width / 2, y: pos.y + sz.height / 2)
        }
        targetDesc = ["matchedText": text, "experience": expStatus]
    } else {
        point = mousePointFromArgs(args)
        targetDesc = ["x": point.x, "y": point.y]
        expStatus = "coords"
    }
    if resolveMs == 0 { resolveMs = msSince(tResolve) }

    enforceGuard(pid: s.pid, action: "session click")

    // ---------- 2) 执行 ----------
    var opts = ActionOptions()
    opts.showCursor = showCursor
    opts.cursorMode = cursorMode
    opts.verify = verify
    opts.allowAX = (args.str("mode") ?? "auto") != "targeted"
    opts.preResolved = preResolved
    opts.observeElement = observeEl
    // 观测超时自适应：只在真的要用事件驱动时才去查经验里的失败计数。
    // （之前无条件查一次，等于命中路径跑了两遍经验查找，反而比不命中更慢。）
    if observeEl != nil {
        let prevFail = expLookup(app: s.bundleId, pid: s.pid, intent: "click",
                                 label: learnLabel)?.entry.observeFail ?? 0
        opts.observeTimeoutMs = args.int("timeout") ?? (prevFail > 0 ? 150 : 400)
    }
    opts.baselineFingerprint = s.lastFingerprint.isEmpty ? nil : s.lastFingerprint
    let outcome = performAgentAction(global: point, pid: s.pid, windowId: s.windowId,
                                     windowFrame: s.windowFrame, label: label, options: opts)

    // ---------- 3) 学习 ----------
    // 写经验的条件：
    //   a) 界面确实变了 —— 最强证据
    //   b) AXPress 返回成功但界面无差异 —— 元素找对了（应用接受了语义动作），
    //      只是这次操作幂等（如重复点「全部清除」）。路径仍然值得记，
    //      否则幂等按钮永远学不到，每次都退回全树遍历。
    // 反例（不学）：targeted 兜底成功但界面没变 —— 无法确认点对了地方。
    let learnedOK = (outcome.changed == true)
        || (outcome.mode == "ax" && outcome.changed == false)
    if verify, learnedOK, let path = prePath, !learnLabel.isEmpty {
        var learnedObserve = observePath
        if learnedObserve == nil, let before = snapBefore {
            // 冷启动顺手学会「该盯哪个元素」：下次验证直接监听它
            let after = walkAX(pid: s.pid, maxDepth: 14, maxNodes: 2000,
                               includeActions: false, skipMenuBar: true)
            learnedObserve = detectChangedPath(before: before, after: after)
        }
        expLearn(app: s.bundleId, pid: s.pid, intent: "click",
                 label: learnLabel, role: learnRole, identifier: learnIdentifier,
                 path: path, element: preResolved ?? appElement(s.pid),
                 windowFrame: s.windowFrame, actionMode: outcome.mode,
                 validation: outcome.changed == true
                     ? (learnedObserve == nil ? "fingerprint" : "axvalue")
                     : "axpress-only",
                 observePath: learnedObserve, latencyMs: Int(outcome.timing.total))
    } else if verify, outcome.changed == false, expStatus.hasPrefix("hit") {
        expRecordFailure(app: s.bundleId, intent: "click",
                         label: learnLabel, role: learnRole, identifier: learnIdentifier)
    }

    if let fp = outcome.fingerprintAfter { s.lastFingerprint = fp }
    if observeEl != nil, !learnLabel.isEmpty {
        // 成功观测一次就清零失败计数；连续 3 次才摘掉观测目标
        expNoteObserve(app: s.bundleId, intent: "click", label: learnLabel,
                       role: learnRole, identifier: learnIdentifier,
                       success: !outcome.observeStale)
    }
    s.actionCount += 1
    s.lastVerification = outcome.verification
    saveSession(s)

    var timing = outcome.timing
    timing.resolve = resolveMs
    timing.total = msSince(tStart)

    perfLog(["app": s.bundleId, "intent": "click", "label": label,
             "experience": expStatus, "mode": outcome.mode,
             "verification": outcome.verification, "via": outcome.via,
             "resolveMs": timing.resolve, "dispatchMs": timing.dispatch,
             "verifyMs": timing.verify, "cursorMs": timing.cursor,
             "totalMs": timing.total])

    var out = actionReport(outcome, windowId: s.windowId, pid: s.pid,
                           point: point, frame: s.windowFrame)
    // 会话层保留自己的上下文字段
    out["session"] = s.id
    out["target"] = targetDesc
    out["experience"] = expStatus
    out["timing"] = timing.dict()
    out["targetActivated"] = NSRunningApplication(processIdentifier: s.pid)?.isActive ?? false
    if !gJSONMode {
        let mark = outcome.ok ? "✅" : "❌"
        emitText(String(format: "%@ %@ exp=%@ verify=%@ via=%@  %.0fms (定位 %.0f / 投递 %.0f / 验证 %.0f)",
                        mark as NSString, outcome.mode as NSString, expStatus as NSString,
                        outcome.verification as NSString, outcome.via as NSString,
                        timing.total, timing.resolve, timing.dispatch, timing.verify))
        if !outcome.failureReason.isEmpty {
            emitText("   原因=\(outcome.failureReason)  窗口状态=\(TargetWindowVisibilityManager.humanNote(outcome.visibility))")
        }
    } else { emit(out) }
    // 没做成就不返回 0
    exit(outcome.ok ? 0 : 3)
}

// MARK: type（AXValue 优先，键盘兜底）

private func sessionType(_ args: Args) {
    var s = needSession(args)
    _ = refreshSessionWindow(&s)
    guard let text = args.str("text") else { emitError(CUError.badRequest, "需要 --text") }
    let fpBefore = axFingerprint(pid: s.pid)

    // 策略 1：直接写 AXValue（非激活窗口唯一可靠路径）
    var written = false
    var usedIndex: Int? = nil
    if let idx = args.int("element"), let el = sessionElement(s, index: idx) {
        let r = AXUIElementSetAttributeValue(el, kAXValueAttribute as CFString, text as CFTypeRef)
        written = (r == .success)
        usedIndex = idx
    } else {
        // 自动挑第一个可写的文本类元素（AXTextArea / AXTextField / AXComboBox）
        let snap = walkAX(pid: s.pid, maxDepth: 14, maxNodes: 1200,
                          includeActions: false, skipMenuBar: true)
        saveSnapshot(snap)
        let roleOK: Set<String> = ["AXTextArea", "AXTextField", "AXComboBox", "AXSearchField"]
        if let cand = snap.items.first(where: { roleOK.contains($0.role) }),
           let el = sessionElement(s, index: cand.index) {
            let r = AXUIElementSetAttributeValue(el, kAXValueAttribute as CFString, text as CFTypeRef)
            written = (r == .success)
            usedIndex = cand.index
        }
    }

    var mode = "axvalue"
    if !written {
        // 策略 2：定向键盘（需要目标有 field editor，成功率低，但仍然值得尝试）
        enforceGuard(pid: s.pid, action: "session type")
        typeText(text, pid: s.pid)
        mode = "targeted-keys"
    }
    usleep(160_000)
    let changed = axFingerprint(pid: s.pid).hash != fpBefore.hash
    s.actionCount += 1
    s.lastVerification = changed ? "changed" : "no_observable_change"
    saveSession(s)

    var out: [String: Any] = ["ok": true, "session": s.id, "mode": mode, "chars": text.count,
                              "element": usedIndex ?? -1, "verification": s.lastVerification,
                              "targetActivated": NSRunningApplication(processIdentifier: s.pid)?.isActive ?? false]
    if !written {
        out["warning"] = "AXValue 写入失败，已降级为定向键盘；非激活窗口通常收不到按键（需要 field editor）"
        out["error"] = CUError.noObservableChange
    }
    if gJSONMode { emit(out) }
    else {
        emitText("✅ typed \(text.count) chars via \(mode)  verify=\(s.lastVerification)")
        if !written { emitText("   ⚠️ 走了键盘兜底，非激活窗口可能无效") }
    }
    exit(0)
}

// MARK: key

private func sessionKey(_ args: Args) {
    var s = needSession(args)
    let spec = args.str("combo") ?? args.str("key") ?? ""
    guard let combo = parseKeyCombo(spec) else { emitError(CUError.badRequest, "无法解析按键: \(spec)") }
    enforceGuard(pid: s.pid, action: "session key \(spec)")
    let fpBefore = axFingerprint(pid: s.pid)
    pressKeyCombo(combo, pid: s.pid)
    usleep(200_000)
    let changed = axFingerprint(pid: s.pid).hash != fpBefore.hash
    s.actionCount += 1
    s.lastVerification = changed ? "changed" : "no_observable_change"
    saveSession(s)
    var out: [String: Any] = ["ok": true, "session": s.id, "combo": spec, "mode": "targeted-keys",
                              "verification": s.lastVerification,
                              "targetActivated": NSRunningApplication(processIdentifier: s.pid)?.isActive ?? false]
    if !changed {
        out["warning"] = "按键已投递但 UI 未变化：非激活窗口通常没有 field editor，依赖 key window 的快捷键不会触发；改用 ax-act / session type"
    }
    if gJSONMode { emit(out) } else { emitText("✅ key \(spec)  verify=\(s.lastVerification)") }
    exit(0)
}

// MARK: cursor

private func sessionCursor(_ args: Args) {
    let s = needSession(args)
    guard let x = args.dbl("x"), let y = args.dbl("y") else {
        emitError(CUError.badRequest, "需要 --x --y（窗口局部坐标）")
    }
    // 局部坐标 → 屏幕坐标 → 再由 ghost 内部转回局部，保证窗口移动后一致
    let global = windowGlobal(from: CGPoint(x: x, y: y), in: s.windowFrame)
    let st = ghostGoto(window: s.windowId,
                       local: CGPoint(x: x, y: y),
                       animated: args.flag("animate"),
                       label: args.str("label") ?? "")
    let out: [String: Any] = ["ok": st != nil, "session": s.id,
                              "global": ["x": global.x, "y": global.y],
                              "windowLocal": ["x": x, "y": y],
                              "cursor": st ?? ["used": false]]
    if gJSONMode { emit(out) } else { emitText("✅ cursor → 局部(\(Int(x)),\(Int(y)))") }
    exit(0)
}

// MARK: verify

private func sessionVerify(_ args: Args) {
    let s = needSession(args)
    let values = sessionTextValues(s)
    var out: [String: Any] = ["ok": true, "session": s.id, "values": values]
    if let expect = args.str("expect") {
        let hit = values.contains { $0.contains(expect) }
        out["expect"] = expect
        out["matched"] = hit
        out["ok"] = hit
        if !gJSONMode {
            emitText(hit ? "✅ 期望值「\(expect)」已出现" : "❌ 未找到期望值「\(expect)」，当前值: \(values.prefix(6))")
        }
        if !hit { if gJSONMode { emit(out) }; exit(1) }
    } else if !gJSONMode {
        emitText("当前可见文本值: \(values.prefix(10))")
    }
    emit(out)
    exit(0)
}

// MARK: end

private func sessionEnd(_ args: Args) {
    if args.flag("all") {
        let list = allSessions()
        for s in list { try? FileManager.default.removeItem(at: sessionPath(s.id)) }
        ghostHide()
        if gJSONMode { emit(["ok": true, "ended": list.map { $0.id }]) }
        else { emitText("✅ 已结束 \(list.count) 个会话，光标已隐藏") }
        exit(0)
    }
    guard let id = args.str("id") else { emitError(CUError.badRequest, "需要 --id（或 --all）") }
    guard loadSession(id) != nil else { emitError(CUError.sessionNotFound, "会话不存在: \(id)") }
    try? FileManager.default.removeItem(at: sessionPath(id))
    let remaining = allSessions().count
    if remaining == 0 { ghostHide() }
    if gJSONMode { emit(["ok": true, "ended": id, "remaining": remaining, "cursorHidden": remaining == 0]) }
    else { emitText("✅ 会话 \(id) 已结束（剩余 \(remaining)）\(remaining == 0 ? "，光标已隐藏" : "")") }
    exit(0)
}

// MARK: - 能力探测（给上层做路由决策）

func cmdCapabilities(_ args: Args) {
    gJSONMode = args.flag("json")
    let p = currentPermissions()
    var caps: [String: Any] = [
        "product": "WorkBuddy Third Hand",
        "component": "native engine (wbcu)",
        "version": VERSION,
        "macOS": ProcessInfo.processInfo.operatingSystemVersionString,
        "permissions": ["accessibility": p.accessibility, "screenRecording": p.screenRecording,
                        "postEvent": p.postEvent, "listenEvent": p.listenEvent],
        "features": [
            "ax_tree": p.accessibility,
            "ax_action": p.accessibility,
            "ax_set_value": p.accessibility,
            "window_capture_oneshot": p.screenRecording,
            "window_capture_stream": p.screenRecording,
            "targeted_click": p.accessibility,
            "targeted_key": p.accessibility,
            "ghost_cursor": true,
            "global_hid_click": p.postEvent
        ],
        "defaults": [
            "click_mode": "auto (AX → targeted)",
            "global_hid_requires_flag": "--allow-global",
            "text_input_preferred": "AXValue",
            "no_disturb": ProcessInfo.processInfo.environment["WBCU_NO_HID_MOUSE"] == "1"
        ],
        "errorCodes": [CUError.permissionDenied, CUError.windowNotFound, CUError.targetGone,
                       CUError.noPressableElement, CUError.unsupportedBackgroundClick,
                       CUError.noObservableChange, CUError.sessionNotFound, CUError.badRequest]
    ]
    caps["ghostDaemon"] = ghostDaemonAlive()
    if gJSONMode { emit(caps) } else {
        emitText("WorkBuddy Third Hand — 引擎 wbcu \(VERSION)  \(ProcessInfo.processInfo.operatingSystemVersionString)")
        emitText("AX=\(p.accessibility ? "✅" : "❌")  屏幕录制=\(p.screenRecording ? "✅" : "❌")  输入注入=\(p.postEvent ? "✅" : "❌")")
        emitText("后台点击=\(p.accessibility ? "可用" : "不可用")  窗口捕获=\(p.screenRecording ? "可用" : "不可用")")
    }
    exit(0)
}
