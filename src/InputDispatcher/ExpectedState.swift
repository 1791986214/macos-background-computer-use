import Foundation
import AppKit
import ApplicationServices

// ============================================================
// ExpectedStateVerifier —— 「UI 变了」不等于「做对了」
//
// v0.4.2 的判据是「AX 指纹有没有变」。这条判据能抓住「没反应」，
// 但抓不住「反应了但反应错了」，也冤枉「本来就该没反应」的幂等操作。
//
// 这里把一次操作拆成五段可审计的事实：
//
//   precondition  →  操作前目标状态是什么
//   target        →  操作指向哪个元素/窗口
//   action        →  用了什么动作（ax / targeted / key）
//   expected_state→  期望变成什么
//   actual_state  →  实际变成了什么
//
// 再按这些事实给出四种结论之一：
//
//   success            确认产生了预期结果
//   already_satisfied  操作前就已经满足期望（幂等，或本来就无需操作）
//   failure            实际结果与期望不一致
//   inconclusive       证据不足（读不到状态 / 没给期望 / 事件路径不可验证）
//
// 置信度是人为定义的口径，不是统计学概率，写在这里便于第三方复核：
//   success(显式期望) .95   already_satisfied .60   failure(显式期望) .95
//   success(仅靠指纹变化) .75   inconclusive .30
//
// 为什么 already_satisfied 只有 .60：我们只能证明「最终状态符合期望」，
// 无法证明「这次点击真的被应用消费了」。要证明消费，需要事件侧证据
// （应用侧事件计数、或 UI 在点击瞬间的中间态），本层拿不到。
// ============================================================

enum VerifyResult: String {
    case success = "success"
    case alreadySatisfied = "already_satisfied"
    case failure = "failure"
    case inconclusive = "inconclusive"

    var ok: Bool { self == .success || self == .alreadySatisfied }
}

struct StateExpectation {
    /// 期望的最终值；nil 表示「没给期望」，只能做弱验证
    var value: String? = nil
    /// equals | contains | not_equals | changed | not_changed
    var match = "equals"
    /// 状态元素定位：`id:Display` / `role:AXStaticText` / `text:结果` / `path:0,1,7`
    var elementHint: String? = nil
    /// 显式声明幂等（幂等操作不把「无变化」当失败）
    var idempotent: Bool? = nil
    /// 等待期望值出现的最长时间（应用常常异步更新）
    var maxWaitMs = 600

    static func parse(match: String?, value: String?, hint: String?) -> StateExpectation {
        var e = StateExpectation()
        e.value = value
        if let m = match, !m.isEmpty { e.match = m.lowercased() }
        e.elementHint = hint
        return e
    }
}

struct ElementReadout {
    var found = false
    var path: [Int] = []
    var role = ""
    var identifier = ""
    var title = ""
    var value = ""
    var elapsedMs = 0

    /// 用于比较的「状态值」：优先 value，其次 title，再其次 desc
    var stateValue: String { value.isEmpty ? title : value }

    var dict: [String: Any] {
        ["found": found, "role": role, "identifier": identifier,
         "value": value, "title": title, "path": path.map { Int($0) }]
    }
}

struct VerifyReport {
    var result: VerifyResult = .inconclusive
    var verificationMethod = "none"
    var confidence = 0.0
    var precondition: ElementReadout? = nil
    var actualState: ElementReadout? = nil
    /// 点击是否被证明消费：proven / unproven / no
    var clickConsumed = "unproven"
    var notes: [String] = []
    var targetDesc = ""
    var actionDesc = ""
    var expectedDesc = ""

    var dict: [String: Any] {
        var d: [String: Any] = [
            "result": result.rawValue,
            "ok": result.ok,
            "verificationMethod": verificationMethod,
            "confidence": (confidence * 100).rounded() / 100,
            "clickConsumed": clickConsumed,
            "target": targetDesc,
            "action": actionDesc,
            "expectedState": expectedDesc,
            "note": notes.joined(separator: "; ")
        ]
        if let p = precondition { d["precondition"] = p.dict }
        if let a = actualState { d["actualState"] = a.dict }
        return d
    }
}

enum ExpectedStateVerifier {

    // MARK: - 定位状态元素

