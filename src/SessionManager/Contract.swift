import Foundation

// ============================================================
// 跨平台契约（v0.6.0）
//
// 这份输出的**权威定义**在仓库 contract/README.md，可执行版本有两个实现：
//   - macOS：本文件（Swift）
//   - Windows：src-windows/Wbcu.Contract/ContractSchema.cs
//
// 为什么要把契约做成可执行输出：
//   文档会漂，代码不会。两个引擎各自实现时，只要有一边动作名或错误码改了一个字母，
//   两边的 contract 输出立刻不一致，测试就会红。
//
// 约定：
//   - actions / errorCodes / verifyCategories / matchModes / capabilityKeys 必须逐字一致。
//   - platform / engine 允许不同（这是它们存在的意义）。
//   - invariants 是纪律，不是口号：任何一条被违反，结果就不可信。
// ============================================================

func cmdContract(_ args: Args) {
    let doc: [String: Any] = [
        "schemaVersion": "1.0",
        "platform": "macos",
        "engine": "macos-ax",
        "engineVersion": VERSION,

        "actions": [
            "launch", "attach", "inspect", "capture", "click",
            "type", "scroll", "key", "verify", "trace", "endSession",
        ],

        "errorCodes": [
            "bad_args", "app_not_found", "window_not_found", "window_minimized",
            "protected_window", "no_session", "session_stale", "uia_unavailable",
            "element_not_found", "uia_pattern_unsupported", "deliver_failed",
            "capture_unavailable", "capture_failed", "permission_denied",
            "not_supported_on_platform", "timeout", "internal_error",
        ],

        "verifyCategories": ["success", "already_satisfied", "failure", "inconclusive"],

        "verifyMethods": [
            "state_matches_expected", "state_pre_equals_expected", "state_unreadable",
            "state_mismatch", "value_found_elsewhere", "ui_changed",
            "declared_idempotent", "expected_no_change", "no_observable_change", "not_verified",
        ],

        "verifyProviders": ["ax", "uia"],

        "matchModes": ["equals", "contains", "not_equals", "changed", "not_changed", "strict"],

        "capabilityKeys": [
            "uia_semantic_ops", "background_click", "background_type", "foreground_fallback",
            "window_capture", "minimized_window_capture", "ghost_cursor", "session_reuse",
            "result_verification", "experience_memory", "activation_trace",
            "multi_monitor_dpi", "elevated_target", "electron_apps", "custom_drawn_ui",
        ],

        "capabilityStatus": ["supported", "partial", "unsupported", "not_tested"],

        "selectorKinds": [
            "auto", "automationid", "name", "controltype", "classname",
            "helptext", "value", "path", "index",
        ],

        "resultFields": [
            "ok", "action", "platform", "engine", "method", "delivered", "verified",
            "verification", "failureReason", "errorCode", "frontAppPreserved",
            "physicalCursorPreserved", "elapsedMs", "data", "warnings",
        ],

        "invariants": [
            "ok 只表示操作目标达成，不表示 API 调用返回成功",
            "delivered 与 verified 必须分开上报",
            "未测量的布尔字段必须是 null，不能填 true",
            "inconclusive 不能映射成 ok=true",
            "任何降级路径必须写进 warnings",
            "物理鼠标位置与前台窗口的变化必须如实上报",
        ],
    ]

    if gJSONMode {
        emit(doc)
        return
    }

    emitText("""
    WorkBuddy Third Hand 契约 v1.0（macOS 引擎 \(VERSION)）
      统一动作：  \((["launch","attach","inspect","capture","click","type","scroll","key","verify","trace","endSession"]).joined(separator: " "))
      验证四分类：success / already_satisfied / failure / inconclusive
      动作名、错误码、能力键与 Windows 引擎逐字一致（见 contract/README.md）
    """)
}
