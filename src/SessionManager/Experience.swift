import Foundation
import AppKit
import ApplicationServices

// MARK: - ThirdHandAppExperienceMemory
//
// 目标：同一个应用第二次操作时，不必再整棵树扫一遍找元素。
//
// 做法：第一次成功操作后，把「目标元素的 AX 路径 + 身份特征」存下来；
// 下次先按路径 O(depth) 回查（通常 5~6 跳），再用 identifier/role/label 校验。
// 校验不过就当作没命中，退回完整遍历 —— 宁慢勿错。
//
// 隐私红线：
//   * 不存窗口标题、不存截图、不存任何文本内容
//   * label 只存 UI 控件自身标签（"7"、"全部清除"），不涉及用户文档内容
//   * 库文件在 ~/.wbcu/ 本地，不上传、不进仓库

let EXPERIENCE_SCHEMA_VERSION = 1

// MARK: 数据结构

struct ExpEntry: Codable {
    var key: String
    var intent: String              // "click"
    var label: String
    var role: String
    var identifier: String
    var path: [Int]                 // AX 路径（与 walkAX 的 childrenForWalk 顺序一致）
    var relRect: [Double]           // 相对窗口的归一化矩形 [x,y,w,h]
    var windowSize: [Double]
    var actionMode: String          // "ax" | "targeted"
    var validation: String          // "axvalue" | "fingerprint"
    var observePath: [Int]?         // 验证时监听哪个元素的值变化
    /// 观测超时次数。可选类型以兼容旧经验文件（缺失时按 0 处理）。
    /// 单次超时可能只是「这次操作本来就没变化」，连续超时才是「盯错了元素」。
    var observeFail: Int?
    var successCount: Int
    var failureCount: Int
    var recentLatencyMs: [Int]
    var lastVerifiedAt: Double
    var status: String              // candidate | verified | stable

    var confidence: Double {
        let total = successCount + failureCount
        guard total > 0 else { return 0 }
        let base = Double(successCount) / Double(total)
        let sample = min(1.0, Double(successCount) / 6.0)   // 样本量修正
        return (base * 0.7 + sample * 0.3 * base)
    }

    var medianLatencyMs: Int {
        guard !recentLatencyMs.isEmpty else { return 0 }
        let s = recentLatencyMs.sorted()
        return s[s.count / 2]
    }
}

struct ExpApp: Codable {
    var bundleId: String
    var appVersion: String
    var lastUpdated: Double
    var entries: [String: ExpEntry]
}

struct ExpDB: Codable {
    var schemaVersion: Int
    var apps: [String: ExpApp]
}

// MARK: 存储

func expPath() -> URL { stateDir().appendingPathComponent("experience.json") }

func expLoad() -> ExpDB {
    guard let d = try? Data(contentsOf: expPath()),
          let db = try? JSONDecoder().decode(ExpDB.self, from: d) else {
        return ExpDB(schemaVersion: EXPERIENCE_SCHEMA_VERSION, apps: [:])
    }
    // 版本迁移：旧 schema 不兼容时先备份再重建，绝不静默丢数据
    if db.schemaVersion != EXPERIENCE_SCHEMA_VERSION {
        let bak = expPath().appendingPathExtension("v\(db.schemaVersion).bak")
        try? FileManager.default.copyItem(at: expPath(), to: bak)
        return ExpDB(schemaVersion: EXPERIENCE_SCHEMA_VERSION, apps: [:])
    }
    return db
}

func expSave(_ db: ExpDB) {
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    if let d = try? enc.encode(db) { try? d.write(to: expPath()) }
}

func expKey(intent: String, label: String, role: String, identifier: String) -> String {
    // identifier 优先：它是开发者显式给出的稳定锚点，比展示文本可靠
    let anchor = identifier.isEmpty ? label : identifier
    return "\(intent)|\(anchor)|\(role)"
}

func appVersion(_ pid: pid_t) -> String {
    guard let app = NSRunningApplication(processIdentifier: pid),
          let url = app.bundleURL,
          let bundle = Bundle(url: url) else { return "" }
    let v = bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    let b = bundle.infoDictionary?["CFBundleVersion"] as? String ?? ""
    return v.isEmpty ? b : "\(v)(\(b))"
}

// MARK: 匹配与校验

struct ExpHit {
    var entry: ExpEntry
    var element: AXUIElement
    var resolveMs: Double
}

/// 按路径回查并用身份特征校验。校验不过返回 nil（视为未命中）。
func expResolve(_ entry: ExpEntry, pid: pid_t) -> AXUIElement? {
    guard !entry.path.isEmpty, let el = elementAt(pid: pid, path: entry.path) else { return nil }
    let role = axStr(el, kAXRoleAttribute) ?? ""
    guard role == entry.role else { return nil }              // 角色变了 → 布局已变
    if !entry.identifier.isEmpty {
        let id = axStr(el, "AXIdentifier") ?? ""
        guard id == entry.identifier else { return nil }
    } else if !entry.label.isEmpty {
        let title = axStr(el, kAXTitleAttribute) ?? ""
        let desc = axStr(el, kAXDescriptionAttribute) ?? ""
        let val = axStr(el, kAXValueAttribute) ?? ""
        guard [title, desc, val].contains(where: { $0 == entry.label }) else { return nil }
    }
    // 尺寸合理性：0 尺寸通常意味着元素已折叠/隐藏
    if let s = axSize(el, kAXSizeAttribute), s.width < 1 || s.height < 1 { return nil }
    return el
}

