import Foundation
import AppKit
import CoreGraphics
import CoreMedia
import ScreenCaptureKit

// MARK: - 窗口共享指示器探针
//
// 系统在「某个窗口被别的进程持续捕获」时，会在该窗口左上角（红黄绿位置）绘制
// 紫/靛蓝胶囊。它由 WindowServer 合成，不属于目标 App 的视图层。
// 本模块只做观察，不绘制任何伪造 UI。

let shareKeywords = ["shar", "共享", "共亯", "sharing", "screenshare"]

func looksLikeShareElement(_ el: AXUIElement) -> (Bool, [String: String]) {
    var info: [String: String] = [:]
    for attr in [kAXRoleAttribute as String, kAXSubroleAttribute as String,
                 kAXTitleAttribute as String, kAXDescriptionAttribute as String,
                 "AXRoleDescription", "AXIdentifier", kAXHelpAttribute as String] {
        if let v = axStr(el, attr) { info[attr] = v }
    }
    let role = (info["AXRole"] ?? "")
    // 菜单项里的「共享」是普通菜单命令，不是指示器
    if role == "AXMenuItem" || role == "AXMenuBarItem" { return (false, info) }
    let title = (info["AXTitle"] ?? "") + " " + (info["AXIdentifier"] ?? "")
    let lower = title.lowercased()
    // 精确判据：标题含 windowsharingsessionbutton / sharing 系列标识，或非菜单元素的「共享」控件
    let strong = lower.contains("windowsharingsessionbutton")
        || lower.contains("sharingsession")
        || lower.contains("screen sharing")
        || lower.contains("正在共享")
        || lower.contains("共享中")
    let weak = (role == "AXButton" || role.contains("Dialog")) && title.contains("共享")
    return (strong || weak, info)
}

/// 目标 App 的顶层 AXWindow 清单 —— 用于验证「指示器是否被暴露为独立 AXDialog」
func describeAXWindows(pid: pid_t) -> [[String: Any]] {
    windowsOf(pid).map { w -> [String: Any] in
        var d: [String: Any] = [
            "role": axStr(w, kAXRoleAttribute) ?? "",
            "subrole": axStr(w, kAXSubroleAttribute) ?? "",
            "title": axStr(w, kAXTitleAttribute) ?? "",
            "roleDescription": axStr(w, "AXRoleDescription") ?? "",
            "children": axChildren(w).count
        ]
        if let p = axPoint(w, kAXPositionAttribute) { d["x"] = p.x; d["y"] = p.y }
        if let s = axSize(w, kAXSizeAttribute) { d["w"] = s.width; d["h"] = s.height }
        if let wid = cgWindowId(of: w) { d["cgWindowId"] = Int(wid) }
        // 该窗口是否包含 WindowSharingSessionButton
        var found = false
        func scan(_ el: AXUIElement, _ depth: Int) {
            if found || depth > 6 { return }
            if (axStr(el, kAXTitleAttribute) ?? "").contains("WindowSharingSessionButton") { found = true; return }
            for k in axChildren(el) { scan(k, depth + 1) }
        }
        scan(w, 0)
        d["containsSharingButton"] = found
        return d
    }
}

/// 扫描目标 App 的 AX 树，找共享指示器相关的节点（含独立 AXDialog 形态）
func scanAXForSharing(pid: pid_t) -> [[String: Any]] {
    var hits: [[String: Any]] = []
    let root = appElement(pid)
    var visited = 0
    func visit(_ el: AXUIElement, depth: Int) {
        if visited > 3000 || depth > 14 { return }
        visited += 1
        let (hit, info) = looksLikeShareElement(el)
        if hit {
            var d: [String: Any] = ["depth": depth]
            for (k, v) in info { d[k] = v }
            if let p = axPoint(el, kAXPositionAttribute) { d["x"] = p.x; d["y"] = p.y }
            if let s = axSize(el, kAXSizeAttribute) { d["w"] = s.width; d["h"] = s.height }
            d["actions"] = axActions(el)
            hits.append(d)
        }
        for k in axChildren(el) { visit(k, depth: depth + 1) }
    }
    visit(root, depth: 0)
    return hits
}

/// 目标窗口附近的系统合成小窗（指示器在 CGWindowList 里可能表现为一个独立窗口）
func nearbySystemWindows(targetWindowId: CGWindowID, targetBounds: CGRect) -> [[String: Any]] {
    let wins = listCGWindows(onScreenOnly: true)
    let zone = CGRect(x: targetBounds.minX - 8, y: targetBounds.minY - 8,
                      width: min(targetBounds.width, 260) + 16, height: 64)
    var out: [[String: Any]] = []
    for w in wins where w.id != targetWindowId {
        let inZone = w.bounds.intersects(zone) && w.bounds.width < 400 && w.bounds.height < 120
        let systemish = w.layer > 0 || w.owner.contains("Window Server") || w.owner.contains("WindowServer")
        if inZone && systemish {
            out.append(["windowId": Int(w.id), "owner": w.owner, "name": w.name,
                        "layer": w.layer, "alpha": w.alpha,
                        "x": w.bounds.minX, "y": w.bounds.minY,
                        "w": w.bounds.width, "h": w.bounds.height])
        }
    }
    return out
}

