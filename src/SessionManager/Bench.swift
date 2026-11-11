import Foundation

// MARK: - 基准测试与统计
//
// bench 通过**子进程**调用真实的 `wbcu session click`，因此测到的是端到端耗时
// （含一次进程启动）。同时把引擎内部计时 timing.totalMs 一起报出来，
// 这样「进程启动开销」和「引擎真实工作量」可以分开看，不混为一谈。

private func selfExecutablePath() -> String {
    let a = CommandLine.arguments[0]
    if a.hasPrefix("/") { return a }
    return FileManager.default.currentDirectoryPath + "/" + a
}

/// 跑一条 wbcu 子命令并解析它的 JSON 输出
@discardableResult
private func runChildJSON(_ argv: [String]) -> (json: [String: Any]?, wallMs: Double, stderr: String) {
    let t0 = nowNs()
    let p = Process()
    p.executableURL = URL(fileURLWithPath: selfExecutablePath())
    p.arguments = argv
    let outPipe = Pipe(), errPipe = Pipe()
    p.standardOutput = outPipe
    p.standardError = errPipe
    do { try p.run() } catch { return (nil, msSince(t0), "spawn failed: \(error)") }
    let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    let wall = msSince(t0)
    let outStr = String(data: outData, encoding: .utf8) ?? ""
    let json = outStr.data(using: .utf8).flatMap {
        try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
    }
    return (json, wall, String(data: errData, encoding: .utf8) ?? "")
}

func cmdBench(_ args: Args) {
    gJSONMode = args.flag("json")
    gPretty = args.flag("pretty")
    let app = args.str("app") ?? "com.apple.calculator"
    let iters = max(1, args.int("iters") ?? 5)
    let showGhost = !args.flag("no-ghost")
    let cursorMode = args.str("ghost-mode") ?? "fast"

    guard let runApp = findRunningApp(app) else {
        fail("应用未运行：\(app)（先 open -g -a <app>）")
    }
    enforceGuard(pid: runApp.processIdentifier, action: "bench")

    if args.flag("cold") {
        var db = expLoad()
        db.apps.removeValue(forKey: app)
        expSave(db)
        perfReset()
        if !gJSONMode { print("已清空 \(app) 的经验与性能日志（Cold Start）") }
    }

    // 基线：真实鼠标、前台、以及「距上次用户输入多久」
    // 没有这一项，用户中途动鼠标就会被误判成引擎干扰
    let idleBefore = secondsSinceLastUserInput()
    let benchStart = nowNs()
    let mouseBefore = currentMousePoint()
    let frontBefore = frontmostAppInfo()["bundleId"] as? String ?? ""

    let startRes = runChildJSON(["session", "start", "--app", app, "--json"]
                                + (showGhost ? [] : ["--no-ghost"]))
    guard let sid = (startRes.json?["session"] as? [String: Any])?["id"] as? String else {
        fail("建会话失败：\(startRes.stderr)")
    }
    if !gJSONMode { print("会话 \(sid)  目标 \(app)  \(iters) 轮 × 5 次点击\n") }

    let workflow = ["全部清除", "7", "加", "8", "等于"]
    var engineMs: [Double] = []
    var wallMs: [Double] = []
    var expCounts: [String: Int] = [:]
    var verifyOk = 0, verifyFail = 0, noChange = 0, actions = 0
    var viaCounts: [String: Int] = [:]

    for round in 1...iters {
        for label in workflow {
            actions += 1
            let r = runChildJSON(["session", "click", "--id", sid, "--text", label,
                                  "--exact", "--label", label, "--json",
                                  "--ghost-mode", cursorMode]
                                 + (showGhost ? [] : ["--no-ghost"]))
            wallMs.append(r.wallMs)
            if let j = r.json {
                let t = (j["timing"] as? [String: Any])?["totalMs"] as? Double ?? r.wallMs
                engineMs.append(t)
                let exp = (j["experience"] as? String) ?? "?"
                let key = exp.hasPrefix("hit") ? "hit" : exp
                expCounts[key, default: 0] += 1
                let via = (j["verifyVia"] as? String) ?? "-"
                viaCounts[via, default: 0] += 1
                switch (j["verification"] as? String) ?? "" {
                case "changed": verifyOk += 1
                case "no_observable_change": noChange += 1
                case "not_requested": break
                default: verifyFail += 1
                }
            } else {
                verifyFail += 1
                engineMs.append(r.wallMs)
            }
        }
        let v = runChildJSON(["session", "verify", "--id", sid, "--expect", "15", "--json"])
        let matched = (v.json?["matched"] as? Bool) ?? false
        if !gJSONMode {
            print(String(format: "  第 %d 轮  5 次点击  最终结果 %@  引擎均值 %.0fms",
                         round, matched ? "15 ✅" : "异常 ❌",
                         engineMs.suffix(5).reduce(0, +) / 5))
        }
        // 复位，让下一轮从同一状态开始
        _ = runChildJSON(["session", "click", "--id", sid, "--text", "全部清除",
                          "--exact", "--json", "--no-verify", "--ghost-mode", "fast"]
                         + (showGhost ? [] : ["--no-ghost"]))
    }

    _ = runChildJSON(["session", "end", "--id", sid, "--json"])

    let mouseAfter = currentMousePoint()
    let frontAfter = frontmostAppInfo()["bundleId"] as? String ?? ""
    let elapsedS = msSince(benchStart) / 1000.0
    let idleAfter = secondsSinceLastUserInput()
    // 判据：若全程无人操作，「距上次输入」必然 ≥ 本次耗时；否则说明中途有人动了键鼠
    let userInterfered = idleAfter < elapsedS - 1.0
    let eng = LatencyStats.from(engineMs)
    let wall = LatencyStats.from(wallMs)
    let moved = Int(hypot(mouseAfter.x - mouseBefore.x, mouseAfter.y - mouseBefore.y))
    let hitRate = Double(expCounts["hit"] ?? 0) / Double(max(1, actions)) * 100
    // 「确认无变化」不算失败：例如计算器本来就是 0 时再点「全部清除」。
    // 只把「既没变、也没被应用接受」记为失败。
    let accepted = verifyOk + noChange
    let successRate = Double(accepted) / Double(max(1, actions)) * 100

    if gJSONMode {
        emit(["ok": true, "app": app, "session": sid, "iters": iters, "actions": actions,
              "engine": eng.dict(), "wall": wall.dict(),
              "experience": expCounts, "verifyVia": viaCounts,
              "hitRatePct": (hitRate * 10).rounded() / 10,
              "verifySuccessPct": (successRate * 10).rounded() / 10,
              "changed": verifyOk, "noObservableChange": noChange, "verifyFailed": verifyFail,
              "mouseMoved": moved, "frontChanged": frontBefore != frontAfter,
              "userInterfered": userInterfered,
              "elapsedS": (elapsedS * 10).rounded() / 10])
        exit(0)
    }

    print("\n引擎内部耗时（不含进程启动）")
    print(eng.line("全部动作"))
    print("\n端到端墙钟（含进程启动）")
    print(wall.line("全部动作"))
    print("\n经验命中率      \(String(format: "%.1f", hitRate))%   明细 \(expCounts)")
    print("验证有结论率    \(String(format: "%.1f", successRate))%   (变更 \(verifyOk) + 确认无变化 \(noChange) / 共 \(actions)，失败 \(verifyFail))")
    print("验证通道分布    \(viaCounts)")
    print("真实鼠标位移    \(moved) px（越接近 0 越好）")
    print("前台是否切换    \(frontBefore == frontAfter ? "否" : "是 ⚠️")")
    if userInterfered {
        print("⚠️  本次运行期间检测到真实用户输入（idle \(String(format: "%.1f", idleAfter))s < 耗时 \(String(format: "%.1f", elapsedS))s）")
        print("    鼠标位移/前台切换的归属不明，不能算作引擎干扰；请在看屏幕空闲时重跑")
    } else {
        print("干扰检测        全程无用户输入（idle \(String(format: "%.1f", idleAfter))s ≥ 耗时 \(String(format: "%.1f", elapsedS))s）→ 零干扰结论成立")
    }
    exit(0)
}

