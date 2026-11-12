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
//
// ── v0.4.3 修的三处漏判 ─────────────────────────────────────
//
// ① 旧规则 `layer == target.layer` 会漏掉**高层级浮动窗口**：
//    NSPanel（.floating=3）、Popover、Tooltip、Inspector 这些层级比普通窗口高，
//    压在目标身上时旧代码直接忽略，于是报告「可见」而实际被挡住。
//    现在按**窗口列表的真实前后次序**判断：只要排在目标之前就算候选遮挡者。
//
// ② 半透明窗口曾用 alpha>0.02 一刀切。alpha 是整窗不透明度，不等于「每个像素都可透视」，
//    但也没有更好的免费信号 —— 保留阈值，同时在报告里把 alpha 带出去，
//    并在文档里写明：这是保守估计，不做像素级判定。
//
// ③ 系统外壳窗口（Dock / 菜单栏 / 控制中心 / 通知中心）有时会报出**全屏大小的 bounds**
//    （那是透明命中区域，不是实际绘制区域）。若按矩形算，几乎所有窗口都会被判成完全遮挡。
//    这类窗口单独标记为 `suspectedShell`：不参与面积计算，但在报告里列出。
//
// 另外：自己的 Cursor Overlay 永远不算遮挡者（否则光标一显示就自我遮挡）。
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
    var layer: Int
    var alpha: Double
    var sameApp: Bool
    var coversPoint: Bool
    /// 疑似系统外壳（Dock/菜单栏等）的大矩形，面积计算时不采信
    var suspectedShell: Bool
}

struct VisibilityReport {
    var state: TargetVisibility = .unknown
    /// 目标矩形未被遮挡的面积占比（采样估算，0~1）
    var visibleFraction: Double = 0
    var targetIsFrontApp = false
    var targetIsAppFrontWindow = true
    var pointVisible = false
    /// 点被「可信遮挡者」盖住（suspectedShell 不算）
    var pointBlockedByConfident = false
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
            "pointBlockedByConfident": pointBlockedByConfident,
            "coveringCount": covering.count,
            "covering": covering.prefix(6).map {
                ["owner": $0.owner, "pid": Int($0.pid), "layer": $0.layer,
                 "alpha": $0.alpha, "sameApp": $0.sameApp,
                 "coversPoint": $0.coversPoint, "suspectedShell": $0.suspectedShell]
            },
            "note": note
        ]
    }
}

enum TargetWindowVisibilityManager {

    /// 采样网格（15×15）；对「有没有被挡住」这个问题，精度远高于判断所需的粒度
    private static let gridN = 15

    /// 自己的覆盖层：owner 名包含它，或 pid 等于调用方自己
    private static func isOwnOverlay(_ w: CGWin, selfPid: pid_t) -> Bool {
        if selfPid > 0 && w.pid == selfPid { return true }
        let o = w.owner.lowercased()
        return o.contains("thirdhand") || o.contains("wbcu")
    }

    /// 系统外壳：层很高 + 矩形接近整块屏 → 大概率是透明命中区而不是实际绘制
    private static func looksLikeShell(_ w: CGWin, displayHint: CGRect) -> Bool {
        guard w.layer >= 20 else { return false }          // 菜单栏 25 / Dock 20 / 通知中心更高
        let screenArea = displayHint.width * displayHint.height
        guard screenArea > 0 else { return false }
        let area = w.bounds.width * w.bounds.height
        return area >= screenArea * 0.55
    }

