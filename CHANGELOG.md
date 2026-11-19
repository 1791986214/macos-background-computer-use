# 变更记录

格式遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
版本号遵循语义化版本。

## [Unreleased]

## [0.6.4] — 2026-11-19

在 v0.6.3 的 WGC 成果上做常驻化与验收修正，**没有重写捕获模块**。

### 修正：v0.6.3 的「完全遮挡」验收有漏洞

上一份报告用「目标窗口中心点被前台窗口覆盖」判定完全遮挡，结论不成立：
记事本 `(529,244) 992×624` 右边界到 1521，而微信 `(99,88) 1188×784` 右边界只到 1287 ——
右侧 234px 始终露在外面，实际是**部分遮挡**。

已建立可重复的遮挡测试夹具（`capture_fixture.py` + `occluder.py`），
目标窗口每 300ms 计数器 +1、背景换色，**用同一场景连续两次 PNG 是否不同来判断是否为实时画面**。

实测矩阵（全部通过）：

| 场景 | 结果 |
|---|---|
| 完全可见 | graphics_capture_live，连续两次 MD5 不同（实时 ✓） |
| 部分遮挡（盖左 55%） | 同上（实时 ✓） |
| **完全遮挡（四周外扩 10px）** | 同上（实时 ✓） |
| 连续切换前台 ×2 | 正常 |
| 移动窗口（+60,+40） | 正常 |
| 缩放窗口（−120,−80） | 尺寸自动跟随（656×459 → 536×379） |
| 最小化 | 如实报错「无合成表面」，不做假截图 |

### 新增：常驻 Worker（`Worker/WorkerDaemon.cs` + `WorkerClient.cs`）

先测量再动手，实测瓶颈分布：

- CLI 冷启动（.NET apphost + JIT）：**750–1180ms**
- 引擎内捕获（WGC 命中会话）：~210ms
- 结论：`LiveCaptureRegistry` 是**进程内静态表**，进程一退会话就没了 ——
  v0.6.3 所谓的"持久会话"实际只在单条命令内有效，你的判断是对的。

实现：`WorkBuddy → wbcu CLI → Named Pipe → Worker → WGC / UIA / Input`

- Named Pipe 用 `PipeOptions.CurrentUserOnly`，不建服务、不要管理员权限
- 单线程串行处理（UIA 与 D3D11 immediate context 都不是线程安全的）
- CLI 侧 `Ensure()` 自动拉起，连不上**静默回落**本地执行，绝不阻塞
- `capture` 优先走 Worker（`data.worker=true`），`--no-worker` 可强制本地

实测效果：

| 项 | v0.6.3 | v0.6.4 |
|---|---|---|
| 单次 capture 端到端 | 1750–1976ms | **988–1112ms** |
| WGC 会话 | 每条命令重建 | 跨命令复用（worker pid 稳定不变） |

### 已知未达标

- 目标「往返 <50ms」**未达到**。Worker 省掉的是引擎内会话重建（约 700ms），
  但 CLI 本身的 .NET 冷启动（~800ms）仍在。要真正达标需要 CLI 侧 NativeAOT，
  或让调用方直连 Named Pipe 绕过 CLI —— 本轮未做。
- Session 自动重绑定（按 exe 重新发现窗口）**未实现**。
- 企业微信登录态缺失，A/B/C/D 真机验收未执行。

## [0.6.3] — 2026-11-18

Windows 独立窗口捕获（真正可用的 Windows Graphics Capture）、持久捕获会话、
坐标空间参数、后台输入优先级修复。目标：**用户正常用自己的电脑，WorkBuddy 在后台
观察并操作目标应用，切换窗口不应导致截错软件、抢占鼠标或无故停摆。**

### 修复：Windows Graphics Capture 从来就没成功过

v0.6.2 及以前，`capture` 的 `method` 永远是 `printwindow` —— WGC 路径每次都在
`CreateForWindow` 处抛异常，被 catch 后静默降级。这次逐层挖出 4 个叠加的坑：

1. **vtable 槽位错位**：`Marshal.GetTypedObjectForIUnknown` 把
   `RoGetActivationFactory` 返回的工厂包成 RCW，而 `IGraphicsCaptureItemInterop`
   继承的是 **IUnknown**（不是 IInspectable）。ComImport + RCW 的解释与真实布局错位，
   调用到别的方法上。改为直接按 vtable 索引 3 调用。
2. **IID 取错**：`typeof(GraphicsCaptureItem).GUID` 在 CsWinRT 下返回的是**投影类型 GUID**
   （实测 `cc7b16ab-e4bc-3d0e-a4eb-4fdb9ce0a1ff`），不是 WinRT 接口 IID。
   作为 REFIID 传给 `CreateForWindow` 稳定得到 `E_NOINTERFACE(0x80004002)`。
   改为硬编码 `79C3F95B-31F7-4EC2-A464-632EF5D30760`。
3. **命名冲突**：`Vortice.Direct3D11` 里也有一个同名 `IDirect3DDxgiInterfaceAccess`，
   `using` 会优先解析到它，而 `frame.Surface.As<T>()` 只接受 WinRT 投影接口 →
   `InvalidCastException: Unable to cast 'WinRT.IInspectable' to 'Vortice.Direct3D11.IDirect3DDxgiInterfaceAccess'`。
4. **CsWinRT 未公开该接口**：`Windows.Graphics.DirectX.Direct3D11.IDirect3DDxgiInterfaceAccess`
   不在公开投影里，`GetInterface<T>(out T?)` 内部仍走 `MarshalInspectable`，对 COM 接口必然失败。
   改为从 Surface 的 IInspectable 指针 QI（IID `A9B3D012-3DF2-4EE3-B8D1-8695F457D3C1`）
   再走 `GetInterface` vtable，自己用 `new ID3D11Texture2D(ptr)` 包装。

结果：`capture` 的 `method` 变为 `graphics_capture_live`，画面为 DWM 合成结果，
**与前台窗口彻底解耦**——实测在目标窗口被另一个应用完全遮挡时，仍能截到目标窗口自身画面。

### 新增：持久捕获会话（`LiveCapture` / `LiveCaptureRegistry`）

- 绑定 HWND 建一次会话，独立泵线程持续 `TryGetNextFrame`，**Latest Frame Wins**。
- 读回节流 30fps（DWM 可能推 60fps，每帧 Map staging 纹理纯属浪费）。
- `Snapshot()` 命中新鲜帧时 **0 等待**；只有首帧需要等（≤800ms）。
- 尺寸变化自动 `Recreate` 帧池；空闲 60s 或窗口销毁后自动回收。
- 会话与前台窗口无关：切窗口、遮挡都不影响；最小化时如实报「无合成表面」，不做假截图。
- 降级顺序固定为 持久会话 → 一次性 WGC → PrintWindow，**任何一级都不会退化成截前台窗口**。

### 新增：坐标空间参数 `--coord-space`