/// 带校验的查找：调用方已知道 pid，避免重复解析应用
func expLookup(app: String, pid: pid_t, intent: String, label: String,
               role: String = "") -> ExpHit? {
    let db = expLoad()
    guard let a = db.apps[app] else { return nil }
    let t0 = nowNs()
    var candidates: [ExpEntry] = []
    if !role.isEmpty {
        let k = expKey(intent: intent, label: label, role: role, identifier: "")
        if let e = a.entries[k] { candidates.append(e) }
    }
    for e in a.entries.values where e.intent == intent
        && (e.label == label || e.identifier == label)
        && !candidates.contains(where: { $0.key == e.key }) {
        candidates.append(e)
    }
    for e in candidates.sorted(by: { $0.confidence > $1.confidence }) {
        if let el = expResolve(e, pid: pid) {
            return ExpHit(entry: e, element: el, resolveMs: msSince(t0))
        }
    }
    return nil
}

func expPidFor(app: String) -> pid_t? {
    findRunningApp(app)?.processIdentifier
}

// MARK: 学习

func expLearn(app: String, pid: pid_t,
              intent: String, label: String, role: String, identifier: String,
              path: [Int], element el: AXUIElement,
              windowFrame: CGRect, actionMode: String, validation: String,
              observePath: [Int]?, latencyMs: Int) {
    var db = expLoad()
    let now = Date().timeIntervalSince1970
    var a = db.apps[app] ?? ExpApp(bundleId: app, appVersion: appVersion(pid),
                                   lastUpdated: now, entries: [:])
    // 应用升级后旧路径可信度下降：写回时同步版本号，由 status 降级处理
    a.appVersion = appVersion(pid)
    a.lastUpdated = now

    let key = expKey(intent: intent, label: label, role: role, identifier: identifier)
    var e = a.entries[key] ?? ExpEntry(
        key: key, intent: intent, label: label, role: role, identifier: identifier,
        path: path, relRect: [0, 0, 0, 0], windowSize: [0, 0],
        actionMode: actionMode, validation: validation, observePath: observePath,
        successCount: 0, failureCount: 0, recentLatencyMs: [],
        lastVerifiedAt: 0, status: "candidate")

    // 更新位置特征（归一化，换窗口尺寸后仍可用）
    if let p = axPoint(el, kAXPositionAttribute), let s = axSize(el, kAXSizeAttribute),
       windowFrame.width > 0, windowFrame.height > 0 {
        e.relRect = [Double((p.x - windowFrame.minX) / windowFrame.width),
                     Double((p.y - windowFrame.minY) / windowFrame.height),
                     Double(s.width / windowFrame.width),
                     Double(s.height / windowFrame.height)]
    }
    e.windowSize = [Double(windowFrame.width), Double(windowFrame.height)]
    e.path = path
    e.role = role
    e.identifier = identifier
    e.actionMode = actionMode
    e.validation = validation
    if let op = observePath { e.observePath = op }

    e.successCount += 1
    e.recentLatencyMs.append(latencyMs)
    if e.recentLatencyMs.count > 10 { e.recentLatencyMs.removeFirst(e.recentLatencyMs.count - 10) }
    e.lastVerifiedAt = now

    // 生命周期：一次成功只是候选，重复成功才升级
    e.status = e.successCount >= 6 ? "stable" : (e.successCount >= 3 ? "verified" : "candidate")

    a.entries[key] = e
    db.apps[app] = a
    expSave(db)
}

func expRecordFailure(app: String, intent: String, label: String, role: String, identifier: String) {
    var db = expLoad()
    guard var a = db.apps[app] else { return }
    let key = expKey(intent: intent, label: label, role: role, identifier: identifier)
    guard var e = a.entries[key] else { return }
    e.failureCount += 1
    // 连续失败 → 降级；完全不可信时删掉，避免错误经验持续强化自己
    let total = e.successCount + e.failureCount
    if e.failureCount >= 3 && Double(e.failureCount) / Double(max(1, total)) > 0.5 {
        a.entries.removeValue(forKey: key)
    } else {
        e.status = e.successCount >= 3 ? "verified" : "candidate"
        a.entries[key] = e
    }
    a.lastUpdated = Date().timeIntervalSince1970
    db.apps[app] = a
    expSave(db)
}

