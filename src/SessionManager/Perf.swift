import Foundation

// MARK: - 单调时钟计时 + 性能日志
//
// 为什么不用 Date()：Wall clock 会被 NTP 校时、手动改时间影响，
// 测延迟必须用单调时钟。这里统一用 DispatchTime.uptimeNanoseconds。
//
// 为什么记 JSONL：一次操作一行，便于 `bench` 直接算 P50/P95，
// 也便于事后用 jq / pandas 分析。日志只记元数据，不记截图与文本内容。

@inline(__always)
func nowNs() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

@inline(__always)
func msSince(_ startNs: UInt64) -> Double {
    Double(nowNs() &- startNs) / 1_000_000.0
}

/// 一次操作的阶段耗时（毫秒）
struct StageTiming {
    var resolve = 0.0      // 定位元素：AX 树遍历 / 经验命中后的路径回查
    var capture = 0.0      // 截图（仅在需要视觉时）
    var cursor = 0.0       // 虚拟光标动画等待（Fast 模式下应接近 0）
    var dispatch = 0.0     // 事件投递（AXPress / postToPid）
    var verify = 0.0       // 结果验证
    var visibility = 0.0   // 目标窗口可见性判定（一次窗口列表快照）
    var focus = 0.0        // 焦点取证（keyWindow / focusedUIElement）
    var total = 0.0

    func dict() -> [String: Any] {
        ["resolveMs": r(resolve), "captureMs": r(capture), "cursorMs": r(cursor),
         "dispatchMs": r(dispatch), "verifyMs": r(verify),
         "visibilityMs": r(visibility), "focusMs": r(focus), "totalMs": r(total)]
    }
    private func r(_ v: Double) -> Double { (v * 10).rounded() / 10 }
}

func perfDir() -> URL {
    let d = stateDir().appendingPathComponent("perf")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

/// 追加一行性能记录。失败静默——性能日志不该影响主流程。
func perfLog(_ record: [String: Any]) {
    var r = record
    r["ts"] = Date().timeIntervalSince1970
    guard let d = try? JSONSerialization.data(withJSONObject: r, options: [.sortedKeys]) else { return }
    let url = perfDir().appendingPathComponent("perf.jsonl")
    var line = d
    line.append(0x0A)
    if let fh = try? FileHandle(forWritingTo: url) {
        fh.seekToEndOfFile(); fh.write(line); try? fh.close()
    } else {
        try? line.write(to: url)
    }
}

/// 读最近 N 条性能记录（给 bench 与 stats 用）
func perfRead(limit: Int = 500) -> [[String: Any]] {
    let url = perfDir().appendingPathComponent("perf.jsonl")
    guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return [] }
    let lines = raw.split(separator: "\n").suffix(limit)
    return lines.compactMap { line in
        guard let d = line.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        return o
    }
}

func perfReset() { try? FileManager.default.removeItem(at: perfDir().appendingPathComponent("perf.jsonl")) }

// MARK: - 统计

struct LatencyStats {
    var n = 0
    var min = 0.0
    var p50 = 0.0
    var p95 = 0.0
    var max = 0.0
    var mean = 0.0

    static func from(_ values: [Double]) -> LatencyStats {
        guard !values.isEmpty else { return LatencyStats() }
        let s = values.sorted()
        func pct(_ p: Double) -> Double {
            let idx = Int((Double(s.count - 1) * p).rounded())
            return s[Swift.max(0, Swift.min(s.count - 1, idx))]
        }
        var st = LatencyStats()
        st.n = s.count
        st.min = s.first!
        st.max = s.last!
        st.p50 = pct(0.50)
        st.p95 = pct(0.95)
        st.mean = s.reduce(0, +) / Double(s.count)
        return st
    }

    func dict() -> [String: Any] {
        ["n": n, "minMs": rnd(min), "p50Ms": rnd(p50), "p95Ms": rnd(p95),
         "maxMs": rnd(max), "meanMs": rnd(mean)]
    }
    private func rnd(_ v: Double) -> Double { (v * 10).rounded() / 10 }
    func line(_ label: String) -> String {
        String(format: "  %-18@ n=%-3d  P50 %6.1f ms   P95 %6.1f ms   mean %6.1f ms   max %6.1f ms",
               label as NSString, n, p50, p95, mean, max)
    }
}