```bash
wbcu click --id <sid> --x 960 --y 11 --coord-space window   # 窗口左上角为原点
wbcu click --id <sid> --x 12  --y 40 --coord-space client   # 客户区原点
wbcu click --id <sid> --x 1496 --y 255                      # 默认 screen，向后兼容
```

以前只有屏幕坐标，AI 从目标窗口截图读出的坐标必须自己加窗口原点；
算错就点到屏幕左上角，而命令照样返回 `delivered: true`，极难排查。

### 修复：后台输入优先级

- `ClickAt`：显式 `--allow-global` 时直接用 SendInput，不再被 `PostMessage` 的
  假成功吞掉（该修复先在 0.6.2 本机验证过，本次正式入库）。
- `SetText`：此前收下 `allowGlobal` 却从未使用。现在 UIA `ValuePattern` 不可用时，
  若已显式授权则走 `GlobalInput.TypeText`（SendInput + `KEYEVENTF_UNICODE`，
  不经过输入法，中文可直送）；未授权才退回 `WM_CHAR`。
- **默认仍然不启用全局输入**；`--allow-global` 只在调用方明确授权时生效。

### 验证状态

- 单元测试 65/65。
- 真机（Windows 10 19045 / DPI 100%）：记事本窗口 `graphics_capture_live` 992×624 正常；
  **目标被另一应用完全遮挡时捕获仍返回目标自身画面**（遮挡点实测归属前台应用）；
  连续 5 次 capture 全部命中持久会话（帧龄 16ms，无会话重建）。
- 企业微信：本轮执行期间客户端处于扫码登录态（`WeChatLogin`），
  已登录界面的后台捕获与操作未能复测，见回执。

## [0.6.2] — 2026-11-17

Windows Ghost Cursor 视觉精修。**只改显示层**，后台输入引擎、会话管理、
结果验证口径一律未动；macOS 侧未改动。

### 修复（根因）

- **箭头被画成窗口那么大**：`CursorRaster` 的箭头多边形用 0..1 归一化坐标，
  直接乘位图边长，于是 126px 位图里箭头实际画成 **59×91px**（200% DPI 下 117×183px），
  是标准光标的 2–3 倍。现在箭头几何在自己的 glyph box（20×24 DIP）内计算，
  与承载位图尺寸彻底解耦。
- **描边过粗**：线宽按 `sizePx × 1.4%` 推导（126px → 3.5px 线，200% 下 7px）。
  改为固定 **1.5 DIP**。
- **重影**：叠加了一层向右下偏移 (2.5, 6.9)px 的深色投影，视觉上就是第二个箭头。
  已**移除投影**。
- **遮挡内容**：光晕半径按 `0.42 × sizePx`（直径 106px）+ 深色投影 + 巨大箭头，
  三者叠起来把 126×126 几乎填满。现在光晕 **直径 56 DIP、不透明度 0.22**。
- **热点偏移**：`Present()` 直接把覆盖层左上角放在目标坐标上，
  但箭头尖端在图内还有 (24,24) 的偏移，视觉位置与真实点击位置差 24 DIP。
  现在窗口原点回退 `TipX/TipY × scale`，实测偏差 **0px**（DWM 口径）。
- **DPI 只在启动时算一次**：新增 `SyncDpi()`，每帧轻量比对 `GetDpiForWindow`，
  跨显示器拖动或中途改缩放后按新 scale 重建位图。100%–200% 下箭头逻辑尺寸恒定 20×24 DIP。
- **帧率与动画**：33ms（30fps）→ **16ms（60fps）**；点击反馈 260ms → **120ms**。

### 性能

渲染改为只扫「箭头 bbox ∪ 光晕圆」的包围盒（旧版全图逐像素 + 4×4 超采样）：

| 位图 | 旧 | 新 | 提升 |
|---|---|---|---|
| 126px (100%) | 25.30 ms/帧 | 1.08 ms/帧 | 95.7% |
| 252px (200%) | 96.63 ms/帧 | 4.77 ms/帧 | 95.1% |

旧版在 200% DPI 下每帧 96ms，30fps 的 33ms 预算根本跑不动——这是 ghost 进程
持续高 CPU 的直接原因；新版 4.77ms，60fps 预算（16.7ms）绰绰有余。

### 新增

- `Wbcu.Contract/GhostTokens.cs`：Ghost Cursor 设计令牌（窗口 / 箭头 / 描边 / 光晕 / 动效 / 配色），
  与 `docs/ghost-cursor-tokens.md` 同步，作为 Windows 与 macOS 的共享视觉口径。
- `docs/ghost-cursor-tokens.md`：令牌表 + 跨平台映射说明。

### 修复（测试靶子）

- **`wbcu-testapp-win32.exe` 仍崩**：`TextOutW` 声明在 `user32.dll`（实际 `gdi32.dll`），
  与 0.6.1 修的 `GetStockObject` 是同一类错误。这导致 `wbcu-guitests` 的
  click_uia / click_background / type_background 用例全部 FAIL（靶子没起来），
  以及 click_occluded / click_wm_message 因「拿不到窗口矩形」而 SKIP。

### 验证状态

- 引擎单测 65/65（含 `CursorRaster` 的缓冲尺寸 / 四角全透明 / 有不透明像素 / 预乘断言）。
- 真机（Windows 10 19045）：单实例（多次 move + click 后 overlay 窗口数恒为 1）、
  窗口 126×126、exStyle `LAYERED|TRANSPARENT|NOACTIVATE|TOOLWINDOW|TOPMOST`、
  热点对齐偏差 0px、`frontAppPreserved=true`、`physicalCursorPreserved=true`。
- 视觉截图受限于真机处于锁屏状态（桌面无渲染输出，BitBlt 仅得纯色），
  以渲染层逐像素对比图 + 窗口几何数据作为证据。

## [0.6.1] — 2026-11-17

按 **Windows 10 19045 真机部署回执**修 5 项缺陷。回执结论是「可用」（记事本 UIA 写入 success /
截图正常 / 未抢前台 / 未动鼠标），但暴露了 4 个 bug + 1 个打包缺陷。详见
`docs/receipt-v0.6.0-windows-real-machine.md`。

### 修复

- **ghost / trace 守护进程继承调用方 stdout 导致调用方永久挂起**：新增 `DetachedProcess`
  （三重定向 + 后台读空 + 关 stdin）。`--no-ghost` 不再是必要参数。
  这一条影响面最大：PowerShell 管道、GUI 测试、任何 `ReadToEnd` 都会卡死。
- **`launch` 传绝对路径异常退出（exit -1）**：启动异常全捕获，转结构化错误。
- **`launch --app notepad` 被解析到 Git 的 `usr/bin/notepad`**：候选顺序改为
  用户路径 → System32/SysWOW64 → App Paths → PATH，且每个候选过 `MZ` 头校验。
- **输出编码随控制台代码页（GBK）导致 JSON 解析失败**：启动即设 UTF-8（无 BOM），
  并且结果 JSON 一律 `\uXXXX` 转义为纯 ASCII —— 调用方用什么代码页都能解析。