// MARK: - perf 统计（从 perf.jsonl 读，可按经验状态分组对比）

func cmdPerf(_ args: Args) {
    gJSONMode = args.flag("json")
    let sub = args.positional.first ?? "stats"

    if sub == "reset" {
        perfReset()
        if gJSONMode { emit(["ok": true, "reset": true]) } else { emitText("✅ 性能日志已清空") }
        exit(0)
    }

    let rows = perfRead(limit: args.int("limit") ?? 2000)
    guard !rows.isEmpty else {
        if gJSONMode { emit(["ok": true, "count": 0, "note": "没有性能记录，先跑 wbcu bench"]) }
        else { emitText("没有性能记录。先跑 `wbcu bench --app <app>`。") }
        exit(0)
    }

    func group(_ pred: ([String: Any]) -> Bool) -> [Double] {
        rows.filter(pred).compactMap { $0["totalMs"] as? Double }
    }
    let all = group { _ in true }
    let cold = group { (($0["experience"] as? String) ?? "").hasPrefix("cold") }
    let miss = group { (($0["experience"] as? String) ?? "").hasPrefix("miss") }
    let hit = group { (($0["experience"] as? String) ?? "").hasPrefix("hit") }

    let sAll = LatencyStats.from(all)
    let sCold = LatencyStats.from(cold)
    let sMiss = LatencyStats.from(miss)
    let sHit = LatencyStats.from(hit)

    // 关键结论：经验命中相比冷启动快多少
    var speedup = 0.0
    if sCold.p50 > 0 && sHit.p50 > 0 { speedup = (1 - sHit.p50 / sCold.p50) * 100 }

    if gJSONMode {
        emit(["ok": true, "count": rows.count,
              "all": sAll.dict(), "cold": sCold.dict(), "miss": sMiss.dict(), "hit": sHit.dict(),
              "p50SpeedupPct": (speedup * 10).rounded() / 10])
        exit(0)
    }
    print("性能记录 \(rows.count) 条\n")
    print(sAll.line("全部"))
    if sCold.n > 0 { print(sCold.line("冷启动 cold")) }
    if sMiss.n > 0 { print(sMiss.line("未命中 miss")) }
    if sHit.n > 0 { print(sHit.line("经验命中 hit")) }
    if speedup != 0 {
        print(String(format: "\nP50 提速：冷启动 %.1f ms → 命中 %.1f ms  =  -%.1f%%",
                     sCold.p50, sHit.p50, speedup))
    }
    exit(0)
}
