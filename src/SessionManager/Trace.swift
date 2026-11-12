// Trace.swift — 被动激活追踪（Passive Activation Tracing）
//
// 目的只有一个：当用户说「你又抢我前台了」，我们能拿出证据说是谁、在什么时刻、
// 由哪条命令引起，而不是猜。
//
// 设计约束（很重要，否则这个追踪器自己就变成新的干扰源）：
//
//   1. 被动。只读 NSWorkspace.frontmostApplication，不改任何窗口状态，
//      不调用 activate / AXRaise / orderFront —— 它是一个旁观者。
//   2. 非阻塞。追踪器是独立进程，CLI 从不等待它。命令路径上只多一次
//      「pid 文件是否存在」的 stat，约 0.02ms。
//   3. 不申请额外权限。前台应用名与 HID 输入间隔都是无权限可读的。
//   4. 不做归因猜测。前台变化只有在「距上一次真实硬件输入 < 400ms」时才归因给用户，
//      只有在「最近 1.5s 内有 wbcu 命令在跑」时才归因给 Agent，否则记 unknown。
//      拿不准就记 unknown —— 这比给一个漂亮但错误的结论有用。

import Foundation
import AppKit
import CoreGraphics

func traceDir() -> URL { perfDir() }
func traceLogURL() -> URL { traceDir().appendingPathComponent("activation.jsonl") }
func tracePidURL() -> URL { stateDir().appendingPathComponent("trace.pid") }
func traceMarkerURL() -> URL { traceDir().appendingPathComponent("cmd-marker.json") }

private func traceEnsureDir() {
    try? FileManager.default.createDirectory(at: traceDir(), withIntermediateDirectories: true)
}

// MARK: - 运行状态

func tracePid() -> pid_t? {
    guard let s = try? String(contentsOf: tracePidURL(), encoding: .utf8),
          let p = pid_t(s.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
    // kill(pid, 0) 只探测存在性，不发信号
    return kill(p, 0) == 0 ? p : nil
}

func traceRunning() -> Bool { tracePid() != nil }

// MARK: - 命令标记
//
// 每条命令启动时把「我是谁、什么时候开始」写进一个很小的时间戳文件。
// 追踪器读它来做归因。只有追踪器在跑时才写 —— 平时零成本。

private var traceActiveCache: Bool?
private var traceMarkerLive = false

/// 命令结束时间。为什么需要：
/// 只用「开始时间 + 1.5s 窗口」归因会把别人的 activate 算到 wbcu 头上（实测踩过：
/// 脚本自己在下一步调了 `osascript ... activate`，被算成「wbcu 抢前台」）。
/// 记下结束时刻，只有当切换发生在 [t0, t1] 之间才归因给 wbcu。
func traceMarkEnd() {
    guard traceMarkerLive else { return }
    traceMarkerLive = false
    guard let d = try? Data(contentsOf: traceMarkerURL()),
          var o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return }
    o["t1"] = Date().timeIntervalSince1970
    if let out = try? JSONSerialization.data(withJSONObject: o) {
        try? out.write(to: traceMarkerURL())
    }
}

func traceMark(command: String) {
    if traceActiveCache == nil { traceActiveCache = traceRunning() }
    guard traceActiveCache == true else { return }
    let payload: [String: Any] = [
        "cmd": command,
        "t0": Date().timeIntervalSince1970,
        "pid": Int(getpid())
    ]
    if let d = try? JSONSerialization.data(withJSONObject: payload) {
        try? d.write(to: traceMarkerURL())
        traceMarkerLive = true
        // exit() 会触发 atexit，正好用来补结束时刻；重复注册无害（只看标志位）
        atexit { traceMarkEnd() }
    }
}

// MARK: - 采样
//
// 用 NSWorkspace.didActivateApplicationNotification 而不是轮询。
// 原因：轮询版实测会被系统节流（CLI 进程在后台跑，两次采样间隔被拉到 16.8s，
// 期间的前台切换全丢了）。通知是事件驱动的：切换发生就回调，不采样、不丢、不耗 CPU。

struct TraceSample {
    let ts: Double
    var bundleId: String
    var name: String
    var pid: pid_t
    var userInputAgoMs: Double
    var cmd: String
    var cmdAgeMs: Double
    var cmdStart: Double = -1
    var cmdEnd: Double = -1
}