- **`wbcu-guitests.exe` 空转 335s CPU 零产出**：异步读 stdout/stderr（消除同步读死锁点），
  单命令 90s / 单用例 300s 看门狗，超时杀进程树，每例打印耗时。
- **`wbcu-testapp-win32.exe` 启动即崩**：`GetStockObject` 从 `user32.dll` 改为 `gdi32.dll`。

### 文档

- 新增 `docs/receipt-v0.6.0-windows-real-machine.md`：回执原文要点 + 逐条修复映射 + 重跑步骤。
- `docs/windows-installation.md` 补充：GitHub 直连不通时的 `WBCU_LOCAL_ZIP` 离线路径；
  引擎只需 .NET Core 运行时、`testapps` 才需要 Desktop 运行时。

### 验证状态

- 引擎单测 65/65；macOS `selftest 53/53`；契约 `PARITY OK`。
- Windows GUI 套件仍未跑绿（回执里那次是空转，已修），`capabilities` 相关项保持 `not_tested`。


## [0.6.0] — 2026-11-16

**macOS 引擎保持 v0.5.x 的成熟行为（仅新增 `contract` 命令），新增 Windows 原生引擎，
两者共享同一份跨平台契约与同一个技能。**

这是「磨刀阶段」的跨平台第一步：不是把 Swift 翻成 C#，而是**为 Windows 重写执行层、
共用语义层**。定位仍然是 WorkBuddy 的第三只手——不加审批、不加阻塞、不做前台守卫。

### 新增：跨平台契约（`contract/`）

- `wbcu contract --json` / `wbcu.exe contract --json` 输出同一份可执行契约：
  11 个统一动作、17 个错误码、验证四分类、6 种匹配模式、15 个能力键、选择器语法、6 条不可违反的纪律。
- `./scripts/check-contract-parity.sh` 逐字对比两侧 → 当前 `PARITY OK`。
- 结果信封统一：`ok / action / platform / engine / method / delivered / verified /
  verification / failureReason / errorCode / frontAppPreserved / physicalCursorPreserved /
  elapsedMs / data / warnings`。

### 新增：Windows 引擎（`src-windows/`，wbcu.exe）

| 模块 | 实现 | 说明 |
|---|---|---|
| 窗口/应用发现 | `EnumWindows` + `DwmGetWindowAttribute` + 包族/AUMID | 用 extended frame bounds 避免 Win10 隐形边框导致坐标偏移 |
| 捕获 | Windows.Graphics.Capture（D3D11 读回）+ PrintWindow 兜底 | 最小化/DRM 内容如实报失败，不假装截到黑图 |
| UIA | `Interop.UIAutomationClient`（官方 COM 互操作）+ 专用 MTA 线程 | **不手写 vtable**；超时抛 `timeout`，不挂死调用方 |
| 定向输入 | UIA Pattern → `SendMessageTimeout`（最深子窗口）→ 显式 `SendInput` | 三级阶梯，失败说清卡在哪一级 |
| Ghost Cursor | 独立进程 + `WS_EX_LAYERED` + `UpdateLayeredWindow` | NOACTIVATE/TRANSPARENT/TOOLWINDOW，点击穿透、跟随窗口、被遮挡变淡 |
| 会话 | JSON 持久化 + HWND/PID 校验 | 句柄被复用 → `session_stale`，不拿死句柄硬点 |
| 验证 | UIA 状态读数 + 树指纹 + 「值出现在别处」兜底 | 四分类与 macOS 同判据 |
| 经验 | 只存 AutomationId/路径/名称 | 坐标与 HWND 不进长期库 |
| 追踪 | `SetWinEventHook(EVENT_SYSTEM_FOREGROUND)` | 命令时间窗归因，区分 wbcu / user / external |

### 新增：Windows 测试与构建

- `Wbcu.Tests`：65 个纯逻辑单测（契约/验证四分类/选择器/归一化/几何/光标光栅/PNG/经验），
  **在 macOS 与 CI 上均通过**。
- `Wbcu.TestApp`（WPF，纯代码）与 `Wbcu.TestApp.Win32`（原生控件 + 自绘画布）作为受控目标。
- `Wbcu.GuiTests`：交互式验收套件（UIA 点击 / 后台点击 / 遮挡点击 / 消息投递 / 后台输入 /
  用户并发 / 覆盖层 / 最小化 / 多屏 DPI），**只能在有交互桌面的 Windows 上跑**。
- `build.ps1` / `install.ps1` / `uninstall.ps1` / `scripts/pack-windows.sh`；
  安装脚本**探测**技能目录而不是假设 `~/.workbuddy` 在 Windows 上等价。
- CI 新增 `windows-build-and-unit-test`：编译 + 单测 + 发布 win-x64；
  GUI 验收明确**不在 CI 跑**（`gui-acceptance-note` 说明原因）。

### 修正

- `docs/windows-feasibility.md` 的「Windows 不可用」结论标注为**已被取代**：
  结论对「复用 Swift 二进制」仍然成立，但不等于「没有 Windows 版」。
- 技能升级为双平台单一技能（`version: 0.6.0`），新增平台检测、能力差异表、Windows 专属边界。

### 未验证（不要当成已支持）

真机 GUI 验收（Calculator / 记事本 / 资源管理器、遮挡、并发用户输入、多屏混合 DPI）、
Graphics Capture 实际取帧质量、Windows on ARM64。
这些在 `wbcu.exe capabilities --json` 里显示为 `not_tested`，直到 `wbcu-guitests.exe` 在本机全绿。


## [0.5.2] — 2026-11-16

只有一件事：**把「Windows 能不能用」这个问题回答清楚，并写进技能里**。
代码逻辑零改动，版本号递增是为了让「引擎 == 技能」这条不变量继续成立。

### 结论：Windows 不可用，且不是编译问题

证据（`docs/windows-feasibility.md` 有完整表）：

| 检查 | 结果 |
|---|---|
| 二进制格式 | `Mach-O 64-bit arm64`，Windows 只认 PE |
| 框架依赖 | AppKit 20 文件 / CoreGraphics 15 / ApplicationServices 10 / ScreenCaptureKit 3，全是 macOS 独占 |
| 工具链 | 本机只有 `MacOSX*.sdk`，无 Windows 目标 |
| Windows 代码 | `user32` / `SendInput` / `UIAutomation` 命中 0 处；仓库无 `.exe`/`.dll` |

移植量级：7777 行里，可复用的是「验证逻辑 + CLI 壳 + 测试方法」约 25–30%，
其余 5000+ 行平台绑定要在 Windows 上重写 —— 那是独立引擎，不是补丁。

### Windows 用户的正确路径

1. WorkBuddy 产品自带 Computer Use（`requireFlags` 含 `macOrWindowsPlatform`，官方支持 Windows）
2. 本地方案：PowerShell + UIAutomation / pywinauto / AutoHotkey
3. 真要 Third Hand 的 Windows 版 → 按 `docs/windows-feasibility.md` 方案 C 重写，先做 UIA spike

