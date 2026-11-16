# WorkBuddy Third Hand 跨平台契约 (v1.0)

这份文件是 macOS 引擎（Swift）与 Windows 引擎（C#）之间的**唯一权威定义**。
任何一边改了动作名、错误码、验证口径，都必须先改这里，再改两个实现，否则
`scripts/check-contract-parity.sh` 会红。

契约是**可执行**的，不只是文档：

```bash
wbcu contract --json            # macOS 引擎输出
wbcu.exe contract --json        # Windows 引擎输出
./scripts/check-contract-parity.sh   # 逐字对比两侧（CI 可跑）
```

---

## 1. 统一动作（11 条）

| 动作 | 语义 | macOS 实现 | Windows 实现 |
|---|---|---|---|
| `launch` | 后台启动目标应用 | `NSWorkspace.OpenConfiguration.activates=false` | `CreateProcessW` + `SW_SHOWNOACTIVATE` |
| `attach` | 建立会话（定位窗口 + 记录身份） | `session start`（AX 授权检查） | `attach`（UIA 可用性检查） |
| `inspect` | 读 UI 树 | AX 树 | UIA 树（含 Patterns） |
| `capture` | 抓目标窗口画面 | ScreenCaptureKit | Windows.Graphics.Capture / PrintWindow |
| `click` | 点击元素或坐标 | AXPress → `postToPid` → 坐标 | UIA Pattern → `SendMessageTimeout` → 坐标 |
| `type` | 写入文本 | 写 AXValue → 键盘兜底 | UIA ValuePattern → `WM_CHAR` |
| `scroll` | 滚动 | 定向投递 | UIA ScrollPattern → `WM_MOUSEWHEEL` |
| `key` | 按键组合 | `postToPid` | `WM_KEYDOWN/UP` |
| `verify` | 只读验证 | AX 状态读数 | UIA 状态读数 |
| `trace` | 前台切换归因 | `NSWorkspace` 通知 | `SetWinEventHook(EVENT_SYSTEM_FOREGROUND)` |
| `endSession` | 结束会话并清理 | `session end` | `session end` |

> 动作名是**意图**，不是实现。两个引擎可以用完全不同的 API 完成同一个动作，
> 但对外报出的 action 名、结果结构、验证口径必须一致。

---

## 2. 结果信封

```jsonc
{
  "ok": false,               // 只表示「操作目标达成」，不表示 API 调用成功
  "action": "click",
  "platform": "windows",     // windows | macos
  "engine": "windows-uia",   // windows-uia | macos-ax
  "method": "uia_invoke",    // 实际执行路径
  "delivered": true,         // 事件是否进入目标（null = 未涉及）
  "verified": false,         // UI 是否真的变了（null = 没验证/验证不可用）
  "verification": { "result": "failure", "confidence": 0.95, "..." : "..." },
  "failureReason": "期望 \"15\"，实际 \"12\"",
  "errorCode": "deliver_failed",
  "frontAppPreserved": true,          // null = 未测量
  "physicalCursorPreserved": true,    // null = 未测量
  "elapsedMs": 84.2,
  "data": { },               // 动作专属数据
  "warnings": []             // 任何降级路径都必须出现在这里
}
```

### 不可违反的六条

1. `ok` 只表示操作目标达成，不表示 API 调用返回成功。
2. `delivered` 与 `verified` 必须分开上报。
3. 未测量的布尔字段必须是 `null`，不能填 `true`。
4. `inconclusive` 不能映射成 `ok=true`。
5. 任何降级路径必须写进 `warnings`。
6. 物理鼠标位置与前台窗口的变化必须如实上报。

---

## 3. 验证四分类

| result | 判据 | 置信度口径 | `ok` |
|---|---|---|---|
| `success` | 明确达到期望值 | 0.95（显式期望）/ 0.75（仅指纹变化） | true |
| `already_satisfied` | 操作前就已满足期望 | 0.60（幂等）/ 0.55（声明幂等） | true |
| `failure` | 实际与期望不一致 | 0.95 | false |
| `inconclusive` | 证据不足 | 0.30 / 0.20 | false |

方法名带 provider 前缀：macOS 用 `ax_*`，Windows 用 `uia_*`，语义相同、证据来源可区分。
例如 `ax_state_matches_expected` 与 `uia_state_matches_expected`。

