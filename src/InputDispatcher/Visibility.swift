import Foundation
import CoreGraphics
import AppKit
import ApplicationServices
import Darwin

// ============================================================
// 目标窗口可见性管理（TargetWindowVisibilityManager）
//
// 存在的理由：
//   以前「投递了」就等于「成功」，于是目标窗口被挡住/最小化时，
//   引擎会一路 ok 到底，而用户看到的界面一动不动。
//   这个模块负责在动手之前先回答一个问题：
//   **目标窗口现在到底能不能被点到？能点到哪一部分？**
//
// 设计约束（性能）：
//   · 每次动作只调用一次，不做后台高频轮询，不引入常驻扫描线程
//   · 只做一次 CGWindowListCopyWindowInfo（O(n)），遮挡面积用采样网格估算
//   · 采样而不是矩形并集：并集需要布尔运算，采样 15×15=225 次点测试足够准
//
// 这里只做「判断」，不做「改变」：
//   不调用 AXRaise、不激活 App、不切 Space、不把窗口顶上来。
//   可见性不合格时由调用方决定降级或如实失败 —— 不允许伪装成功。
// ============================================================

enum TargetVisibility: String {
    /// 目标 App 就是前台，且目标窗口是它最前面的窗口
    case front = "front"
    /// 目标窗口可见（未被完全遮住），但 App 不在前台
    case background = "background"
    /// 可见面积被压在 5%~95% 之间
    case partiallyOccluded = "partially_occluded"
    /// 可见面积 < 5%
    case fullyOccluded = "fully_occluded"
    /// 窗口被最小化到 Dock
    case minimized = "minimized"
    /// 窗口不在当前 Space（或已被关闭）
    case offScreen = "off_screen"
    case unknown = "unknown"

    /// 该状态下「按坐标投递」是否还有意义
    var pointDispatchPlausible: Bool {
        switch self {
        case .front, .background, .partiallyOccluded, .fullyOccluded: return true
        default: return false
        }
    }
}

struct CoveringWindow {
    var id: CGWindowID
    var pid: pid_t
    var owner: String
    var sameApp: Bool
    var coversPoint: Bool
}

struct VisibilityReport {
    var state: TargetVisibility = .unknown
    /// 目标矩形未被遮挡的面积占比（采样估算，0~1）
    var visibleFraction: Double = 0
    var targetIsFrontApp = false
    var targetIsAppFrontWindow = true
    var pointVisible = false
    var covering: [CoveringWindow] = []
    var costMs: Double = 0
    var note = ""

    var dict: [String: Any] {
        [
            "state": state.rawValue,
            "visibleFraction": (visibleFraction * 1000).rounded() / 1000,
            "targetIsFrontApp": targetIsFrontApp,
            "targetIsAppFrontWindow": targetIsAppFrontWindow,
            "pointVisible": pointVisible,
            "coveringCount": covering.count,
            "covering": covering.prefix(6).map {
                ["owner": $0.owner, "pid": Int($0.pid), "sameApp": $0.sameApp]
            },
            "note": note
        ]
    }
}

enum TargetWindowVisibilityManager {

    /// 采样网格（15×15）；对「有没有被挡住」这个问题，精度远高于判断所需的粒度
    private static let gridN = 15