### 顺带

- SKILL.md 顶部加平台声明（避免别人拿到包以为是跨平台的）
- 分发包 README 同步说明（`dist-src/README.md`）


## [0.5.1] — 2026-11-16

对 v0.5.0 的一处**事实性纠错**加两项工程补强。不改底层引擎、不新增任何阻塞。

### 一、更正：Browser Use 其实可用（v0.5.0 的结论是错的）

v0.5.0 我写「本构建没有浏览器交互接口」，依据是 `app.asar` 里搜不到 `browser_*`。
**那个判断错了**，因为我只查了主 bundle 字符串，没查插件缓存、CLI 和技能注册表。

事实（WorkBuddy 5.11.3，本机实测）：

| 通道 | 状态 | 说明 |
|---|---|---|
| `agent-browser` CLI（Vercel agent-browser 0.27.0 + 官方插件 1.3.0） | ✅ **已装、已跑通** | `~/.workbuddy/binaries/node/versions/22.22.2-6/bin/agent-browser` |
| 产品「浏览器操控」`workbuddy-browser-use` | ⚠️ 产品支持，本机**未启用** | 设置 → 智能体 → 浏览器操控 → 安装扩展 |

实测链路：`open` → `fill` → `click` → **`get text` 读回 JS 计算结果** → `scroll`（scrollY=400）
→ `screenshot`（6.7K PNG）→ `close`，全部通过；**全过程零次前台切换**。

完整证据与调用方式见 [`docs/browser-use.md`](docs/browser-use.md)（该文件已重写并标注自我推翻）。

### 二、`wbcu doctor`：引擎/技能版本一致性自检

起因是 v0.5.0 的真实事故：`install.sh` 默认只装二进制，技能要显式 `--skill`，
结果二进制 0.5.0、SKILL.md 还是 0.4.2（177 行），技能里教着不存在的 `wbcu launch`。

`wbcu doctor` 现在一次列出 10 项：

```
engine_version / skill_file / version_match / skill_commands / skill_stale_claims /
installed_binary / overlay / smoke / git / skill_lines / session_gc
```

- 技能新增 `version:` 字段，与二进制版本严格比对
- 扫描技能正文里所有 `wbcu <cmd>`，和编译期命令白名单交叉核对（白名单与 `main.swift` 的
  switch 由单元测试保证一致，42 条）
- 已安装副本不在 git 仓库内时**跳过** git 锚点检查，不误报
- 有 `fail` 项退出码 1，`warn` 项只提示不阻断

### 三、`install.sh` 默认装技能 + 装完自检

- 默认 `--skill`（新增 `--no-skill` 才跳过）—— 从根上消掉「二进制新、技能旧」
- 安装结束自动跑 `wbcu doctor`；不一致只打提示，**不阻断安装**

### 四、修掉一个「假装成功」：`ghost stop` 并没有真的停掉进程

回归时发现：`ghost stop` 打印「✅ 已停止」，但 `pgrep` 还能看到 daemon 在跑
（实测 pid 52987，SIGTERM 都没被处理）。原因：旧实现发完 `quit` 就删 socket，
**无条件**报成功，从不确认进程是否退出。

现在改成可验证的停止：

1. daemon 启动时写 `~/.wbcu/ghost.pid`，并注册 SIGTERM 处理器
2. `stop` 先 quit → 等 1.5s → 仍活着就 SIGTERM → 再不行 SIGKILL
3. 最后用 `kill(pid, 0)` 复核，退出码如实反映结果（失败 exit 1）

实测：历史遗留 daemon（无 pid 文件，靠 `pgrep` 兜底找到）→ `SIGTERM` 后退出；
新 daemon → 干净 quit，无升级。

### 五、会话垃圾清理

实测一周堆了 15 个会话文件（全指向已关闭的窗口）。新增：

- `wbcu session prune [--max-age 秒] [--dry-run]`：目标是死的或超过 24h 就删
- `session start` 时若会话文件 > 20 个，顺手清一次（只读目录计数，不扫内容）

### 六、Skill 修正

- 浏览器章节从「本构建没有该接口」改为「`agent-browser` 可用 + 调用示例 + 实测数据」
- 加一条硬规则：**网页有 DOM 就用 DOM，不要用 wbcu 坐标点击去点网页**
- 保留原红线与所有 v0.5.0 性能能力（launch / 会话复用 / identifier / 快速验证 / trace）

### 七、测试

- 新增 `tests/regression/version-consistency.sh`：7 项断言，含**人为制造版本漂移**验证 doctor 能抓到
- `tests/unit/run.sh` 新增：doctor 命令白名单与 `main.swift` switch 必须完全一致
- 7 套 GUI 回归 + `selftest 53/53` 保持通过


## [0.5.0] — 2026-11-12

能力打磨阶段。不新增任何阻塞、审批或门禁；只做四件事：**少抢前台、少重复初始化、点得更准、把证据留下来**。

### 一、被动激活追踪（`wbcu trace`）

在回答「谁抢了前台」之前，先要有证据。新增追踪器：

- 监听 `NSWorkspace.didActivateApplicationNotification`，事件驱动、零轮询（轮询版实测被系统节流到 16.8s 一次，切换全丢）
- 每条 wbcu 命令写一对开始/结束时间戳（`atexit` 补 t1），**只在命令真正运行的那段时间内**归因
- 三分类 + 一类：`user`（400ms 内有真实硬件输入）/ `wbcu`（落在命令运行窗口内）/ `external`（都不是）/ `harness`（测试脚手架自己登记）
- `wbcu trace mark --note "..."` 让测试脚手架主动登记，避免把自己的切换算成引擎的锅

**归因窗口的一个坑**：早期用「命令开始后 1.5s 内」归因，结果脚本自己的 `osascript activate`
被算成「wbcu 抢前台」。现在窗口是 `[t0-50ms, t1]`，命令结束后 500ms 内的变化只标
「紧随其后」不做归因。

### 二、`wbcu launch`：后台启动，不抢前台

Agent 最自然的动作是 `open -a Calculator`——那条命令**必然**把目标顶到最前。
新增的 `launch` 用 `NSWorkspace.OpenConfiguration.activates = false`：

| 行为 | `open -a` | `wbcu launch` |
|---|---|---|
| 应用未运行 | 启动并**激活** | 启动，`activated=false` |
| 应用已在运行 | **重新激活到前台** | 直接返回，不激活 |
| 实测前台变化 | 1 次 | **0 次** |

### 三、会话复用：一个任务 = 一个会话

`session start` 命中同 App 的活会话时直接复用（`reused=true`），不再重算整树指纹、
不再重拉 ghost daemon。实测 `session start` 190ms → **94ms**。

同时支持 `--app` 直接寻址：`session click --app com.apple.calculator --identifier One`
不需要记 session id —— 「忘了 id → 重新 start → 重新拉窗口」这条链路从结构上消失。

ghost daemon 拉起改为非阻塞预热（`waitForReady: false`），会话建立不再等可视化组件。