    /// 一次窗口列表快照
    static func report(pid: pid_t,
                       windowId: CGWindowID,
                       point: CGPoint? = nil,
                       frontPid: pid_t? = nil,
                       selfPid: pid_t = 0) -> VisibilityReport {
        let t0 = nowNs()
        var r = VisibilityReport()

        let front = frontPid ?? NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1
        r.targetIsFrontApp = (front == pid)

        let onScreen = listCGWindows(onScreenOnly: true)
        guard let idx = onScreen.firstIndex(where: { $0.id == windowId }) else {
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

        // 目标所在的显示器矩形（用来判断「是不是全屏外壳窗口」）
        let disp = DisplayCoordinateTransformer.display(containingCG:
            CGPoint(x: target.bounds.midX, y: target.bounds.midY))
        let dispRect = disp?.cgFrame ?? screenUnionCG()

        // 候选遮挡者：真实前后次序里排在目标之前的所有窗口，不再按 layer 相等过滤
        var blockers: [CGWin] = []
        var shells: [CGWin] = []
        for w in above {
            if w.id == windowId { continue }
            if isOwnOverlay(w, selfPid: selfPid) { continue }
            if w.alpha <= 0.02 { continue }
            if w.bounds.width <= 2 || w.bounds.height <= 2 { continue }
            if !w.bounds.intersects(target.bounds) { continue }
            if looksLikeShell(w, displayHint: dispRect) { shells.append(w) } else { blockers.append(w) }
        }

        r.targetIsAppFrontWindow = !blockers.contains { $0.pid == pid } && !shells.contains { $0.pid == pid }

        // 采样估算可见比例（只用可信遮挡者，外壳窗口不参与）
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

        // 命中点
        if let pt = point {
            let confident = blockers.filter { $0.bounds.contains(pt) }
            let shellHit = shells.filter { $0.bounds.contains(pt) }
            r.pointBlockedByConfident = !confident.isEmpty
            r.pointVisible = confident.isEmpty && shellHit.isEmpty
            for b in confident.prefix(3) {
                r.covering.append(CoveringWindow(id: b.id, pid: b.pid, owner: b.owner,
                                                 layer: b.layer, alpha: b.alpha,
                                                 sameApp: b.pid == pid, coversPoint: true,
                                                 suspectedShell: false))
            }
            for b in shellHit.prefix(2) {
                r.covering.append(CoveringWindow(id: b.id, pid: b.pid, owner: b.owner,
                                                 layer: b.layer, alpha: b.alpha,
                                                 sameApp: b.pid == pid, coversPoint: true,
                                                 suspectedShell: true))
            }
        } else {
            r.pointVisible = r.visibleFraction > 0.02
            r.pointBlockedByConfident = r.visibleFraction <= 0.02
        }

        r.covering += blockers.filter { $0.bounds.intersects(tb) }.prefix(5)
            .map { CoveringWindow(id: $0.id, pid: $0.pid, owner: $0.owner, layer: $0.layer,
                                  alpha: $0.alpha, sameApp: $0.pid == pid,
                                  coversPoint: false, suspectedShell: false) }

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
        if !shells.isEmpty {
            r.note += "（另有 \(shells.count) 个疑似系统外壳窗口未计入面积）"
        }
        r.costMs = msSince(t0)
        return r
    }

    static func screenUnionCG() -> CGRect {
        let ds = DisplayCoordinateTransformer.liveDisplays()
        guard let f = ds.first?.cgFrame else { return .zero }
        return ds.dropFirst().reduce(f) { $0.union($1.cgFrame) }
    }

    /// 点是否落在目标窗口的「可见部分」（未被更上层窗口盖住）
    /// selfPid：调用者自己的 pid（光标 daemon），用来跳过自身覆盖层
    static func pointVisible(windowId: CGWindowID, point: CGPoint, selfPid: pid_t = 0) -> Bool {
        let onScreen = listCGWindows(onScreenOnly: true)
        guard let idx = onScreen.firstIndex(where: { $0.id == windowId }) else { return false }
        let target = onScreen[idx]
        guard target.bounds.contains(point) else { return false }
        let disp = DisplayCoordinateTransformer.display(containingCG: point)?.cgFrame
            ?? screenUnionCG()
        for w in onScreen[0..<idx] {
            if w.id == windowId || isOwnOverlay(w, selfPid: selfPid) { continue }
            if w.alpha <= 0.02 || w.bounds.width <= 2 || w.bounds.height <= 2 { continue }
            guard w.bounds.contains(point) else { continue }
            if looksLikeShell(w, displayHint: disp) { continue }   // 不采信外壳窗口的大矩形
            return false
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
        case .fullyOccluded: return "目标基本被遮挡"
        case .minimized: return "目标已最小化"
        case .offScreen: return "目标不在当前 Space"
        case .unknown: return "目标窗口状态未知"
        }
    }
}

// MARK: - 诊断命令：`wbcu occlusion --window <id> [--x --y]`
//
// 把「谁压在目标上面」按真实前后次序完整打出来。
// 第三方审查遮挡判定时，直接看这个输出即可，不用猜内部规则。
func cmdOcclusion(_ args: Args) {
    gJSONMode = args.flag("json")
    var (pid, wid) = inputTarget(args)
    guard let w = wid else { fail("需要 --window <id>", code: 5) }
    let all = listCGWindows(onScreenOnly: true)
    guard let idx = all.firstIndex(where: { $0.id == w }) else {
        let rep = TargetWindowVisibilityManager.report(pid: pid ?? 0, windowId: w)
        var out = rep.dict
        out["ok"] = true
        out["windowId"] = Int(w)
        if gJSONMode { emit(out) } else { emitText("窗口 \(w) 不在屏上：\(rep.note)") }
        exit(0)
    }
    let target = all[idx]
    if pid == nil { pid = target.pid }
    let pt: CGPoint? = (args.dbl("x") != nil && args.dbl("y") != nil)
        ? CGPoint(x: args.dbl("x")!, y: args.dbl("y")!) : nil
    let rep = TargetWindowVisibilityManager.report(pid: pid ?? 0, windowId: w, point: pt,
                                                  selfPid: 0)
    var stack: [[String: Any]] = []
    for (i, win) in all.enumerated() {
        let rel = i < idx ? "above" : (i == idx ? "target" : "below")
        stack.append(["z": i, "id": Int(win.id), "owner": win.owner, "pid": Int(win.pid),
                      "layer": win.layer, "alpha": win.alpha,
                      // 显式转成 Double：CGFloat 与 Double 在 Swift 里是不同类型，
                      // 直接用 CGFloat 塞进 [String: Any] 再 as? [String: Double] 会静默失败
                      "bounds": ["x": Double(win.bounds.minX), "y": Double(win.bounds.minY),
                                 "w": Double(win.bounds.width), "h": Double(win.bounds.height)],
                      "relation": rel, "intersects": win.bounds.intersects(target.bounds)])
    }
    var out = rep.dict
    out["ok"] = true
    out["windowId"] = Int(w)
    out["targetPid"] = Int(pid ?? 0)
    out["targetBounds"] = ["x": Double(target.bounds.minX), "y": Double(target.bounds.minY),
                           "w": Double(target.bounds.width), "h": Double(target.bounds.height)]
    out["stack"] = stack
    if gJSONMode {
        emit(out)
    } else {
        emitText("目标 \(w) [\(target.owner)] → \(TargetWindowVisibilityManager.humanNote(rep))")
        emitText(String(format: "  可见比例 %.2f   点可见=%@   被可信遮挡=%@",
                        rep.visibleFraction,
                        rep.pointVisible ? "是" : "否",
                        rep.pointBlockedByConfident ? "是" : "否"))
        emitText("  前后次序（前 → 后，只列到目标后 6 个）：")
        for s in stack {
            let z = (s["z"] as? Int) ?? 0
            let rel = (s["relation"] as? String) ?? ""
            if rel == "below" && z > idx + 6 { continue }
            let b = (s["bounds"] as? [String: Double]) ?? [:]
            emitText(String(format: "    #%-3d %-7@ %-18@ layer=%-4d alpha=%.2f (%.0f,%.0f %.0fx%.0f)",
                            z, rel as NSString,
                            (s["owner"] as? String ?? "") as NSString,
                            (s["layer"] as? Int) ?? 0, (s["alpha"] as? Double) ?? 0,
                            b["x"] ?? 0, b["y"] ?? 0, b["w"] ?? 0, b["h"] ?? 0))
        }
    }
    exit(0)
}