    /// 只算一次窗口列表，report 与 pointVisible 共用
    static func report(pid: pid_t,
                       windowId: CGWindowID,
                       point: CGPoint? = nil,
                       frontPid: pid_t? = nil) -> VisibilityReport {
        let t0 = nowNs()
        var r = VisibilityReport()

        let front = frontPid ?? NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1
        r.targetIsFrontApp = (front == pid)

        // ① 在「屏上窗口」里找目标。列表是前→后顺序。
        let onScreen = listCGWindows(onScreenOnly: true)
        guard let idx = onScreen.firstIndex(where: { $0.id == windowId }) else {
            // ② 屏上找不到：区分「最小化」「不在当前 Space / 已关闭」
            let all = listCGWindows(onScreenOnly: false)
            if let rec = all.first(where: { $0.id == windowId }) {
                if axWindowIsMinimized(pid: pid, windowId: windowId) {
                    r.state = .minimized
                    r.note = "窗口已最小化到 Dock"
                } else if rec.bounds.width < 40 || rec.bounds.height < 40 {
                    r.state = .offScreen
                    r.note = "窗口尺寸异常（\(Int(rec.bounds.width))×\(Int(rec.bounds.height))）"
                } else {
                    r.state = .offScreen
                    r.note = "窗口不在当前 Space 或未上屏"
                }
            } else {
                r.state = .unknown
                r.note = "找不到该窗口（可能已关闭）"
            }
            r.visibleFraction = 0
            r.pointVisible = false
            r.costMs = msSince(t0)
            return r
        }

        let target = onScreen[idx]
        let above = Array(onScreen[0..<idx])

        // ③ 只把「同层级、不透明」的窗口算作遮挡者。
        //    菜单栏/状态栏/Dock 的 layer 不为 0，不该被当遮挡；
        //    全透明窗口（alpha≈0）也不该算。
        let blockers = above.filter {
            $0.id != windowId && $0.layer == target.layer && $0.alpha > 0.02 &&
            $0.bounds.width > 8 && $0.bounds.height > 8
        }

        r.targetIsAppFrontWindow = !blockers.contains { $0.pid == pid }

        // ④ 采样估算可见比例
        let tb = target.bounds
        if tb.width > 1, tb.height > 1 {
            var visible = 0
            var total = 0
            for gy in 0..<gridN {
                for gx in 0..<gridN {
                    let p = CGPoint(x: tb.minX + tb.width * (Double(gx) + 0.5) / Double(gridN),
                                    y: tb.minY + tb.height * (Double(gy) + 0.5) / Double(gridN))
                    total += 1
                    if !blockers.contains(where: { $0.bounds.contains(p) }) { visible += 1 }
                }
            }
            r.visibleFraction = total > 0 ? Double(visible) / Double(total) : 0
        }

        // ⑤ 命中点是否可见（光标画不画、点了会不会落到别人身上，都靠这个）
        if let pt = point {
            let hit = blockers.first(where: { $0.bounds.contains(pt) })
            r.pointVisible = (hit == nil)
            if let h = hit {
                r.covering = [CoveringWindow(id: h.id, pid: h.pid, owner: h.owner,
                                             sameApp: h.pid == pid, coversPoint: true)]
            }
        } else {
            r.pointVisible = r.visibleFraction > 0.02
        }

        // ⑥ 汇总遮挡者（只为了报告可读，不再影响判断）
        r.covering += blockers
            .filter { $0.bounds.intersects(tb) }
            .prefix(5)
            .map { CoveringWindow(id: $0.id, pid: $0.pid, owner: $0.owner,
                                  sameApp: $0.pid == pid, coversPoint: false) }

        // ⑦ 定状态
        if r.visibleFraction >= 0.95 && r.targetIsFrontApp && r.targetIsAppFrontWindow {
            r.state = .front
        } else if r.visibleFraction >= 0.95 {
            r.state = .background
            if !r.targetIsAppFrontWindow { r.note = "目标窗口上方还有本应用的其它窗口" }
            else if !r.targetIsFrontApp { r.note = "目标 App 不在前台" }
        } else if r.visibleFraction >= 0.05 {
            r.state = .partiallyOccluded
            r.note = "约 \(Int(r.visibleFraction * 100))% 可见"
        } else {
            r.state = .fullyOccluded
            r.note = "几乎完全被其它窗口遮住"
        }
        r.costMs = msSince(t0)
        return r
    }

    /// 点是否落在目标窗口的「可见部分」（未被更上层窗口盖住）
    static func pointVisible(windowId: CGWindowID, point: CGPoint) -> Bool {
        let onScreen = listCGWindows(onScreenOnly: true)
        guard let idx = onScreen.firstIndex(where: { $0.id == windowId }) else { return false }
        let target = onScreen[idx]
        guard target.bounds.contains(point) else { return false }
        for w in onScreen[0..<idx] where w.layer == target.layer && w.alpha > 0.02 {
            if w.bounds.contains(point) { return false }
        }
        return true
    }

    /// 目标窗口的可见矩形（用于把光标限制在窗口内）
    static func windowFrame(_ windowId: CGWindowID) -> CGRect? {
        listCGWindows(onScreenOnly: false).first(where: { $0.id == windowId })?.bounds
    }

    /// AX 侧查询窗口是否最小化；拿不到就返回 false（不猜）
    static func axWindowIsMinimized(pid: pid_t, windowId: CGWindowID) -> Bool {
        for w in windowsOf(pid) {
            if cgWindowId(of: w) == windowId {
                if let v = axAttr(w, kAXMinimizedAttribute) as? Bool { return v }
                return false
            }
        }
        return false
    }

    /// 适用于报告的「一句话结论」，供 CLI 直接打印
    static func humanNote(_ r: VisibilityReport) -> String {
        switch r.state {
        case .front: return "目标在前台，可见"
        case .background: return "目标在后台但可见（未被遮挡）"
        case .partiallyOccluded: return "目标部分被遮挡（\(Int(r.visibleFraction * 100))% 可见）"
        case .fullyOccluded: return "目标基本被遮挡，坐标点击可能落到挡在前面的窗口上"
        case .minimized: return "目标已最小化"
        case .offScreen: return "目标不在当前 Space"
        case .unknown: return "目标窗口状态未知"
        }
    }
}