### 四、点得更准：`--identifier` 与期望状态的两个修正

- **`session click --identifier <AXIdentifier>`**：按稳定标识点。
  但实测有个反例——计算器的清除键**连 identifier 都会随状态变**（干净状态 `AllClear`、
  有输入后 `Clear`），所以「identifier 一定稳定」这个假设不成立，测试里两个都试。
- **期望元素选择器支持下标**：`role:AXStaticText[1]`。
- **按值搜索兜底**：主显示元素不匹配时，再在窗口里按值搜一次。
  原因：计算器按下等号后，结果 `1,000` 出现在**新出现的第二个** AXStaticText 上，
  而主元素仍是表达式行 `125×8`。旧实现死等主元素路径，白等 600ms 还判 failure。
  现在三段式：先读（多数一帧内更新）→ 最多 120ms 等主元素命中（一发现「变了但不对」立刻跳出）
  → 按值搜索 → 才用满 `maxWaitMs`。计算器等号那步 **739.9ms → 282.6ms**。

### 五、Browser Use 协同：查清边界，不做假接口

调查报告见 [`docs/browser-use.md`](docs/browser-use.md)。结论：

- 本构建**没有**向 Agent 暴露浏览器自动化工具（无 `browser_*`、无插件、无扩展包）
- 可用的是 `present_files`（内置右侧面板，只渲染不交互）、`WebFetch` / `WebSearch`（只读）
- 因此 **不得用坐标点击冒充网页交互**；需要网页交互时如实报告能力缺失

Skill 里写死了路由：网页读取 → `WebFetch`；展示 → `present_files`；原生应用 → Third Hand；
混合任务各自做自己那段，互不代理。

### 七、测试

新增 `tests/regression/no-reactivation.sh`（13 项断言，全部实跑）：

```
✅ 后台启动成功且未激活（activated=false）
✅ 启动后前台未变（WorkBuddy）
✅ 已在运行时 launch 不重复启动、不激活（alreadyRunning=true）
✅ 同一 App 复用同一会话（s48416），没有重复初始化
✅ harness 切换确实改变了前台（WorkBuddy → Safari浏览器）
✅ 7/7 步验证通过（含结果行与表达式行分离的那一步）
✅ 最终读数为 1,000
✅ 计算全程前台停在用户的应用（Safari浏览器）
✅ 0 次前台变化归因于 wbcu 命令
✅ 0 次未登记的外部 activate
✅ ghost 进程已清理
```

7 套 GUI 回归 + `selftest 53/53` 全部保持通过。

### 七、明确的「没做」

- 没有新增审批、确认、前台状态守卫
- 没有改 Browser Use（也没有可改的接口）
- 没有把 Third Hand 做成拦截层：`act` / `session click` 路径里没有任何 `activate` 调用


## [0.4.3] — 2026-11-12

严格意义上的可靠性审计。v0.4.2 证明了「能在后台点中」，这一版回答的是
**「怎么证明点对了」「用户在用电脑时还成不成立」「判定本身有没有漏」**。

### 一、P0：ExpectedStateVerifier —— 「变了」不等于「做对了」

v0.4.2 的判据是「AX 指纹有没有变」。这条判据抓得住「没反应」，但抓不住
「反应了但反应错了」，也会冤枉幂等操作（「全部清除」再点一次本来就没变化）。

现在一次操作会被拆成五段可审计事实，并给出四分类结论：

| 结论 | 含义 | 置信度 |
|---|---|---|
| `success` | 确认产生了预期结果 | .95（有显式期望）/ .75（仅指纹变化） |
| `already_satisfied` | 操作前就已满足期望（幂等） | .60 |
| `failure` | 实际结果与期望不一致 | .95 |
| `inconclusive` | 证据不足 | .30 |

用法：`wbcu session click --text 7 --expect 7 --expect-el role:AXStaticText`

实测（计算器）：

- 干净状态点 7 → 显示 7 → `success`
- 点 8 但期望 7 → 显示 8 → `failure`，并标注「目标被错误点击或产生了意外结果」
- 幂等「全部清除」且显示本来就是 0 → `already_satisfied`，且 `clickConsumed=unproven`
  （**不声称点击被消费** —— 这一点我们只能证明最终状态，证明不了副作用）

顺带修掉一个真问题：计算器的显示值是 `‎7,778` —— 带 U+200E（LRM）与千分位逗号。
逐字符比较会把「正确」判成 failure。新增值规范化（去格式类字符、去千分位），
`--match strict` 可退回逐字节比较。

**无变化不再一律算失败**：没有显式期望且没有可观测变化时给 `inconclusive`，
要求调用方要么给期望、要么接受「不知道」。

### 二、P0：真实用户并发交互测试（`tests/concurrency/`）

不是「前台没变」那种弱断言。三件事：

1. `ActivityProbe` 用 listen-only 事件 tap 记录用户真实输入（鼠标/键盘/滚动）时间线，
   同时 100ms 采样前台应用与鼠标位置
2. Third Hand 在同一时段后台连续操作目标，每次带显式期望
3. 事后做**责任归因**：每次前台变化，若前 0.4s 内有用户输入 → 归因 user，
   否则 → 归因 agent；脚本自己发起的切前台登记为 `harness`，不算任何一方

实测（两次完整运行）：

| 场景 | 用户输入事件 | Agent 动作 | 前台变化归因 | 结果 |
|---|---|---|---|---|
| 默认（AX 优先） | 968 条 | 8/8 success | 用户 0 / Agent 0 | 通过 |
| 强制坐标投递 + 中途切前台 | 977 条 | 8/8 success | 用户 1 / 脚本 2 / Agent 0 | 通过 |

同时断言：0 条合成事件进入会话事件流（说明投递确实走 `postToPid` 而不是全局 HID 注入）、
目标窗口 ID 全程不变、目标 keyWindow/第一响应者不变。

**归属不明的处理**：动作窗口内检测到真实硬件输入时，`frontAppPreserved` /
`physicalCursorPreserved` 记为 `null` 而不是 `false`。
「用户自己在动鼠标」不该被算成「Agent 动了鼠标」，也不该被算成「Agent 没有动鼠标」。

### 三、P1：遮挡判定漏判（`Visibility.swift`）

旧规则 `layer == target.layer && alpha > 0.02` 漏掉了**高层级浮层**：
NSPanel（.floating=3）、Popover、Tooltip 压在目标上时直接被忽略，于是报告「可见」。

改为按**窗口列表的真实前后次序**判断：只要排在目标之前就算候选遮挡者。

同时处理两个相反方向的坑：

- **系统外壳窗口**：Dock 在窗口列表里报的是 `1470×956` 全屏 bounds（那是透明命中区，
  不是绘制区）。按矩形算会把所有窗口判成完全遮挡。这类窗口标记 `suspectedShell`，
  不参与面积计算，但在报告里列出。
- **自己的光标**：Cursor Overlay 永远不算遮挡者，否则光标一显示就自我遮挡。