private func readMarker() -> (cmd: String, ageMs: Double, t0: Double, t1: Double)? {
    guard let d = try? Data(contentsOf: traceMarkerURL()),
          let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
          let cmd = o["cmd"] as? String,
          let t0 = o["t0"] as? Double else { return nil }
    let age = (Date().timeIntervalSince1970 - t0) * 1000
    // 超过 30s 的标记视为过期：避免上一个命令的标记污染后续归因
    guard age <= 30_000 else { return nil }
    return (cmd, age, t0, (o["t1"] as? Double) ?? -1)
}

private func currentSample() -> TraceSample {
    let app = NSWorkspace.shared.frontmostApplication
    let m = readMarker()
    let ago = min(
        CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .mouseMoved),
        CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .leftMouseDown),
        CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .keyDown)
    ) * 1000
    return TraceSample(ts: Date().timeIntervalSince1970,
                       bundleId: app?.bundleIdentifier ?? "?",
                       name: app?.localizedName ?? "?",
                       pid: app?.processIdentifier ?? -1,
                       userInputAgoMs: ago,
                       cmd: m?.cmd ?? "",
                       cmdAgeMs: m?.ageMs ?? -1,
                       cmdStart: m?.t0 ?? -1,
                       cmdEnd: m?.t1 ?? -1)
}

// MARK: - daemon

/// 上一次记录的前台 bundleId。闭包里要写，所以放文件级。
private var traceLastBundle = ""

func runTraceDaemon(intervalMs: Int) -> Never {
    traceEnsureDir()
    try? String(getpid()).write(to: tracePidURL(), atomically: true, encoding: .utf8)

    let first = currentSample()
    traceLastBundle = first.bundleId
    appendTraceLine(first, from: "(start)")

    let nc = NSWorkspace.shared.notificationCenter
    nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                   object: nil, queue: nil) { note in
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        else { return }
        let bid = app.bundleIdentifier ?? "?"
        guard bid != traceLastBundle else { return }
        var s = currentSample()
        // 通知里带的就是新前台；以它为准，避免和我们自己读到的竞态
        s.bundleId = bid
        s.name = app.localizedName ?? bid
        s.pid = app.processIdentifier
        appendTraceLine(s, from: traceLastBundle)
        traceLastBundle = bid
    }

    // RunLoop 只服务这一个通知源；不建 NSApplication，因此不参与应用激活。
    RunLoop.current.run()
    exit(0)
}

private func appendTraceLine(_ s: TraceSample, from: String) {
    // 归因规则（阈值都写在这里，报告与测试共用同一套）
    // 三类：user（用户手动）/ wbcu（当前 wbcu 命令）/ external（都不是）。
    // external 的意思是「有人调了 activate，但不是用户的手、也不是 wbcu 这条命令」——
    // 典型是 Agent 跑了 `open -a` 或 `osascript ... activate`。这类最该被看见。
    var attributed = "external"
    if from == "(start)" {
        attributed = "baseline"
    } else if s.userInputAgoMs <= 400 {
        attributed = "user"
    } else if !s.cmd.isEmpty && s.cmdStart > 0 {
        // 只在命令的运行窗口内归因（含 150ms 收尾余量），不再用「开始 + N 秒」的模糊窗
        // 归因窗口 = 该命令真正在跑的那段时间 [t0-50ms, t1]，**不留尾巴**。
        // 留尾巴会把「命令结束后别人调的 activate」算到我们头上 —— 实测踩过一次，
        // 结论写成「引擎抢前台」，其实那条命令早就退出了。
        let lower = s.cmdStart - 0.05
        let upper = s.cmdEnd > 0 ? s.cmdEnd : s.cmdStart + 30
        if s.ts >= lower && s.ts <= upper { attributed = "wbcu" }
    }
    let line: [String: Any] = [
        "ts": s.ts,
        "from": from,
        "to": s.bundleId,
        "toName": s.name,
        "toPid": Int(s.pid),
        "userInputAgoMs": (s.userInputAgoMs * 10).rounded() / 10,
        "cmd": s.cmd,
        "cmdAgeMs": s.cmdAgeMs < 0 ? -1 : (s.cmdAgeMs * 10).rounded() / 10,
        // 命令已结束、但切换紧跟着发生：只做提示，不算归因
        "afterCmdMs": (s.cmdEnd > 0 && s.ts > s.cmdEnd && s.ts - s.cmdEnd <= 0.5)
            ? ((s.ts - s.cmdEnd) * 1000 * 10).rounded() / 10 : -1,
        "attributed": attributed
    ]
    guard let d = try? JSONSerialization.data(withJSONObject: line),
          var text = String(data: d, encoding: .utf8) else { return }
    text += "\n"
    let url = traceLogURL()
    if let h = try? FileHandle(forWritingTo: url) {
        h.seekToEndOfFile()
        h.write(Data(text.utf8))
        try? h.close()
    } else {
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }
}

