import Foundation
import AppKit

// MARK: - 按应用的显式授权（per-app consent）
//
// TCC 只回答「这个进程能不能看屏幕 / 能不能发事件」，
// 它不回答「WorkBuddy 现在可以替我操作哪个 App」。
// 后者必须自己管：白名单存在 ~/.wbcu/allowlist.json，副作用操作（捕获、点击、键入）必须先授权。

struct GuardEntry: Codable {
    var bundleId: String
    var name: String
    var path: String
    var allowed: Bool
    var updatedAt: String
}

struct GuardStore: Codable {
    var version: Int = 1
    var apps: [String: GuardEntry] = [:]
}

func guardFile() -> URL { stateDir().appendingPathComponent("allowlist.json") }

func loadGuard() -> GuardStore {
    guard let data = try? Data(contentsOf: guardFile()),
          let s = try? JSONDecoder().decode(GuardStore.self, from: data) else {
        return GuardStore()
    }
    return s
}

func saveGuard(_ s: GuardStore) {
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    if let d = try? enc.encode(s) { try? d.write(to: guardFile()) }
}

func nowISO() -> String {
    let f = ISO8601DateFormatter()
    return f.string(from: Date())
}

/// 检查 pid 对应的应用是否被显式授权
func appAuthorized(pid: pid_t) -> (ok: Bool, entry: GuardEntry?, bundleId: String, name: String) {
    let app = NSRunningApplication(processIdentifier: pid)
    let bundleId = app?.bundleIdentifier ?? "unknown.\(pid)"
    let name = app?.localizedName ?? "pid \(pid)"
    let store = loadGuard()
    if let e = store.apps[bundleId], e.allowed {
        return (true, e, bundleId, name)
    }
    return (false, store.apps[bundleId], bundleId, name)
}

/// 副作用操作的安检闸门
func enforceGuard(pid: pid_t, action: String) {
    let st = appAuthorized(pid: pid)
    if st.ok { return }
    let hint = """
    应用「\(st.name)」(\(st.bundleId)) 尚未授权给 Computer Use。
    需要用户明确同意后执行：
        wbcu guard --app \(st.bundleId) --allow
    本次被拦截的操作：\(action)
    """
    if gJSONMode {
        emit(["ok": false, "error": "app_not_authorized", "app": st.name,
              "bundleId": st.bundleId, "action": action, "hint": hint])
    } else {
        FileHandle.standardError.write(("wbcu: " + hint + "\n").data(using: .utf8)!)
    }
    exit(3)
}

// MARK: - 命令：guard
func cmdGuard(_ args: Args) {
    gJSONMode = args.flag("json")
    gPretty = args.flag("pretty")
    var store = loadGuard()

    if args.flag("list") || (args.str("app") == nil && !args.flag("revoke")) {
        if gJSONMode {
            emit(["ok": true, "apps": store.apps.values.map { e -> [String: Any] in
                ["bundleId": e.bundleId, "name": e.name, "allowed": e.allowed, "updatedAt": e.updatedAt]
            }])
        } else {
            if store.apps.isEmpty { emitText("(白名单为空，所有副作用操作都会被拦截)") }
            for e in store.apps.values.sorted(by: { $0.name < $1.name }) {
                emitText("\(e.allowed ? "✅" : "⛔️") \(e.name)  \(e.bundleId)  \(e.updatedAt)")
            }
        }
        exit(0)
    }

    guard let token = args.str("app") else { fail("需要 --app") }
    guard let app = findRunningApp(token) else { fail("找不到应用: \(token)") }
    let bundleId = app.bundleIdentifier ?? "unknown.\(app.processIdentifier)"
    let name = app.localizedName ?? bundleId

    if args.flag("revoke") {
        store.apps[bundleId] = GuardEntry(bundleId: bundleId, name: name,
                                          path: app.bundleURL?.path ?? "", allowed: false, updatedAt: nowISO())
        saveGuard(store)
        if gJSONMode { emit(["ok": true, "revoked": bundleId]) } else { emitText("⛔️ 已撤销授权: \(name) (\(bundleId))") }
        exit(0)
    }

    let allowed = !args.flag("deny")
    store.apps[bundleId] = GuardEntry(bundleId: bundleId, name: name,
                                      path: app.bundleURL?.path ?? "", allowed: allowed, updatedAt: nowISO())
    saveGuard(store)
    if gJSONMode {
        emit(["ok": true, "bundleId": bundleId, "name": name, "allowed": allowed])
    } else {
        emitText(allowed ? "✅ 已授权 Computer Use 操作「\(name)」" : "⛔️ 已拒绝「\(name)」")
    }
    exit(0)
}