/// 对窗口左上角区域采样，判断紫胶囊是否存在
func sampleIndicator(windowBounds: CGRect, keepAs: String? = nil) -> PixelStats? {
    // 指示器占据标题栏左端：取左上角 200x46
    let rect = CGRect(x: windowBounds.minX + 2, y: windowBounds.minY + 1,
                      width: min(200, windowBounds.width - 4), height: min(46, windowBounds.height - 2))
    let url = tmpDir().appendingPathComponent("indicator-sample-\(Int(Date().timeIntervalSince1970 * 1000)).png")
    guard captureRegion(rect, to: url) else { return nil }
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
    let s = analyzePurple(img)
    if let keep = keepAs {
        try? FileManager.default.removeItem(atPath: keep)
        try? FileManager.default.copyItem(at: url, to: URL(fileURLWithPath: keep))
    }
    try? FileManager.default.removeItem(at: url)
    return s
}

// MARK: - 命令：indicator-oneshot（截图 vs 持续捕获 的对照）
func cmdIndicatorOnce(_ args: Args) {
    gJSONMode = args.flag("json")
    gPretty = args.flag("pretty")
    let pid = resolvePid(args)
    let appName = findRunningApp("\(pid)")?.localizedName ?? ""
    guard let wid = args.int("window").map({ CGWindowID($0) }) ?? mainWindowId(for: pid) else { fail("找不到目标窗口") }
    let wins = windowsFor(pid: pid, onScreenOnly: true, includeSystemChrome: true)
    guard let target = wins.first(where: { $0.id == wid }) else { fail("窗口不可见") }

    var report: [String: Any] = ["ok": true, "app": appName, "windowId": Int(wid), "mode": "oneshot"]

    let p0 = sampleIndicator(windowBounds: target.bounds, keepAs: args.str("keep-prefix").map { "\($0)-before.png" })
    report["before"] = ["purple": p0?.purpleCount ?? -1,
                        "axShares": scanAXForSharing(pid: pid).count,
                        "axWindowCount": windowsOf(pid).count]

    // 单帧截图（SCScreenshotManager）
    let t0 = Date()
    let out = tmpDir().appendingPathComponent("oneshot.png")
    let ok = captureWindowOnce(windowId: wid, maxWidth: nil, to: out)
    let shotMs = Int(Date().timeIntervalSince(t0) * 1000)

    var samples: [[String: Any]] = []
    for (i, delay) in [0.15, 0.5, 1.2, 2.0].enumerated() {
        Thread.sleep(forTimeInterval: delay)
        let p = sampleIndicator(windowBounds: target.bounds,
                                keepAs: i == 0 ? args.str("keep-prefix").map { "\($0)-after.png" } : nil)
        let ax = scanAXForSharing(pid: pid).count
        samples.append(["t": delay, "purple": p?.purpleCount ?? -1, "axShares": ax])
    }
    report["shotOk"] = ok
    report["shotMs"] = shotMs
    report["samples"] = samples
    report["verdict"] = (samples.allSatisfy { ($0["purple"] as? Int ?? 0) < 40 })
        ? "单帧截图未触发窗口共享指示器"
        : "单帧截图也触发了指示器（短时）"

    if gJSONMode { emit(report) } else {
        emitText("单帧截图: ok=\(ok) \(shotMs)ms  基线紫色=\(p0?.purpleCount ?? -1)")
        for s in samples { emitText("  t=\(s["t"]!)s purple=\(s["purple"]!) axShares=\(s["axShares"]!)") }
        emitText("判定: \(report["verdict"]!)")
    }
    exit(0)
}