// MARK: - CLI

func cmdTrace(_ args: Args) {
    gJSONMode = args.flag("json")
    let sub = args.positional.first ?? "report"

    switch sub {
    case "daemon":
        runTraceDaemon(intervalMs: args.int("interval") ?? 100)

    case "start":
        if args.flag("restart"), let p = tracePid() {
            kill(p, SIGTERM)
            try? FileManager.default.removeItem(at: tracePidURL())
            usleep(120_000)
        }
        if let p = tracePid() {
            if gJSONMode { emit(["ok": true, "running": true, "pid": Int(p), "already": true]) }
            else { emitText("✅ 追踪已在运行（pid \(p)）") }
            exit(0)
        }
        traceEnsureDir()
        let interval = args.int("interval") ?? 100
        let exe = CommandLine.arguments[0]
        let path = exe.hasPrefix("/") ? exe : (FileManager.default.currentDirectoryPath + "/" + exe)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = ["trace", "daemon", "--interval", String(interval)]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        for _ in 0..<40 {
            if let pid = tracePid() {
                if gJSONMode {
                    emit(["ok": true, "running": true, "pid": Int(pid), "intervalMs": interval,
                          "log": traceLogURL().path])
                } else {
                    emitText("✅ 追踪已启动（pid \(pid)，采样 \(interval)ms）→ \(traceLogURL().path)")
                }
                exit(0)
            }
            usleep(50_000)
        }
        if gJSONMode { emit(["ok": false, "running": false, "error": "trace_start_failed"]) }
        else { emitText("❌ 追踪启动失败") }
        exit(1)

    case "stop":
        guard let p = tracePid() else {
            if gJSONMode { emit(["ok": true, "running": false]) } else { emitText("· 追踪未运行") }
            exit(0)
        }
        kill(p, SIGTERM)
        try? FileManager.default.removeItem(at: tracePidURL())
        try? FileManager.default.removeItem(at: traceMarkerURL())
        if gJSONMode { emit(["ok": true, "running": false, "stopped": Int(p)]) }
        else { emitText("✅ 追踪已停止（pid \(p)）") }
        exit(0)

    case "status":
        if let p = tracePid() {
            if gJSONMode { emit(["ok": true, "running": true, "pid": Int(p)]) }
            else { emitText("● 追踪中（pid \(p)）") }
        } else {
            if gJSONMode { emit(["ok": true, "running": false]) } else { emitText("· 未追踪") }
        }
        exit(0)

    case "mark":
        // 测试脚手架自己造成的前台变化（例如脚本切换前台模拟用户），
        // 打一个时间戳，报告里标成 harness —— 既不冒充用户，也不算引擎的锅。
        let note = args.str("note") ?? "harness"
        let line = "\(Date().timeIntervalSince1970)\t\(note)\n"
        let url = traceDir().appendingPathComponent("harness.txt")
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
        if gJSONMode { emit(["ok": true, "marked": note]) } else { emitText("· 已标记 harness：\(note)") }
        exit(0)

    case "reset":
        try? FileManager.default.removeItem(at: traceLogURL())
        try? FileManager.default.removeItem(at: traceDir().appendingPathComponent("harness.txt"))
        if gJSONMode { emit(["ok": true]) } else { emitText("✅ 已清空追踪日志") }
        exit(0)

    default:
        traceReport(args)
    }
}

// MARK: - 报告

