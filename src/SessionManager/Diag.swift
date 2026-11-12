import Foundation
import AppKit
import CoreGraphics
import ApplicationServices

// MARK: - 诊断命令集合（v0.4.3 审计用）
//
// 这些命令只读，不改变任何状态（除 `compat --reset` 显式复位）。
// 目的：让第三方审查不必读源码就能看到「引擎认为自己在什么环境里」。

/// `wbcu displays [--json]`
func cmdDisplays(_ args: Args) {
    gJSONMode = args.flag("json")
    let ds = DisplayCoordinateTransformer.liveDisplays()
    let out: [String: Any] = ["ok": true, "count": ds.count,
                              "displays": DisplayCoordinateTransformer.describe(ds),
                              "primaryHeight": DisplayCoordinateTransformer.primaryHeight(ds)]
    if gJSONMode { emit(out) } else {
        emitText("显示器 \(ds.count) 台（primaryHeight=\(DisplayCoordinateTransformer.primaryHeight(ds))）")
        for d in ds {
            emitText(String(format: "  %@  主屏=%@  scale=%.1f  CG(%.0f,%.0f %.0fx%.0f)  AppKit(%.0f,%.0f %.0fx%.0f)",
                            d.id, d.isPrimary ? "是" : "否", d.backingScale,
                            d.cgFrame.minX, d.cgFrame.minY, d.cgFrame.width, d.cgFrame.height,
                            d.appKitFrame.minX, d.appKitFrame.minY,
                            d.appKitFrame.width, d.appKitFrame.height))
        }
    }
    exit(0)
}

/// `wbcu compat [--reset] [--json]`
func cmdCompat(_ args: Args) {
    gJSONMode = args.flag("json")
    if args.flag("reset") {
        EventFieldCompat.reset()
        if gJSONMode { emit(["ok": true, "reset": true]) } else { emitText("✅ 兼容层记录已复位") }
        exit(0)
    }
    let d = EventFieldCompat.describe()
    if gJSONMode { var o = d; o["ok"] = true; emit(o) } else {
        emitText("未文档化字段兼容层")
        emitText("  OS: \(d["osVersion"] ?? "")  大版本已验证=\(d["osVerified"] ?? false)")
        emitText("  字段: 51/58/91/92   CGEventSetWindowLocation=\(d["hasSetWindowLocation"] ?? false)")
        emitText("  已验证大版本: \(d["verifiedOSMajors"] ?? [])")
        if let apps = d["apps"] as? [String: Any], !apps.isEmpty {
            emitText("  逐应用记录：")
            for (k, v) in apps.sorted(by: { $0.key < $1.key }) {
                emitText("    \(k): \(v)")
            }
        }
    }
    exit(0)
}

/// `wbcu focus --window <id> | --app <bundleId> [--json]`
func cmdFocus(_ args: Args) {
    gJSONMode = args.flag("json")
    let (pid, wid) = inputTarget(args)
    var target = pid
    if target == nil, let w = wid { target = pidForWindow(w) }
    guard let p = target else { fail("需要 --window 或 --app", code: 5) }
    let f = FocusProbe.read(pid: p)
    let front = FocusProbe.readFrontmost()
    var out = f.dict
    out["ok"] = true
    out["pid"] = Int(p)
    out["frontBundle"] = front.bundle
    out["frontPid"] = Int(front.pid)
    if gJSONMode { emit(out) } else {
        emitText("pid \(p)  active=\(f.appActive)  keyWindow=\(f.keyWindowId.map { Int($0) } ?? 0)  第一响应者=\(f.focusedRole)/\(f.focusedIdentifier)")
        emitText("  前台: \(front.name) (\(front.bundle))")
    }
    exit(0)
}