// MARK: - 命令：indicator scan（一次性观察）
func cmdIndicatorScan(_ args: Args) {
    gJSONMode = args.flag("json")
    gPretty = args.flag("pretty")
    let pid = resolvePid(args)
    let appName = findRunningApp("\(pid)")?.localizedName ?? ""
    guard let wid = args.int("window").map({ CGWindowID($0) }) ?? mainWindowId(for: pid) else { fail("找不到目标窗口") }
    let wins = windowsFor(pid: pid, onScreenOnly: true, includeSystemChrome: true)
    guard let target = wins.first(where: { $0.id == wid }) else { fail("窗口 \(wid) 不在当前可见列表") }

    let axHits = scanAXForSharing(pid: pid)
    let sysWins = nearbySystemWindows(targetWindowId: wid, targetBounds: target.bounds)
    let pixels = sampleIndicator(windowBounds: target.bounds)

    let out: [String: Any] = [
        "ok": true,
        "pid": Int(pid), "app": appName, "windowId": Int(wid),
        "windowBounds": ["x": target.bounds.minX, "y": target.bounds.minY,
                         "w": target.bounds.width, "h": target.bounds.height],
        "axSharingElements": axHits,
        "nearbySystemWindows": sysWins,
        "titlebarPurplePixels": pixels?.purpleCount ?? -1,
        "titlebarDominantRGB": pixels.map { [$0.dominant.r, $0.dominant.g, $0.dominant.b] } ?? [],
        "titlebarPurpleBBox": pixels?.bbox.map { ["x": $0.minX, "y": $0.minY, "w": $0.width, "h": $0.height] } ?? [:],
        "verdict": {
            let hasAX = !axHits.isEmpty
            let hasPx = (pixels?.purpleCount ?? 0) > 40
            if hasPx && hasAX { return "指示器存在（像素 + AX 双证据）" }
            if hasPx { return "指示器存在（像素证据）" }
            if hasAX { return "AX 树含共享相关元素，但标题栏未见紫色" }
            return "未见窗口共享指示器"
        }()
    ]
    if gJSONMode { emit(out) } else {
        emitText("""
        应用: \(appName) (pid \(pid))  窗口: \(wid)
        窗口位置: \(Int(target.bounds.minX)),\(Int(target.bounds.minY))  \(Int(target.bounds.width))x\(Int(target.bounds.height))
        AX 共享相关元素: \(axHits.count) 个
        \(axHits.map { "  - \($0["AXSubrole"] ?? $0["AXRole"] ?? "?") \"\($0["AXTitle"] ?? "")\" \($0["AXIdentifier"] ?? "")" }.joined(separator: "\n"))
        邻近系统合成窗口: \(sysWins.count) 个
        \(sysWins.map { "  - win\($0["windowId"]!) owner=\($0["owner"]!) layer=\($0["layer"]!) \($0["w"]!)x\($0["h"]!)" }.joined(separator: "\n"))
        标题栏紫色像素: \(pixels?.purpleCount ?? -1)  主色: \(pixels.map { "\($0.dominant.r),\($0.dominant.g),\($0.dominant.b)" } ?? "-")
        判定: \(out["verdict"]!)
        """)
    }
    exit(0)
}