private func traceReport(_ args: Args) {
    guard let raw = try? String(contentsOf: traceLogURL(), encoding: .utf8), !raw.isEmpty else {
        if gJSONMode { emit(["ok": true, "events": 0, "note": "no trace data"]) }
        else { emitText("· 没有追踪数据（wbcu trace start 后再跑任务）") }
        exit(0)
    }
    var rows: [[String: Any]] = []
    for line in raw.split(separator: "\n") {
        if let d = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] {
            rows.append(d)
        }
    }
    // 只保留最近 N 条（默认 200），够看一次任务的全过程
    let limit = args.int("last") ?? 200
    if rows.count > limit { rows = Array(rows.suffix(limit)) }

    // 脚手架标记：±2.5s 内的切换不算任何一方的责任
    var harness: [(Double, String)] = []
    if let raw = try? String(contentsOf: traceDir().appendingPathComponent("harness.txt"), encoding: .utf8) {
        for line in raw.split(separator: "\n") {
            let f = line.split(separator: "\t")
            if f.count >= 1, let t = Double(f[0]) { harness.append((t, f.count > 1 ? String(f[1]) : "harness")) }
        }
    }
    for i in rows.indices {
        guard let ts = rows[i]["ts"] as? Double else { continue }
        for (t, note) in harness where abs(ts - t) <= 2.5 {
            rows[i]["attributed"] = "harness"
            rows[i]["harnessNote"] = note
            break
        }
    }

    var byAttr: [String: Int] = [:]
    for r in rows {
        let a = (r["attributed"] as? String) ?? "unknown"
        byAttr[a, default: 0] += 1
    }
    // 「起点」那一行不是真的切换
    let changes = rows.filter { ($0["from"] as? String) != "(start)" }

    if gJSONMode {
        emit(["ok": true, "samples": rows.count, "changes": changes.count,
              "attribution": byAttr, "events": changes,
              "rules": ["user": "距上一次真实硬件输入 <= 400ms",
                        "wbcu": "切换发生在该命令的 [t0, t1+150ms] 窗口内",
                        "external": "两者都不满足（典型：Agent 调了 open -a / osascript activate）"]])
        exit(0)
    }

    emitText("前台切换 \(changes.count) 次（样本 \(rows.count) 条）")
    emitText("归因：\(byAttr.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: "  "))")
    if changes.isEmpty {
        emitText("· 没有前台切换 —— 没有任何东西抢过前台")
        exit(0)
    }
    emitText("")
    let fmt = DateFormatter()
    fmt.dateFormat = "HH:mm:ss.SSS"
    for r in changes {
        let ts = (r["ts"] as? Double) ?? 0
        let t = fmt.string(from: Date(timeIntervalSince1970: ts))
        let from = (r["from"] as? String) ?? "?"
        let to = (r["toName"] as? String) ?? (r["to"] as? String) ?? "?"
        let attr = (r["attributed"] as? String) ?? "unknown"
        let mark = attr == "wbcu" ? "⚠️" : (attr == "user" ? "·" : (attr == "harness" ? "◇" : "❗️"))
        var extra = ""
        // 只在真的归因给 wbcu 时才显示 cmd，否则那个名字只会误导
        if attr == "wbcu", let c = r["cmd"] as? String, !c.isEmpty {
            extra += "  cmd=\(c)"
            if let a = r["cmdAgeMs"] as? Double, a >= 0 { extra += "(+\(Int(a))ms)" }
        }
        let ago = (r["userInputAgoMs"] as? Double) ?? -1
        if ago >= 0 && ago < 3000 { extra += "  用户输入 \(Int(ago))ms 前" }
        if let ac = r["afterCmdMs"] as? Double, ac >= 0 {
            extra += "  紧随上一条命令结束后 \(Int(ac))ms"
        }
        if let hn = r["harnessNote"] as? String { extra += "  [harness: \(hn)]" }
        emitText("\(mark) \(t)  \(from) → \(to)  [\(attr)]\(extra)")
    }
    if let n = byAttr["wbcu"], n > 0 {
        emitText("")
        emitText("⚠️  有 \(n) 次前台变化归因于 wbcu —— 这是要修的东西，不是正常现象。")
    }
    if let n = byAttr["external"], n > 0 {
        emitText("")
        emitText("❗️ 有 \(n) 次前台变化既非用户手动、也非 wbcu 命令：常见于 Agent 调了")
        emitText("   `open -a` / `osascript ... activate`。改用 `wbcu launch` 可消除。")
    }
    exit(0)
}