**为什么 `already_satisfied` 只有 0.60**：只能证明「最终状态符合期望」，
无法证明「这次点击真的被应用消费了」。要证明消费，需要事件侧证据
（应用侧事件计数、或 UI 在点击瞬间的中间态），这一层拿不到。

### 匹配模式

`equals`（默认，先归一化）｜`contains`｜`not_equals`｜`changed`｜`not_changed`｜`strict`（不归一化）

归一化口径（两平台一致）：丢弃 Unicode `Format`/`Control` 类字符（LRM/ZWSP/BOM…）、
ASCII 逗号、U+00A0，然后 trim。副作用：`"a,b"` 会归一成 `"ab"`。
这是刻意保留的既有行为——宁可吃掉普通逗号，也不要让千分位造成误判。

---

## 4. 选择器语法

| 语法 | 含义 | 备注 |
|---|---|---|
| `automationid:Foo` / `id:Foo` | Windows `AutomationId` = Foo；macOS `AXIdentifier` | **长期记忆首选** |
| `name:保存` | 名称精确匹配（归一化后） | 裸字符串等同于此 |
| `name:~保存` | 名称包含 | |
| `controltype:Button` / `role:AXButton` | 控件类型 | `AX` 前缀自动去掉 |
| `class:NotepadEdit` | 类名 | Win32 窗口类 / macOS AXSubrole |
| `helptext:保存` | 帮助文本包含 | |
| `value:15` | 当前值等于 | |
| `path:0,1,7` | 从窗口根节点出发的树索引路径 | 短命，仅运行时定位 |
| `index:7` | 扁平树序第 7 个 | 短命 |
| 末尾 `[n]` | 同名第 n 个（0 基） | 例：`controltype:StaticText[1]` |

**长期记忆只许存 `automationid` / `name` / `controltype` / `path` 这类语义标识**；
HWND、RuntimeId、绝对坐标是短命的，只用于运行时定位和短期复验。

---

## 5. 错误码（17 条）

`bad_args` `app_not_found` `window_not_found` `window_minimized` `protected_window`
`no_session` `session_stale` `uia_unavailable` `element_not_found` `uia_pattern_unsupported`
`deliver_failed` `capture_unavailable` `capture_failed` `permission_denied`
`not_supported_on_platform` `timeout` `internal_error`

新增码只能追加，不得改变已有码的含义。
`uia_unavailable` / `uia_pattern_unsupported` 在 macOS 上表示「对应的 Accessibility 能力不可用」，
保留同名是为了让 Skill 侧只写一套分支。

---

## 6. 能力键（15 个）

`uia_semantic_ops` `background_click` `background_type` `foreground_fallback`
`window_capture` `minimized_window_capture` `ghost_cursor` `session_reuse`
`result_verification` `experience_memory` `activation_trace` `multi_monitor_dpi`
`elevated_target` `electron_apps` `custom_drawn_ui`

状态只能取：`supported` / `partial` / `unsupported` / `not_tested`。

**纪律：代码写完 ≠ supported。** 没有实机验证的能力只能是 `not_tested`，
Windows 侧的 `gui-verified.json` 由 `wbcu-guitests.exe` 全部通过后才写入。

---

## 7. 会话与经验格式

- 会话：`SessionRecord`（id / pid / 窗口句柄 / 可执行文件 / 包族 / DPI / 帧矩形 / 生命周期）
- 经验：`AppExperience`（应用身份 + 若干 WorkflowMemory + 每个元素的语义定位 + 方法命中史 + 耗时画像）

字段定义以代码为准：`src-windows/Wbcu.Contract/SessionRecord.cs`、`AppExperience.cs`。
macOS 侧对应结构在 `src/SessionManager/`，字段名一致。

---

## 8. 变更流程

1. 改本文件（先说清语义变化与兼容影响）。
2. 改两边实现（`src/SessionManager/Contract.swift`、`src-windows/Wbcu.Contract/ContractSchema.cs`）。
3. 跑 `./scripts/check-contract-parity.sh`，必须 `PARITY OK`。
4. 跑两边自检：`./bin/wbcu selftest --json`、`wbcu.exe selftest --json`。
