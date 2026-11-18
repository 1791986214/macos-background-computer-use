# Windows 能力矩阵（v0.6.0）

**读法**：`状态` 是本仓库能证明的程度，不是宣称。

| 状态 | 含义 |
|---|---|
| `supported` | 本机实测通过，有报告可查 |
| `partial` | 有可用路径，但存在明确的失败场景 |
| `unsupported` | 不提供，或做了也是骗人 |
| `not_tested` | 代码已实现/编译通过，**尚未在真机验证** |

`wbcu.exe capabilities --json` 返回的就是这张表（运行时探测 + `gui-verified.json` 解锁）。

## 1. 引擎能力

| 能力键 | 状态 | 机制 | 说明 / 证据 |
|---|---|---|---|
| `uia_semantic_ops` | `not_tested`（运行时可达则 `supported`） | `IUIAutomation` (CUIAutomation8) | 编译通过 + COM 互操作程序集；真机 Pattern 行为待验收 |
| `background_click` | `not_tested` | UIA Pattern → `SendMessageTimeout` | 分级降级已实现；成功率取决于目标框架 |
| `background_type` | `not_tested` | `ValuePattern.SetValue` → `WM_CHAR` | `WM_CHAR` 只在部分控件生效 |
| `foreground_fallback` | `unsupported` | `SendInput`（仅 `--allow-global`） | 默认不启用：会移动真实鼠标、进入用户前台窗口 |
| `window_capture` | `partial` | Graphics Capture / PrintWindow | 两条后端都实现；最小化与 DRM 内容取不到 |
| `minimized_window_capture` | `unsupported` | — | 最小化窗口无 DWM 合成表面 |
| `ghost_cursor` | `supported`（代码）/ `not_tested`（观感） | `WS_EX_LAYERED` + `UpdateLayeredWindow` | v0.6.2 起视觉口径由 `GhostTokens` 定义（窗口 126 / 箭头 20×24 / 光晕 56 DIP，三者解耦），见 `docs/ghost-cursor-tokens.md`；光栅与反馈环共 11 个单测；预览图 `docs/images/ghost-cursor-on-light.png` / `-on-dark.png` / `ghost-click-ring.png`；静态时不重绘（脏标记），实际 DWM 合成观感仍待真机看 |
| `session_reuse` | `supported` | 会话 JSON + HWND/PID 校验 | 失效会报 `session_stale`，不拿死句柄硬点 |
| `result_verification` | `supported` | UIA 状态读数 + 树指纹 | 四分类与 macOS 同一套判据，65 个单测覆盖 |
| `experience_memory` | `supported` | 只存语义选择器 | 坐标与 HWND 不进长期库 |
| `activation_trace` | `supported` | `SetWinEventHook(EVENT_SYSTEM_FOREGROUND)` | 事件驱动 + 命令时间窗归因 |
| `multi_monitor_dpi` | `not_tested` | PerMonitorV2 + `GetDpiForWindow` | 代码按物理像素处理；混合 DPI 实机未验收 |
| `elevated_target` | `partial` | asInvoker | UIPI 会挡消息与 UIA；**不做提权** |
| `electron_apps` | `not_tested` | UIA (Chromium accessibility) | 默认关闭无障碍树时只能退化为消息投递 |
| `custom_drawn_ui` | `not_tested` | 窗口消息 / 坐标 | 无 Pattern，成功率不保证 |

## 2. 按应用类型（预期，非实测）

| 目标 | 预期表现 | 风险点 |
|---|---|---|
| 原生 Win32（Button/Edit/CheckBox/ComboBox/ListBox） | 语义操作齐全，后台可点 | 少数自绘所有者绘制按钮无 Pattern |
| WPF / WinUI 3 | UIA Provider 完整 | 虚拟化列表里的元素需要先滚动到可见 |
| Windows Calculator（MSIX） | 按钮有 `AutomationId`，结果元素可读 | 启动必上前台（`ActivateApplication` 固有行为）；中英文元素名不同 |
| 记事本（Win11 新版） | 编辑区可用 UIA 写值 | 新版记事本跨进程 UIA 可能较慢 |
| 文件资源管理器 | 地址栏/工具栏可用 UIA | 部分列表项是虚拟化元素 |
| Electron（VS Code、Slack…） | 视无障碍树是否开启 | 关闭时只能消息投递，多半被忽略 |
| 自绘客户端（游戏、部分国产 IM） | 只能按坐标投递消息 | 大概率不生效，如实报 `failure` |

## 3. 已知系统级限制

1. **UIPI**：目标进程权限更高时，窗口消息与部分 UIA 调用会被静默丢弃。本工具不请求提权、不做 `uiAccess` 绕过。
2. **最小化**：`Windows.Graphics.Capture` 与 `PrintWindow` 都拿不到有效画面。
3. **DRM / 受保护内容**：捕获结果是黑帧。
4. **MSIX 激活**：`IApplicationActivationManager` 一定把窗口带到前台，无法后台化；`launch` 会如实标注 `activatedToForeground=true`。
5. **`WM_CHAR` 语义**：投递 `WM_CHAR` 不等于真实键盘输入；IME、组合键、需要焦点的控件都不会响应。
6. **窗口消息 vs 真实输入**：`SendMessageTimeout` 返回成功只代表消息被处理，不代表业务动作发生。

## 4. 验证证据分级

| 证据 | 覆盖范围 | 位置 |
|---|---|---|
| 编译通过（真实 PE32+） | 全部源码 | `scripts/pack-windows.sh`、CI `windows-build-and-unit-test` |
| 65 个纯逻辑单测 | 契约、验证四分类、选择器、归一化、几何、光标光栅、PNG、经验结构 | `src-windows/Wbcu.Tests`（macOS 与 CI 均通过） |
| 契约一致性 | 两平台动作/错误码/口径逐字一致 | `scripts/check-contract-parity.sh` → `PARITY OK` |
| **真机 GUI 验收** | 点击/遮挡/消息投递/并发/覆盖层/最小化 | `wbcu-guitests.exe`（**尚未运行，待真机**） |

**最后一行没有跑过，所以上表绝大多数能力只能是 `not_tested`。**
这是这份文档存在的主要目的：防止「编译通过」被当成「功能可用」。
