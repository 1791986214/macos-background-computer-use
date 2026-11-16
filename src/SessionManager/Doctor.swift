// Doctor.swift — Engine / Skill 版本一致性与安装自检
//
// 为什么需要它：v0.5.0 出过一次真实事故 ——
//   install.sh 默认只装二进制（技能要显式 `--skill`），
//   结果二进制升到 0.5.0，SKILL.md 还停在 0.4.2（177 行），
//   技能里教的 `wbcu launch` / `trace` 根本不存在。
// 这种不一致必须在安装时就被发现，而不是等 Agent 照着技能敲命令报错。
//
// 设计约束：
//   1. 只读，不改任何东西（要修就明说怎么修，不自动改用户环境）
//   2. 不阻塞正常任务：只有显式 `wbcu doctor` 或安装脚本才跑
//   3. 检查项都要能给出「实际值 vs 期望值」，不给模糊结论

import Foundation

/// 编译期已知的子命令。与 main.swift 的 switch 必须保持同步；
/// tests/unit/run.sh 里有一条 lint 会核对两边是否一致。
let KNOWN_COMMANDS: [String] = [
    "perm", "capabilities", "experience", "bench", "perf", "trace", "selftest",
    "session", "guard", "mouse-pos", "idle", "apps", "windows", "ax-tree",
    "ax-find", "ax-act", "ax-set", "ax-hit", "app-state", "shot", "analyze",
    "stream", "click", "ghost", "act", "vis", "occlusion", "displays", "compat",
    "focus", "move", "launch", "drag", "scroll", "key", "type", "activate",
    "window-move", "indicator-scan", "indicator-oneshot", "indicator-exp",
    "version", "doctor"
]

struct DoctorCheck {
    var name: String
    var ok: Bool
    /// pass / warn / fail
    var level: String
    var detail: String
    var fix: String = ""
}

private func skillPath() -> String {
    NSHomeDirectory() + "/.workbuddy/skills/workbuddy-third-hand/SKILL.md"
}

/// 从 SKILL.md 的 frontmatter 里读 `version: x.y.z`
private func skillVersion(_ text: String) -> String? {
    guard text.hasPrefix("---") else { return nil }
    let head = text.split(separator: "---", maxSplits: 2, omittingEmptySubsequences: false)
    guard head.count >= 2 else { return nil }
    for line in head[1].split(separator: "\n") {
        let t = line.trimmingCharacters(in: .whitespaces)
        if t.lowercased().hasPrefix("version:") {
            return t.dropFirst("version:".count).trimmingCharacters(in: .whitespaces)
        }
    }
    return nil
}

/// 从技能正文里提取它引用的 `wbcu <cmd>`，返回不在 KNOWN_COMMANDS 里的那些
private func unknownCommandsReferenced(in text: String) -> [String] {
    var found = Set<String>()
    let pattern = #"wbcu\s+([a-z][a-z0-9-]*)"#
    guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
    let ns = text as NSString
    for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
        if m.numberOfRanges > 1 {
            let c = ns.substring(with: m.range(at: 1))
            if !KNOWN_COMMANDS.contains(c) { found.insert(c) }
        }
    }
    return found.sorted()
}