// MARK: - 命令：indicator experiment（开/关捕获的完整生命周期实验）
func cmdIndicatorExperiment(_ args: Args) {
    gJSONMode = args.flag("json")
    gPretty = args.flag("pretty")
    let pid = resolvePid(args)
    let appName = findRunningApp("\(pid)")?.localizedName ?? ""
    guard let wid = args.int("window").map({ CGWindowID($0) }) ?? mainWindowId(for: pid) else { fail("找不到目标窗口") }
    let wins = windowsFor(pid: pid, onScreenOnly: true, includeSystemChrome: true)
    guard let target = wins.first(where: { $0.id == wid }) else { fail("窗口 \(wid) 不在可见窗口列表") }
    enforceGuard(pid: pid, action: "indicator-exp(stream)")
    let hold = args.dbl("seconds") ?? 4.0
    let stageDelay = args.dbl("delay") ?? 1.2

    var report: [String: Any] = ["ok": true, "app": appName, "pid": Int(pid), "windowId": Int(wid),
                                 "bounds": ["x": target.bounds.minX, "y": target.bounds.minY,
                                            "w": target.bounds.width, "h": target.bounds.height]]

    // ---- 阶段 0：基线 ----
    let keep = args.str("keep-prefix")
    let p0 = sampleIndicator(windowBounds: target.bounds, keepAs: keep.map { "\($0)-before.png" })
    let ax0 = scanAXForSharing(pid: pid).count
    let sys0 = nearbySystemWindows(targetWindowId: wid, targetBounds: target.bounds).count
    let axWins0 = windowsOf(pid).count
    report["baseline"] = ["purple": p0?.purpleCount ?? -1, "axShares": ax0, "nearbySysWins": sys0,
                          "axWindowCount": axWins0, "axWindows": describeAXWindows(pid: pid)]

    // ---- 阶段 1：启动 SCStream 窗口级捕获 ----
    let box = StreamBox()
    let sem = DispatchSemaphore(value: 0)
    var started = false
    var startErr: String? = nil
    var stream: SCStream? = nil
    var captureInfo: [String: Any] = [:]

    Task.detached {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard let win = content.windows.first(where: { $0.windowID == wid }) else {
                startErr = "窗口不可共享（可能已关闭或受保护）"; sem.signal(); return
            }
            let filter = SCContentFilter(desktopIndependentWindow: win)
            let cfg = SCStreamConfiguration()
            let scale = CGFloat(filter.pointPixelScale)
            cfg.width = max(Int(win.frame.width * scale), 2)
            cfg.height = max(Int(win.frame.height * scale), 2)
            cfg.minimumFrameInterval = CMTime(value: 1, timescale: 15)
            cfg.showsCursor = false
            cfg.capturesAudio = false
            captureInfo = ["w": cfg.width, "h": cfg.height, "scale": Double(scale)]
            let s = SCStream(filter: filter, configuration: cfg, delegate: box)
            try s.addStreamOutput(box, type: .screen, sampleHandlerQueue: DispatchQueue(label: "wbcu.exp"))
            try await s.startCapture()
            stream = s
            started = true
            sem.signal()
        } catch {
            startErr = "\(error)"; sem.signal()
        }
    }
    _ = sem.wait(timeout: .now() + 20)
    report["captureStarted"] = started
    report["captureInfo"] = captureInfo
    if let e = startErr { report["captureError"] = e }

    if started {
        // 等系统绘制指示器
        Thread.sleep(forTimeInterval: stageDelay)

        // ---- 阶段 2：捕获中观察 ----
        let p1 = sampleIndicator(windowBounds: target.bounds, keepAs: keep.map { "\($0)-during.png" })
        let axHits = scanAXForSharing(pid: pid)
        let sys1 = nearbySystemWindows(targetWindowId: wid, targetBounds: target.bounds)
        let axWins1 = windowsOf(pid).count
        // 抓一帧看指示器是否会出现在「被捕获的画面」里
        let frameURL = tmpDir().appendingPathComponent("exp-frame.png")
        _ = captureWindowOnce(windowId: wid, maxWidth: 900, to: frameURL)
        var framePurple = -1
        if let src = CGImageSourceCreateWithURL(frameURL as CFURL, nil),
           let img = CGImageSourceCreateImageAtIndex(src, 0, nil) {
            framePurple = analyzePurple(img)?.purpleCount ?? -1
        }
        if let keep = keep {
            let dst = "\(keep)-captured.png"
            try? FileManager.default.removeItem(atPath: dst)
            try? FileManager.default.copyItem(at: frameURL, to: URL(fileURLWithPath: dst))
        }
        report["duringCapture"] = [
            "purple": p1?.purpleCount ?? -1,
            "purpleRGB": p1.map { [$0.dominant.r, $0.dominant.g, $0.dominant.b] } ?? [],
            "purpleBBox": p1?.bbox.map { ["x": $0.minX, "y": $0.minY, "w": $0.width, "h": $0.height] } ?? [:],
            "axShares": axHits.count,
            "axShareDetail": axHits,
            "nearbySysWins": sys1,
            "axWindowCount": axWins1,
            "axWindows": describeAXWindows(pid: pid),
            "framesInCapturedImage": box.frameCount,
            "purpleInCapturedFrame": framePurple
        ]

        // 持续 N 秒
        let until = Date().addingTimeInterval(max(0, hold - stageDelay))
        while Date() < until {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
        }

        // ---- 阶段 3：停止捕获 ----
        let stopSem = DispatchSemaphore(value: 0)
        Task.detached {
            try? await stream?.stopCapture()
            stopSem.signal()
        }
        _ = stopSem.wait(timeout: .now() + 10)
        Thread.sleep(forTimeInterval: stageDelay)

        let p2 = sampleIndicator(windowBounds: target.bounds, keepAs: keep.map { "\($0)-after.png" })
        let ax2 = scanAXForSharing(pid: pid).count
        let sys2 = nearbySystemWindows(targetWindowId: wid, targetBounds: target.bounds).count
        let axWins2 = windowsOf(pid).count
        report["afterStop"] = ["purple": p2?.purpleCount ?? -1, "axShares": ax2,
                               "nearbySysWins": sys2, "axWindowCount": axWins2,
                               "axWindows": describeAXWindows(pid: pid),
                               "totalFrames": box.frameCount]
    }

    if gJSONMode {
        emit(report)
    } else {
        emitText("""
        === 窗口共享指示器生命周期实验 ===
        应用: \(appName) (pid \(pid))  窗口: \(wid)
        基线      : 紫色像素=\((report["baseline"] as? [String: Any])?["purple"] ?? "?")  AX共享节点=\((report["baseline"] as? [String: Any])?["axShares"] ?? "?")
        捕获已启动: \(started)  \((captureInfo["w"] ?? 0))x\((captureInfo["h"] ?? 0))px
        捕获中    : \(report["duringCapture"] ?? "无")
        停止后    : \(report["afterStop"] ?? "无")
        """)
    }
    exit(started ? 0 : 1)
}