/// 记录一次观测结果。
///
/// 为什么不「一次超时就摘掉」：幂等操作（重复点「全部清除」）本来就不会让界面变化，
/// 拿它当「盯错元素」的证据，会把好经验误杀 —— 实测就是这样把所有事件驱动验证废掉的。
/// 规则：成功即清零；连续 3 次失败才认定盯错，摘掉 observePath 退回指纹。
func expNoteObserve(app: String, intent: String, label: String, role: String,
                    identifier: String, success: Bool) {
    var db = expLoad()
    guard var a = db.apps[app] else { return }
    let key = expKey(intent: intent, label: label, role: role, identifier: identifier)
    guard var e = a.entries[key] else { return }
    if success {
        if (e.observeFail ?? 0) != 0 { e.observeFail = 0; a.entries[key] = e; db.apps[app] = a; expSave(db) }
        return
    }
    let n = (e.observeFail ?? 0) + 1
    e.observeFail = n
    if n >= 3, e.observePath != nil {
        e.observePath = nil
        e.validation = "fingerprint"
    }
    a.entries[key] = e
    db.apps[app] = a
    expSave(db)
}

// MARK: 统计

struct ExpStats {
    var entries = 0
    var stable = 0
    var verified = 0
    var candidate = 0
    var medianLatency = 0
}

func expStats(app: String? = nil) -> ExpStats {
    let db = expLoad()
    var st = ExpStats()
    var lat: [Int] = []
    let apps = app.map { [$0] } ?? Array(db.apps.keys)
    for k in apps {
        guard let a = db.apps[k] else { continue }
        for e in a.entries.values {
            st.entries += 1
            switch e.status {
            case "stable": st.stable += 1
            case "verified": st.verified += 1
            default: st.candidate += 1
            }
            lat.append(e.medianLatencyMs)
        }
    }
    if !lat.isEmpty {
        let s = lat.sorted(); st.medianLatency = s[s.count / 2]
    }
    return st
}

// MARK: 命令

func cmdExperience(_ args: Args) {
    gJSONMode = args.flag("json")
    gPretty = args.flag("pretty")
    let sub = args.positional.first ?? "list"

    switch sub {
    case "list", "show":
        let db = expLoad()
        let target = args.str("app")
        if gJSONMode {
            if let t = target, let a = db.apps[t] {
                emit(["ok": true, "schemaVersion": db.schemaVersion, "app": t,
                      "appVersion": a.appVersion, "entries": a.entries.values.map(expDict)])
            } else {
                emit(["ok": true, "schemaVersion": db.schemaVersion,
                      "apps": db.apps.mapValues { ["appVersion": $0.appVersion, "count": $0.entries.count] }])
            }
            exit(0)
        }
        print("经验库 schema v\(db.schemaVersion)  \(expPath().path)")
        if db.apps.isEmpty { print("  （空）"); exit(0) }
        for (bid, a) in db.apps.sorted(by: { $0.key < $1.key }) where target == nil || target == bid {
            print("\n\(bid)  v\(a.appVersion.isEmpty ? "?" : a.appVersion)  \(a.entries.count) 条")
            for e in a.entries.values.sorted(by: { $0.successCount > $1.successCount }) {
                print(String(format: "  [%-9@] %-14@ path=%@  %d 成功/%d 失败  中位 %dms  可信 %.2f",
                             e.status as NSString, e.label as NSString,
                             e.path.map(String.init).joined(separator: "/") as NSString,
                             e.successCount, e.failureCount, e.medianLatencyMs, e.confidence))
            }
        }
        exit(0)

    case "clear":
        if args.flag("all") || args.str("app") == nil {
            try? FileManager.default.removeItem(at: expPath())
            emitText("✅ 已清空整个经验库")
        } else if let app = args.str("app") {
            var db = expLoad()
            db.apps.removeValue(forKey: app)
            expSave(db)
            emitText("✅ 已清空 \(app) 的经验")
        }
        exit(0)

    case "stats":
        let st = expStats(app: args.str("app"))
        let out: [String: Any] = ["ok": true, "entries": st.entries, "stable": st.stable,
                                  "verified": st.verified, "candidate": st.candidate,
                                  "medianLatencyMs": st.medianLatency]
        if gJSONMode { emit(out) }
        else { emitText("经验 \(st.entries) 条（stable \(st.stable) / verified \(st.verified) / candidate \(st.candidate)）  中位延迟 \(st.medianLatency)ms") }
        exit(0)

    default:
        emitText("""
        wbcu experience <list|stats|clear>

          wbcu experience list [--app com.apple.calculator]
          wbcu experience stats
          wbcu experience clear [--app X | --all]
        """)
        exit(0)
    }
}

func expDict(_ e: ExpEntry) -> [String: Any] {
    var d: [String: Any] = [
        "label": e.label, "role": e.role, "identifier": e.identifier,
        "path": e.path, "actionMode": e.actionMode, "validation": e.validation,
        "success": e.successCount, "failure": e.failureCount,
        "status": e.status, "confidence": (e.confidence * 100).rounded() / 100,
        "medianLatencyMs": e.medianLatencyMs
    ]
    if let op = e.observePath { d["observePath"] = op }
    return d
}