新增 `wbcu occlusion --window <id>`：把完整前后次序（z 序、owner、layer、alpha、bounds、
谁压着谁）直接打出来，供第三方复核判定，不用读源码。

新增回归 `occlusion-layers.sh`：layer=3 / layer=8 / 部分遮挡 / 同应用第二窗口 / 遮挡下光标抑制但点击仍生效，
连跑两次稳定通过（部分遮挡实测可见比例 0.467）。

### 四、P1：多显示器坐标（`DisplayGeometry.swift`）

v0.4.2 的问题不是翻转公式错，而是**把所有点都当成在主屏上**：
Ghost 用 `NSScreen.screens.first` 取尺寸再夹取，副屏（尤其负 X 的左屏）会被夹回主屏 ——
画的位置和点的位置不是同一处。

新增 `DisplayCoordinateTransformer`，显式区分四个坐标空间：
CG 全局 / AppKit 屏幕 / 窗口局部 / 捕获像素。要点：

- **点**的翻转是全局的：`appkitY = primaryHeight − cgY`，与目标在哪块屏无关
- **矩形**的翻转是逐边的：`appkitRect.y = primaryHeight − cgRect.maxY`
- **选哪块屏**是局部的：必须按点所在 CG 矩形选，不能默认主屏

Ghost 定位改为「按点选屏 + 该屏内夹取」。15 项纯函数自检覆盖：单屏 Retina、
右副屏、左副屏负 X、上方副屏负 Y、混合缩放、跨屏窗口、捕获像素往返、scale=0。

> 硬件限制：本机只有一块内建屏（1470×956 @2x）。**多显示器真机场景标记 Not Tested**，
> 只验证了数学与选屏逻辑，不宣称真机通过。

### 五、P1：未文档化事件字段隔离（`LegacyFields.swift`）

51/58/91/92 与 `CGEventSetWindowLocation` 全部收敛到 `EventFieldCompat`：

- 版本闸门：只在被矩阵验证过的大版本（14/15/26）上默认启用坐标投递；
  未知大版本 → AX 优先，除非该应用在本机被证明过 ≥2 次成功
- 逐应用退让：连续 3 次「投递后验证失败」→ 该应用降级为 AX 优先，
  状态落盘 `~/.wbcu/compat.json`，`wbcu compat --reset` 可复位
- 字段 58 的取值 `12345` 明确标注「语义未确认」，注释里不推断系统行为
- 不再宣称「Codex 用相同字段」——我们没有证据

### 六、性能（没有为了可靠性变慢）

| 指标 | v0.4.0 记录 | v0.4.3 实测 |
|---|---|---|
| 计算器 P50 | 108 ms | **73.9 ms** |
| 计算器 P95 | 124 ms | **85.4 ms** |
| 可见性判定 P50 | — | 0.7–1.1 ms |
| 状态验证 P50 | — | 2.3 ms |
| Ghost daemon 空闲 CPU / RSS | — | 0.4% / 33 MB |

三个优化，都是「别把不属于输入的成本算进输入」：

- 焦点取证由「每次点击都做」改为按需（`--focus-check`），省 54 ms/次
  （一次 AX IPC 实测约 27 ms）
- 有显式期望时跳过整树指纹，改用状态元素前后读数，省 60~90 ms
- 光标按下反馈（socket 往返 50~70 ms）移出 `dispatch` 计时

受控夹具上 P50 167.7 ms，其中 101 ms 是夹具自己的 `AXPress` 同步处理时间，与引擎无关；
真实应用（计算器）`dispatch` 仅 2.1 ms。

### 七、真实应用矩阵

| 应用 | AXPress | 坐标投递 | 期望状态验证 | 限制 |
|---|---|---|---|---|
| Calculator | 通过 | 通过 | success/failure 均正确 | 清除键标签随输入状态在「全部清除/C」间切换；显示值含 LRM 与千分位 |
| TextEdit | n/a（文本） | 未测 | 通过（AXValue 往返） | 后台按键需 field editor，写入走 AXValue |
| Finder | 未测 | 未测 | 未测 | 侧边栏/工具栏无稳定标识，需人工指定目标（只读能力已验证：AX 树 863 节点） |
| Safari | 未测 | 未测 | 未测 | 会操作用户正在使用的浏览会话与登录态，需单独授权 |
| Electron | 未测 | 未测 | 未测 | 本机无安全可驱动的实例 |

### 八、测试

- `selftest`：**53/53**（新增 15 项坐标空间 + 11 项期望状态验证）
- 6 条 GUI 回归全部实跑通过：`cursor-window-bounds`、`background-targeted-click`、
  `window-switch-isolation`、`occlusion-behavior`、`occlusion-layers`、`ghost-cleanup`
- 并发交互 2 场景通过（见上表）
- 应用矩阵 3 个应用，未测项明确标注


## [0.4.2] — 2026-11-12

两件事：把虚拟光标从「整屏透明面板」改成「跟随目标窗口的小窗口」，
以及把「投递了」和「做成了」彻底拆开。

### 症状（用户原话）

> 我能看到虚拟鼠标在我前台窗口飞来飞去。
> 我切换窗口还会影响你点击，这没道理。

### 一、虚拟光标：整屏面板 → 126×126 跟随小窗口

**根因**（v0.4.1 实际代码）：

```swift
panel = GhostPanel(contentRect: screen.frame, ...)   // Ghost.swift:212
view  = GhostView(frame: screen.frame)               // Ghost.swift:226
```

`screen.frame` —— 面板和画布都是整屏。透明并不等于「用户感知不到」：
它是用户前台窗口上方一整块全屏窗口，任何窗口级合成、录屏、窗口列表都能看到它，
而且光标一动，整块区域都要重绘。

**修法**：

- 面板与画布统一改为 `GHOST_WIN_SIZE = 126`（对齐 Codex `Software Cursor` 实测 126×126）
- 视图改为 flipped（左上原点、y 向下），和 CGEvent 全局坐标同一套方向，不再翻 y
- 每帧按「全局点 − 尖端内偏移」移动小窗，并夹在屏幕内；尖端由**实际窗口原点**反推，
  所以贴边时指向的仍是真实像素
- 标签超出小窗就截断，不做无边界扩张

**但小窗本身不解决遮挡**：目标被你的窗口盖住时，小窗照样会把光标画到你窗口上面。
所以同时加了下面这条。

### 二、新增 `TargetWindowVisibilityManager`

`src/InputDispatcher/Visibility.swift`。动手之前先回答「这个点现在还归目标窗口吗」：

- 一次 `CGWindowListCopyWindowInfo(.optionOnScreenOnly)`（前→后顺序），O(n)
- 只把「同层级、alpha > 0.02」的窗口算遮挡者（菜单栏 / Dock 的 layer≠0，不参与）
- 15×15 采样网格估算可见比例（0~1），命中点单独判定是否被盖住
- 输出状态：`front` / `background` / `partially_occluded` / `fully_occluded` / `minimized` / `off_screen`
- 明确**不**做三件事：不 `AXRaise`、不激活 App、不切 Space —— 判定只用于降级与如实上报