    /// 用 hint 在目标进程的 AX 树里找「状态元素」
    /// hint 形式：id:xxx / role:xxx / text:xxx / path:0,1,7（也给 index 用 idx:7）
    static func locate(pid: pid_t, hint: String?, snapshot: AXSnapshot? = nil) -> (ElementReadout, AXSnapshot) {
        let snap = snapshot ?? walkAX(pid: pid, maxDepth: 16, maxNodes: 2000,
                                      includeActions: false, skipMenuBar: true)
        guard let h = hint, !h.isEmpty else {
            return (ElementReadout(found: false, elapsedMs: snap.elapsedMs), snap)
        }
        let parts = h.split(separator: ":", maxSplits: 1).map(String.init)
        let kind = parts.count == 2 ? parts[0] : ""
        let arg = parts.count == 2 ? parts[1] : h

        var hit: AXItem? = nil
        switch kind {
        case "id":
            hit = snap.items.first { $0.identifier == arg && !$0.role.isEmpty }
        case "role":
            // 同一 role 可能有多个，取「第一个有值的」最稳
            hit = snap.items.first { $0.role == arg && !$0.value.isEmpty }
                ?? snap.items.first { $0.role == arg }
        case "text":
            hit = snap.items.first { $0.title.contains(arg) || $0.value.contains(arg) }
        case "path":
            let nums = arg.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            hit = snap.items.first { $0.path == nums }
        case "idx":
            if let i = Int(arg) { hit = snap.items.first { $0.index == i } }
        default:
            hit = snap.items.first { $0.identifier == h && !$0.role.isEmpty }
                ?? snap.items.first { $0.role == h }
        }
        guard let it = hit else {
            return (ElementReadout(found: false, elapsedMs: snap.elapsedMs), snap)
        }
        let r = ElementReadout(found: true, path: it.path, role: it.role,
                               identifier: it.identifier, title: it.title,
                               value: it.value, elapsedMs: snap.elapsedMs)
        return (r, snap)
    }

    /// 只读一次状态（不建整树，走 path 回查，快）
    static func readPath(pid: pid_t, path: [Int]) -> ElementReadout {
        guard let el = elementAt(pid: pid, path: path) else { return ElementReadout(found: false) }
        return ElementReadout(found: true, path: path,
                              role: axStr(el, kAXRoleAttribute) ?? "",
                              identifier: axStr(el, "AXIdentifier") ?? "",
                              title: axStr(el, kAXTitleAttribute) ?? "",
                              value: axStr(el, kAXValueAttribute) ?? "")
    }

    // MARK: - 判定

