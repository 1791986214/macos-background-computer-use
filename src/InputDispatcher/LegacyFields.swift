import Foundation
import CoreGraphics
import Darwin

// ============================================================
// EventFieldCompat —— 未文档化事件字段的隔离层
//
// 我们在 `targetedClick` 里用了四个没有公开文档的 CGEvent 字段：
//   51  疑似「目标窗口号」
//   58  语义不明（我们写常量 12345，实测能工作，但不知道为什么）
//   91  kCGMouseEventWindowUnderMousePointer 附近
//   92  ...ThatCanHandleThisEvent 附近
// 以及一个私有符号 `CGEventSetWindowLocation`。
//
// v0.4.2 的回执把「字段 51+58+窗口局部坐标 能在本机点中」当成事实记录，
// 但没说清这条事实的**适用边界**。本模块负责把边界写进代码：
//
//   ① 版本闸门：只在「已验证过的大版本」上默认启用；未知大版本 → 保守，
//      优先走 AXPress，除非该应用在本机被证明过 targeted 可行。
//   ② 逐应用退让：连续 3 次投递后验证失败 → 该应用标记 degraded，
//      之后一律 AX 优先（不永久封禁，可通过 `wbcu compat --reset` 复位）。
//   ③ 能力探测：`CGEventSetWindowLocation` 符号不存在时，profile 直接降级。
//   ④ 所有状态落盘 `~/.wbcu/compat.json`，可被第三方直接查看。
//
// 这不解决「字段语义不明」本身 —— 它只是让「不明」不会悄悄变成「默认依赖」。
// ============================================================

struct EventFieldProfile {
    var windowNumberField: UInt32 = 51
    var windowContextField: UInt32 = 58
    /// 写入字段 58 的常量。实测可用，但**语义未确认**，不要据此推断系统行为。
    var windowContextValue: Int64 = 12345
    var underPointerField: UInt32 = 91
    var handlerField: UInt32 = 92
    var hasSetWindowLocation = false
    var osVersion = ""
    var osMajor = 0
    /// 本 OS 大版本是否被本项目的实验矩阵验证过
    var osVerified = false

    var dict: [String: Any] {
        ["fields": ["windowNumber": windowNumberField, "windowContext": windowContextField,
                    "underPointer": underPointerField, "handler": handlerField],
         "windowContextValue": windowContextValue,
         "hasSetWindowLocation": hasSetWindowLocation,
         "osVersion": osVersion, "osMajor": osMajor, "osVerified": osVerified,
         "note": "51/58/91/92 与 CGEventSetWindowLocation 均无公开文档；语义未确认"]
    }
}

struct AppCompatRecord: Codable {
    var targetedOK = 0
    var targetedFail = 0
    var failStreak = 0
    var degraded = false
    var lastResult = ""
}

struct CompatStore: Codable {
    var schemaVersion = 1
    var osMajor = 0
    var apps: [String: AppCompatRecord] = [:]
}

enum EventFieldCompat {
    /// 本项目在哪些 macOS 大版本上跑过投递矩阵（实验证据，不是推测）
    /// 新增验证时在这里登记，并在 docs/compatibility.md 写明实验记录。
    static let verifiedOSMajors: Set<Int> = [14, 15, 26]

    private static var _profile: EventFieldProfile? = nil
    private static var _store: CompatStore? = nil
    // 必须是递归锁：store()/record() 持锁时会再调 profile()
    private static let lock = NSRecursiveLock()

    static func profile() -> EventFieldProfile {
        lock.lock(); defer { lock.unlock() }
        if let p = _profile { return p }
        let v = ProcessInfo.processInfo.operatingSystemVersion
        var p = EventFieldProfile()
        p.osVersion = "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
        p.osMajor = v.majorVersion
        p.osVerified = verifiedOSMajors.contains(v.majorVersion)
        p.hasSetWindowLocation = cgSetWindowLocation != nil
        _profile = p
        return p
    }

    private static func storePath() -> URL {
        stateDir().appendingPathComponent("compat.json")
    }

    static func store() -> CompatStore {
        lock.lock(); defer { lock.unlock() }
        if let s = _store { return s }
        var s = CompatStore()
        if let d = try? Data(contentsOf: storePath()),
           let loaded = try? JSONDecoder().decode(CompatStore.self, from: d) {
            s = loaded
        }
        // 大版本变了就清空逐应用结论（旧结论对新系统没有约束力）
        if s.osMajor != profile().osMajor {
            s = CompatStore()
            s.osMajor = profile().osMajor
        }
        _store = s
        return s
    }

    private static func save(_ s: CompatStore) {
        _store = s
        if let d = try? JSONEncoder().encode(s) { try? d.write(to: storePath()) }
    }

    static func record(app: String, targetedVerified: Bool) {
        lock.lock(); defer { lock.unlock() }
        var s = _store ?? CompatStore()
        if s.osMajor != profile().osMajor { s = CompatStore(); s.osMajor = profile().osMajor }
        var r = s.apps[app] ?? AppCompatRecord()
        if targetedVerified {
            r.targetedOK += 1
            r.failStreak = 0
            r.lastResult = "ok"
        } else {
            r.targetedFail += 1
            r.failStreak += 1
            r.lastResult = "fail"
            if r.failStreak >= 3 { r.degraded = true }
        }
        s.apps[app] = r
        save(s)
    }

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        save(CompatStore(osMajor: profile().osMajor, apps: [:]))
    }

    /// 该应用是否应该「AX 优先、坐标投递只做兜底」
    static func preferAX(app: String) -> Bool {
        let p = profile()
        if !p.hasSetWindowLocation { return true }     // 少了私有符号，坐标路径不完整
        let s = store()
        if let r = s.apps[app], r.degraded { return true }
        if p.osVerified { return false }               // 已验证的大版本：允许 targeted 优先
        // 未验证的大版本：只有在应用被证明过 ≥2 次成功时才敢默认用 targeted
        if let r = s.apps[app], r.targetedOK >= 2, !r.degraded { return false }
        return true
    }

    static func describe() -> [String: Any] {
        var d = profile().dict
        let s = store()
        var apps: [String: Any] = [:]
        for (k, v) in s.apps {
            apps[k] = ["targetedOK": v.targetedOK, "targetedFail": v.targetedFail,
                       "failStreak": v.failStreak, "degraded": v.degraded,
                       "lastResult": v.lastResult]
        }
        d["apps"] = apps
        d["preferAXDefault"] = preferAX(app: "")
        d["verifiedOSMajors"] = verifiedOSMajors.sorted()
        return d
    }
}