开销实测：`visibilityMs` P50 **0.6 ms**，首次调用 14 ms（窗口列表冷启动）。不引入后台扫描线程。

### 三、投递结果结构化：禁止「静默成功」

`ActionOutcome` 新增 `ok / delivered / failureReason / visibility / frontAppPreserved / physicalCursorPreserved`。

- `delivered` = 事件真的进了目标进程
- `verified` = 目标 UI 真的变了（`uiChanged`）
- `ok` = 最终裁决；`verified=false` 时 `ok=false`，并带原因：
  `target_minimized` / `target_off_screen` / `target_window_gone` /
  `ax_press_no_observable_change` / `targeted_window_not_key_no_effect` /
  `targeted_background_no_effect` / `targeted_no_observable_change`
- `wbcu act` / `session click` 失败时退出码改为 **3**，脚本层无法把失败当成功

### 四、重要更正：v0.4.1 的「遮挡下 targeted 静默失败」结论不成立

v0.4.1 交接回执里写着「targeted 坐标投递在目标非前台时静默失败（verify=no_observable_change）」。
v0.4.2 用受控 AppKit 夹具（NSButton / 自绘 CanvasView / WKWebView 按钮）重测 9 种组合，
**没有复现该失败**：

| 用例 | 状态 | 投递方式 | UI 真的变了 |
|---|---|---|---|
| E1 | 前台 | 字段51+58+窗口局部坐标 | ✅ |
| E2 | 后台不遮挡 | 同上 | ✅ |
| E3 | 后台且完全遮挡 | 同上 | ✅ |
| E4 | 后台且完全遮挡 | AXPress | ✅ |
| E5 | 后台不遮挡 · 自绘 Canvas | 坐标投递 | ✅ |
| E6 | 被遮挡 + AX 设 main/focused | 坐标投递 | ✅ |
| E7 | 被遮挡 · 自绘 Canvas | 坐标投递 | ✅ |
| E8 | 被遮挡 · WKWebView 按钮 | 坐标投递 | ✅ |
| E9 | 被遮挡 · WKWebView 按钮 | AXPress | ❌（无 AXPress，-25206） |

追查下来，v0.4.1 那条结论最可能的来源是**测量误差**，而不是引擎缺陷：

- 判据用了「清空后仍为 0」这类**不产生可观测变化**的操作
- 点的是 `WKWebView` 视图中心，而按钮在左上角 120×32 —— 点到的是 body 空白处

本轮把夹具改成用 JS 读 `getBoundingClientRect()` 发布按钮真实矩形后，同一个 WebKit 按钮
在前台、后台、完全遮挡三种状态下**全部点中**。

真机复验（系统计算器，非夹具）：按经验库 `relRect` 反算出「7」按钮全局坐标 `(654,511)`，
强制 `--mode targeted`：

- 前台 → `verify=changed`，显示变 `7`
- 后台 + 被完全遮挡 → `verify=changed`，显示变 `77`，`cursor.suppressed=true`

而 v0.4.1 交接回执里那条「静默失败」用的是 `--x 88 --y 157` —— 那不是「7」按钮的位置。
**结论：那次失败是点错了坐标，不是引擎投不进去。**

保留的结论只有一条：**坐标投递对遮挡免疫**（事件直接进目标进程队列，由字段 51 决定落到哪个窗口），
而 `AXPress` 并非所有元素都有，两者必须并存、以「UI 是否真的变了」为唯一判据。

### 五、顺手修掉的

- `tests/regression/no-focus-steal.sh` 里两处未定义变量（`$FINAL` / `$MISMATCH`），
  在 `set -u` 下会中途崩掉，导致这条回归之前是「看起来通过」而不是真通过
- `osascript set miniaturized` 对未声明脚本支持的 App 直接 `-10006`，
  最小化场景改由夹具自己的控制通道执行，避免造出「以为最小化了」的假状态

### 六、新增回归测试（5 条，全部需要真实桌面）

| 测试 | 断言 |
|---|---|
| `cursor-window-bounds.sh` | 窗口 126×126；尖端落在窗口内；贴边夹屏；hide 与空闲自动隐藏 |
| `background-targeted-click.sh` | 后台点击 UI 真变；前台/物理鼠标不被动；最小化时如实失败 |
| `window-switch-isolation.sh` | 点击途中切窗口仍命中；前台始终是用户应用；光标不漂移 |
| `occlusion-behavior.sh` | 遮挡判定正确；光标整窗隐藏；禁止 `ok=true` + `uiChanged=false` |
| `ghost-cleanup.sh` | stop 后 socket/进程/窗口全部清干净 |

在 0.4.2 发布前，这 5 条 + 单元 27 项 + `no-focus-steal` 全部实跑通过（见 `docs/receipt-v0.4.2.md`）。

## [0.4.1] — 2026-11-11

修复「虚拟光标 daemon 启动时抢走用户前台」——这是用户实际感受到的问题。

### 症状

启动 `wbcu ghost start`（或任何会自动拉起 daemon 的操作）后，
用户的前台应用从原来的 App 变成 `wbcu`。计算器、WorkBuddy 等被瞬间顶掉。

### 根因

daemon 是个 `NSApplication`，被当作普通可激活进程拉起。
它调 `app.run()` 完成启动流程时会被系统激活，前台就变了。

排查过程中排除的三个思路（都实测过，无效）：

| 尝试 | 结果 |
|---|---|
| `setActivationPolicy(.prohibited)` | 不抢前台，但窗口画不出来（紫色像素恒为 0） |
| `NSApp.deactivate()` | 抢到的激活不会还回去 |
| CLI 侧记录前台、启动后 `activate` 还原 | 时机太早，被 daemon 随后的激活覆盖；还原偏差还会把焦点还给错的应用 |

### 修法

把 daemon 打进 **`LSUIElement` 的 helper bundle**（`ThirdHandOverlay.app`），
以代理型 App 身份运行：能渲染窗口，但**从根上不参与应用激活**，也就没有可抢的焦点。
`scripts/build.sh` 自动产出该 bundle，`install.sh` 一并安装；找不到 bundle 时回退到原二进制。

### 新增

- `tests/regression/no-focus-steal.sh`：盯死「daemon 启动 / 连续点击 / 收尾」三个阶段的前台变化，
  并带 `idle` 干扰判定（期间有人操作则不做结论，避免把用户的切换算成引擎的锅）
- 单元测试新增 lint：shell 脚本里 `$VAR` 紧贴中文必须写成 `${VAR}`
  （这个坑连续踩了两次，一次 `unbound variable` 让整段测试挂掉）


## [0.4.0] — 2026-11-11

Third Hand 2.0：把固定等待换成测量驱动的优化，并加入应用经验记忆。

### 性能（实测，同一机器同一套动作）