private func gitInfo() -> (commit: String, tags: [String], dirty: Bool) {
    func sh(_ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        // 仓库路径从二进制位置反推：<repo>/bin/wbcu → <repo>
        let bin = CommandLine.arguments[0]
        let repo = URL(fileURLWithPath: bin).deletingLastPathComponent().deletingLastPathComponent().path
        // 已安装副本（~/.local/bin/wbcu）不在仓库里，这时不该报错，直接跳过
        guard FileManager.default.fileExists(atPath: repo + "/.git") else { return "" }
        p.currentDirectoryURL = URL(fileURLWithPath: repo)
        try? p.run()
        let d = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: d, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
    let commit0 = sh(["rev-parse", "--short", "HEAD"])
    if commit0.isEmpty { return ("", [], false) }   // 不在 git 仓库内
    let commit = commit0
    let tagRaw = sh(["tag", "--points-at", "HEAD"]).split(separator: "\n").map(String.init)
    let status = sh(["status", "--porcelain"])
    return (commit.isEmpty ? "?" : commit, tagRaw, !status.isEmpty)
}

func cmdDoctor(_ args: Args) {
    gJSONMode = args.flag("json")
    var checks: [DoctorCheck] = []

    // ① 二进制版本
    checks.append(DoctorCheck(name: "engine_version", ok: true, level: "pass",
                              detail: VERSION))

    // ② 技能文件是否存在
    let sp = skillPath()
    let exists = FileManager.default.fileExists(atPath: sp)
    checks.append(DoctorCheck(name: "skill_file", ok: exists,
                              level: exists ? "pass" : "fail",
                              detail: exists ? sp : "缺失: \(sp)",
                              fix: exists ? "" : "bash scripts/install.sh --skill"))

    var sv = "?"
    if exists, let text = try? String(contentsOfFile: sp, encoding: .utf8) {
        // ③ 技能声明版本 vs 引擎版本
        sv = skillVersion(text) ?? "未声明"
        let match = sv == VERSION
        checks.append(DoctorCheck(name: "version_match", ok: match,
                                  level: match ? "pass" : "fail",
                                  detail: "engine=\(VERSION) skill=\(sv)",
                                  fix: match ? "" : "bash scripts/install.sh --skill"))

        // ④ 技能引用的命令是否都存在
        let unknown = unknownCommandsReferenced(in: text)
        checks.append(DoctorCheck(name: "skill_commands", ok: unknown.isEmpty,
                                  level: unknown.isEmpty ? "pass" : "fail",
                                  detail: unknown.isEmpty ? "技能引用的命令全部存在"
                                        : "技能引用了不存在的命令: \(unknown.joined(separator: ", "))",
                                  fix: unknown.isEmpty ? "" : "升级技能或引擎，使两边对齐"))
        // ⑤ 技能里是否还残留「没有浏览器接口」这类过期结论
        let stale = text.contains("本构建没有该接口") || text.contains("本构建未向 Agent 暴露")
        if stale {
            checks.append(DoctorCheck(name: "skill_stale_claims", ok: false, level: "warn",
                                      detail: "技能里仍有「本构建没有浏览器接口」一类过期结论",
                                      fix: "更新技能（v0.5.1 起 agent-browser 可用）"))
        }
    }

    // ⑥ 已安装路径
    let installed = NSHomeDirectory() + "/.local/bin/wbcu"
    let instOK = FileManager.default.isExecutableFile(atPath: installed)
    checks.append(DoctorCheck(name: "installed_binary", ok: instOK,
                              level: instOK ? "pass" : "warn",
                              detail: instOK ? installed : "未安装到 \(installed)",
                              fix: instOK ? "" : "bash scripts/install.sh --skill"))

    // ⑦ 覆盖层
    let overlay = NSHomeDirectory() + "/.local/share/wbcu/ThirdHandOverlay.app"
    let ovOK = FileManager.default.fileExists(atPath: overlay)
    checks.append(DoctorCheck(name: "overlay", ok: ovOK, level: ovOK ? "pass" : "warn",
                              detail: overlay, fix: ovOK ? "" : "bash scripts/install.sh"))

    // ⑧ 核心命令冒烟（只跑无副作用、无 GUI 依赖的）
    var smoke: [String] = []
    for c in ["version", "trace", "session", "doctor"] {
        smoke.append(KNOWN_COMMANDS.contains(c) ? "\(c):ok" : "\(c):missing")
    }
    let smokeOK = !smoke.contains { $0.hasSuffix(":missing") }
    checks.append(DoctorCheck(name: "smoke", ok: smokeOK, level: smokeOK ? "pass" : "fail",
                              detail: smoke.joined(separator: " ")))

    // ⑨ Git 状态（只在从仓库里跑时有意义；已安装副本不在仓库内 → 跳过，不算问题）
    let g = gitInfo()
    if g.commit.isEmpty {
        checks.append(DoctorCheck(name: "git", ok: true, level: "pass",
                                  detail: "已安装副本，不在 git 仓库内（跳过版本锚点检查）"))
    } else {
        checks.append(DoctorCheck(name: "git", ok: !g.dirty,
                                  level: g.dirty ? "warn" : "pass",
                                  detail: "commit=\(g.commit) tags=[\(g.tags.joined(separator: ","))]"
                                        + (g.dirty ? " 工作区有未提交改动" : " 工作区干净"),
                                  fix: g.dirty ? "提交后再发布" : ""))
    }

    // ⑩ 技能文件行数（快速判断是不是老版本）
    if exists, let text = try? String(contentsOfFile: sp, encoding: .utf8) {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).count
        checks.append(DoctorCheck(name: "skill_lines", ok: lines >= 200,
                                  level: lines >= 200 ? "pass" : "warn",
                                  detail: "\(lines) 行",
                                  fix: lines >= 200 ? "" : "疑似旧版技能，重装 --skill"))
    }

    // ⑪ 旧会话堆积（不影响正确性，但会让 session list 变脏）
    let sessDir = stateDir().appendingPathComponent("sessions")
    let files = (try? FileManager.default.contentsOfDirectory(atPath: sessDir.path)) ?? []
    let dead = files.filter { $0.hasSuffix(".json") }.count
    if dead > 10 {
        checks.append(DoctorCheck(name: "session_gc", ok: false, level: "warn",
                                  detail: "\(dead) 个会话文件（多数已失效）",
                                  fix: "wbcu session prune"))
    } else {
        checks.append(DoctorCheck(name: "session_gc", ok: true, level: "pass",
                                  detail: "\(dead) 个会话文件"))
    }

    let fails = checks.filter { $0.level == "fail" }
    let warns = checks.filter { $0.level == "warn" }
    let verdict = fails.isEmpty ? (warns.isEmpty ? "healthy" : "degraded") : "broken"

    if gJSONMode {
        emit(["ok": fails.isEmpty, "verdict": verdict,
              "engine": VERSION, "skill": sv,
              "checks": checks.map { ["name": $0.name, "level": $0.level,
                                      "ok": $0.ok, "detail": $0.detail, "fix": $0.fix] },
              "failCount": fails.count, "warnCount": warns.count])
        exit(fails.isEmpty ? 0 : 1)
    }

    emitText("Third Hand 安装自检  engine=\(VERSION)  skill=\(sv)")
    emitText("")
    for c in checks {
        let mark = c.level == "pass" ? "✅" : (c.level == "warn" ? "⚠️ " : "❌")
        emitText("\(mark) \(c.name.padding(toLength: 20, withPad: " ", startingAt: 0)) \(c.detail)")
        if !c.fix.isEmpty { emitText("   → \(c.fix)") }
    }
    emitText("")
    emitText(verdict == "healthy" ? "结论：一致，可直接用"
             : (verdict == "degraded" ? "结论：可用，但有 \(warns.count) 项建议处理"
                : "结论：\(fails.count) 项不一致，先修再用"))
    exit(fails.isEmpty ? 0 : 1)
}