    /// 值规范化：真实应用的显示值不是干净的字符串。
    /// 实测（macOS 26.6 计算器）：显示 "7,778" 实际带着 U+200E（LRM，方向标记）和千分位逗号。
    /// 直接逐字符比较会把「正确」判成「failure」—— 而且只在这种格式出现时才复现，很难查。
    ///
    /// 规则：去掉 Unicode 格式类/控制类字符（LRM、ZWSP、BOM 等）+ 去掉千分位逗号 + 去首尾空白。
    /// 代价：用逗号做小数点的地区会被误规范化 —— 本项目目标环境是 zh_CN/en_US，
    /// 两边同时规范化，因此比较仍然对称；需要严格逐字节比较时用 `--match strict`。
    static func normalize(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        for u in s.unicodeScalars {
            switch u.properties.generalCategory {
            case .format, .control: continue        // LRM / ZWSP / BOM 等不可见字符
            default: break
            }
            if u == "," || u == "\u{00A0}" { continue }   // 千分位分隔符 / 不换行空格
            out.append(u)
        }
        return String(out).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func matches(_ actual: String, _ expected: String, mode: String) -> Bool {
        if mode == "strict" {
            return actual.trimmingCharacters(in: .whitespacesAndNewlines)
                == expected.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let a = normalize(actual)
        let e = normalize(expected)
        switch mode {
        case "contains": return a.contains(e)
        case "not_equals": return a != e
        case "changed": return true          // 由调用方另行比较前后
        case "not_changed": return true
        default: return a == e
        }
    }

    /// 核心：给定期望、前置状态、动作结果，给出四分类结论
    static func evaluate(expectation: StateExpectation,
                         pre: ElementReadout,
                         actual: ElementReadout,
                         changed: Bool?,
                         delivered: Bool,
                         failureReason: String,
                         targetDesc: String,
                         actionDesc: String) -> VerifyReport {
        var r = VerifyReport()
        r.precondition = pre
        r.actualState = actual
        r.targetDesc = targetDesc
        r.actionDesc = actionDesc

        // ① 显式期望：这是最强判据
        if let want = expectation.value, !want.isEmpty {
            r.expectedDesc = "\(expectation.match) \"\(want)\""
            guard actual.found else {
                r.result = .inconclusive
                r.verificationMethod = "ax_state_unreadable"
                r.confidence = 0.30
                r.notes.append("读不到状态元素，无法判断结果")
                return r
            }
            let okNow = matches(actual.stateValue, want, mode: expectation.match)
            let okBefore = pre.found && matches(pre.stateValue, want, mode: expectation.match)

            if okNow && okBefore {
                // 前后都满足：可能是幂等操作，也可能是点击没被消费
                r.result = .alreadySatisfied
                r.verificationMethod = "ax_state_pre_equals_expected"
                r.confidence = 0.60
                r.clickConsumed = delivered ? "unproven" : "no"
                r.notes.append("操作前已满足期望（\(pre.stateValue)），不能据此证明点击被消费")
                return r
            }
            if okNow {
                r.result = .success
                r.verificationMethod = "ax_state_matches_expected"
                r.confidence = 0.95
                r.clickConsumed = "proven"
                r.notes.append("状态 \(pre.stateValue.isEmpty ? "?" : pre.stateValue) → \(actual.stateValue)")
                return r
            }
            // 没达到期望
            r.result = .failure
            r.verificationMethod = "ax_state_mismatch"
            r.confidence = 0.95
            r.clickConsumed = changed == true ? "proven" : "unproven"
            r.notes.append("期望 \"\(want)\"，实际 \"\(actual.stateValue)\"")
            if changed == true && actual.stateValue != pre.stateValue {
                r.notes.append("目标被错误点击或产生了意外结果")
            } else if changed != true {
                r.notes.append("状态未变化；投递=\(delivered ? "已投递" : "未投递")"
                               + (failureReason.isEmpty ? "" : "，原因=\(failureReason)"))
            }
            return r
        }

        // ② 没给显式期望：只能弱验证（指纹/整体变化）
        r.expectedDesc = "changed"
        if changed == true {
            r.result = .success
            r.verificationMethod = "ui_changed"
            r.confidence = 0.75
            r.clickConsumed = "proven"
        } else if changed == false {
            // 关键修正：无变化 ≠ 失败。可能是幂等，也可能事件没被消费。
            if let idem = expectation.idempotent, idem {
                r.result = .alreadySatisfied
                r.verificationMethod = "declared_idempotent"
                r.confidence = 0.55
                r.clickConsumed = delivered ? "unproven" : "no"
                r.notes.append("显式声明幂等，且无可见变化")
            } else if expectation.match == "not_changed" {
                r.result = .success
                r.verificationMethod = "expected_no_change"
                r.confidence = 0.70
                r.clickConsumed = "unproven"
            } else {
                r.result = .inconclusive
                r.verificationMethod = "no_observable_change"
                r.confidence = 0.30
                r.clickConsumed = delivered ? "unproven" : "no"
                r.notes.append("UI 无可观测变化；无法区分「幂等」与「事件未被消费」")
                if !failureReason.isEmpty { r.notes.append("投递层原因=\(failureReason)") }
            }
        } else {
            r.result = .inconclusive
            r.verificationMethod = "not_verified"
            r.confidence = 0.20
            r.notes.append("未启用验证或验证路径不可用")
        }
        return r
    }

    /// 等待期望值出现（应用常常异步更新 UI）；超时返回最后一次读数
    static func waitFor(pid: pid_t, path: [Int], expected: String, mode: String,
                        timeoutMs: Int) -> (ElementReadout, Int) {
        let t0 = nowNs()
        var last = readPath(pid: pid, path: path)
        if !last.found { return (last, 0) }
        if matches(last.stateValue, expected, mode: mode) {
            return (last, Int(msSince(t0)))
        }
        while msSince(t0) < Double(timeoutMs) {
            usleep(25_000)
            last = readPath(pid: pid, path: path)
            if matches(last.stateValue, expected, mode: mode) {
                return (last, Int(msSince(t0)))
            }
        }
        return (last, Int(msSince(t0)))
    }
}