| 版本 | P50 | P95 |
|---|---|---|
| 0.3.0 | 995 ms | 1019 ms |
| 0.4.0 | **108 ms** | **124 ms** |

- 去掉每步 ~700ms 的固定 `usleep`（260 动画 + 200 + 240）
- 光标动画与输入投递解耦：`--ghost-mode fast|normal|demo`，视觉不再阻塞执行
- 验证从「前后各扫一次整树」改为「单次扫描 + 会话基线指纹」

### 新增
- `ThirdHandAppExperienceMemory`（`src/SessionManager/Experience.swift`）
  - 按 bundleId 索引，记录 AX 路径、身份特征、归一化位置、成功/失败计数、中位延迟
  - 生命周期 candidate → verified → stable；失败会降级乃至删除
  - schema 版本化，不匹配时先备份再重建
- `ThirdHandEventDrivenVerifier`（`src/InputDispatcher/Verify.swift`）
  - AXObserver + 轻量轮询双通道等待元素变化
  - 实现保留，**默认关闭**：实测在 Calculator 上为负收益（观测元素选择不可靠，
    超时 400ms 远大于单次指纹的 10ms），用 `--observe-watch` 显式开启
- `wbcu experience list|stats|clear`、`wbcu bench`、`wbcu perf stats|reset`
- `wbcu bench` 内置干扰检测：用 `idle` 判断期间有无人操作，有则标记结论不可用
- `docs/experience-memory.md`：经验格式、匹配优先级、失效机制、隐私边界

### 修正
- `detectChangedPath`（学「该盯哪个元素」）原先按路径索引对比两棵树，
  节点数一变索引整体错位导致全树判定变化，学出垃圾路径 `[0,0,0,0,0,0,0]`；
  改为按元素身份（role+identifier+title+desc）匹配
- 经验查找在命中路径上被调用两次（一次用于命中、一次查观测失败计数），
  导致命中反而比未命中慢；改为仅在启用事件驱动时才查
- 「观测超时一次就摘掉观测目标」会误杀幂等操作（如重复点「全部清除」），
  改为连续 3 次失败才摘


## [0.3.0] — 2026-11-10

产品身份从通用的「macOS Background Computer Use」定为 **WorkBuddy Third Hand**
（WorkBuddy 的第三只手）。不破坏已有调用接口与 Git 历史。

### 变更
- **产品定位**：README 全面重写——明确「WorkBuddy 负责思考和决策，Third Hand 负责观察、执行和验证」，
  强调 Third Hand 是 WorkBuddy 的技能与执行引擎，**不是独立 AI Agent**
- **技能改名**：`skills/macos-background-computer-use/` → `skills/workbuddy-third-hand/`，
  `SKILL.md` 的 `name` 同步为 `workbuddy-third-hand`；`install.sh --skill` 会自动移除旧名字目录，避免两个技能描述同一引擎
- **引擎标识**：`wbcu capabilities` 新增 `product` / `component` 字段（只增不改，向后兼容）
- 版本号 0.2.0 → 0.3.0（产品身份与技能 id 变更属公开接口变化）

### 保持不动（避免破坏调用方）
- 仓库 slug 仍为 `macos-background-computer-use`（旧链接、克隆、脚本引用不受影响）
- 二进制名仍为 `wbcu`，命令行参数、MCP 工具名 `cu_*` 全部不变
- ScreenCaptureKit 捕获、Input Dispatcher 投递、Ghost Cursor 一行未改

### 新增
- `docs/images/demo.gif`：**实际运行录屏**合成的演示（`scripts/record-demo.sh` 抓帧 +
  `scripts/make-demo-gif.py` 合成），字幕条显示同一次运行的真实鼠标坐标与验证结果
- `scripts/record-demo.sh` / `scripts/make-demo-gif.py`：录屏与合成脚本，可复现
- README 补充 Skill 安装路径、MCP 配置片段、`cu_session` 调用示例

### 修正
- README 旧版遗留的事实错误：占位用户名、许可证「待定」（实为 MIT）、
  Roadmap 全部未勾选（实际 Phase 1 已全部完成）
- Roadmap 按真实测试结果逐项勾选，未验证的一律留空

### 文档
- README 重写：补齐真实克隆地址、可复制执行的安装/首次验证命令、实测兼容性表格与分层测试说明；
  修正光标实现描述（NSView + Timer，非 Core Animation）；架构图改为反映真实分层
- 技能补齐 `examples/quickstart.md`（六步最小流程 + 错误码对照 + idle 判据）


## [0.2.0] — 2026-11-10

首个可复用版本。把此前分散的验证脚本收敛成引擎 + 会话层 + 技能。

### 新增
- `session` 会话层：`start / list / state / capture / inspect / click / type / key / cursor / verify / end`
  - 会话状态落盘 `~/.wbcu/sessions/<id>.json`，命令间复用，不常驻 daemon
  - 窗口 frame 每次操作前刷新，窗口被移动后仍然点得准
- `capabilities` 能力探测：一次性返回权限、可用能力、默认策略、错误码表
- `selftest` 纯逻辑自检：27 项断言，无 GUI / 无 TCC 依赖，可直接在 CI 跑
- `idle` 探针：距上次真实用户输入的时间，用于区分「引擎抢焦点」与「用户自己在动」
- 结构化错误码：`permission_denied` / `window_not_found` / `target_gone` /
  `no_pressable_element` / `no_observable_change` / `session_not_found` / `bad_request`
- MCP `cu_session` 工具（16 个工具总计）
- 三层测试：`tests/unit`（CI）、`tests/integration`（需授权）、`tests/regression`（历史矩阵）

### 变更
- 自动升级策略收紧：**只在 AX 失败时**降级到定向投递，不再在「AX 成功但界面没变化」时补一次坐标点击
  - 原因：`AXPress` 成功意味着应用已接受动作；再补一次会让非幂等按钮（复制、发送、+）重复执行。
    检测不到变化改为如实报告 `no_observable_change`
- 主窗口判据抽成纯函数 `pickMainWindowRecord`，成为可单测的安全规则
- 坐标换算统一为 `windowLocal / windowGlobal` 两个函数，投递/光标/截图共用一份实现
- 修复 `processName` 解析 `KERN_PROCARGS2` 时把 argc 二进制当字符串读，导致 `responsibleName` 出现控制字符
- 源码按职责分目录：`WindowCapture / Accessibility / InputDispatcher / GhostCursor / SessionManager`

### 保留（此前已验证，未改动行为）
- 窗口级 `SCStream` 持续捕获与紫色共享指示器生命周期观测
- `postToPid` + 字段 51/58 + `CGEventSetWindowLocation` 的定向投递
- Ghost Cursor 独立 daemon（层级 102、事件穿透、坐标锚定窗口）
- per-app 授权白名单
- `WBCU_NO_HID_MOUSE=1` 结构性禁用鼠标注入

## [0.1.0] — 2026-11-10

内部实验版本，未公开发布。包含紫胶囊机制验证、AX 树读取、
后台定向点击实验、虚拟光标原型。
