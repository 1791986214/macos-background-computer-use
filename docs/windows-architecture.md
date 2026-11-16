# Windows 引擎架构（v0.6.0）

> 本文描述 `src-windows/` 的实现。跨平台语义定义在 `contract/README.md`，
> 两份文件冲突时以契约与代码为准。

## 1. 一个技能，两个引擎

```
                    WorkBuddy Agent
                           │
                  workbuddy-third-hand  (单一 SKILL.md)
                           │
                  平台检测（wbcu / wbcu.exe）
                           │
          ┌────────────────┴────────────────┐
          │                                 │
     macOS Engine                      Windows Engine
     wbcu (Swift)                      wbcu.exe (C#)
          │                                 │
  ScreenCaptureKit                   Windows.Graphics.Capture
  Accessibility (AX)                 UI Automation (IUIAutomation*)
  CGEvent postToPid                  SendMessageTimeout / PostMessage
  NSPanel Ghost                      WS_EX_LAYERED + UpdateLayeredWindow
          │                                 │
          └────────────────┬────────────────┘
                           │
                   统一 Action API（contract v1.0）
                           │
                   结果验证（四分类）
                           │
                   应用经验记忆（同格式）
```

**没有**把 Swift 改写成 C#，也没有共用二进制。共用的是**语义**：
动作名、结果结构、验证判据、经验格式、性能指标、调用方式。

## 2. 工程结构

```
src-windows/
├── Wbcu.Contract/          net8.0 纯逻辑，无 Windows API —— 可在 macOS / CI 上单测
│   ├── Actions.cs          11 个统一动作
│   ├── ResultEnvelope.cs   结果信封 + JSON 口径
│   ├── VerifyModel.cs      四分类验证逻辑（与 Swift 同判据）
│   ├── Selector.cs         选择器语法与匹配
│   ├── TextNormalize.cs    文本归一化与匹配模式
│   ├── Capability.cs       能力矩阵模型
│   ├── SessionRecord.cs    会话结构
│   ├── AppExperience.cs    经验结构 + 百分位
│   ├── Geometry.cs         DPI / 坐标换算 / 遮挡比例
│   ├── CursorRaster.cs     Ghost Cursor 纯像素渲染（可单测）
│   ├── PngWriter.cs        零依赖 PNG 编码（可单测）
│   └── ContractSchema.cs   契约的可执行版本
├── Wbcu.Windows/           net8.0-windows10.0.19041.0 —— 引擎本体（wbcu.exe）
│   ├── Program.cs          命令分发 + 退出码
│   ├── Cli/                参数解析、输出口径
│   ├── Win32/Native.cs     P/Invoke 声明合集
│   ├── Discovery/          窗口枚举、应用匹配、进程信息
│   ├── Uia/                UIA 线程 + 解析器 + 选择器定位
│   ├── Capture/            Graphics Capture + PrintWindow 双后端
│   ├── Input/              定向投递阶梯、全局输入（显式授权）、安全取证
│   ├── Verify/             状态探测与等待
│   ├── Session/            会话持久化与失效校验
│   ├── Experience/         经验库
│   ├── Ghost/              覆盖层守护进程 + 客户端
│   ├── Trace/              前台激活归因
│   ├── Diagnostics/        能力矩阵、自检、体检
│   └── Commands/           命令实现
├── Wbcu.TestApp/           WPF 受控目标（纯代码，无 XAML）
├── Wbcu.TestApp.Win32/     原生 Win32 受控目标（消息投递的唯一可信靶子）
├── Wbcu.Tests/             xunit 纯逻辑测试（65 例，macOS/CI 可跑）
├── Wbcu.GuiTests/          交互式 GUI 验收套件（仅真机桌面）
└── tools/RenderPreview/    Ghost Cursor 视觉预览 + 契约导出（开发工具）
```

## 3. 技术选型与理由

| 选择 | 理由 | 放弃的方案与原因 |
|---|---|---|
| C# + .NET 8 + `net8.0-windows10.0.19041.0` | 拿到 WinRT 投影（Graphics Capture / D3D11 interop），且能在 macOS 上 `EnableWindowsTargeting` 交叉编译 —— 没有 Windows 机器也能给出真实编译证据 | C++/WinRT 性能更好，但开发成本与本次交付窗口不匹配；且无法在本机验证 |
| `Interop.UIAutomationClient`（官方 COM 互操作程序集） | `IUIAutomation*` 的 vtable 由微软维护，不会因为手写顺序错一位而在用户机器上崩 | 手写 COM 接口：`IUIAutomation` 有 60+ 方法，错位即 AV，且无真机无法逐一验证 |
| `Vortice.Direct3D11` | 成熟的托管 D3D11 封装，`ID3D11DeviceContext` 同理避免手写 | 手写 ID3D11Device vtable（Map/Unmap/CopyResource 都很深） |
| 不引用 WPF/WinForms | 引擎无 UI 依赖：启动更快、体积更小、不引入 Dispatcher | WPF 覆盖层实现更省事，但会拖进整套 UI 框架 |
| Ghost 用 `UpdateLayeredWindow` | 逐像素 alpha、点击穿透、零激活，成本最低 | WPF `AllowsTransparency` 需要 UI 线程与 DWM 交互，且更重 |

打包结果：`wbcu.exe` + 依赖共约 26 MB（framework-dependent，需 .NET 8 Desktop? **不需要** —— 本工程不含 WindowsDesktop 依赖）。

## 4. 线程模型

| 线程 | 职责 | 约束 |
|---|---|---|
| 主线程 | 命令解析、输出、退出码 | 不直接做跨进程 UIA 调用 |
| `wbcu-uia`（MTA） | 所有 UIA 客户端调用 | COM 对象**只在这条线程创建与释放**，绝不外泄引用 |
| Ghost 守护进程主线程 | 窗口消息循环 + 定时重绘（33ms） | 独立进程，被杀不影响引擎 |
| Ghost 管道线程 | 命名管道收行 → 入队 → `PostMessage` 唤醒 | 立即回执「已收到」，不代表「已画完」 |
| Trace 守护进程主线程 | `SetWinEventHook` 回调落盘 | 纯旁观者，不碰任何窗口状态 |

UIA 调用统一走 `UiaThread.Run(fn, timeoutMs)`：超时抛 `timeout` 退出码，**不挂死调用方**；
所有 COM 交互都在闭包内完成，对外只返回托管快照（`UiaSnapshot` / `ElementReadout`）。

## 5. 输入执行阶梯

```
① UIA 语义 Pattern        uia_invoke / uia_toggle / uia_select / uia_setvalue / uia_scroll
② 窗口消息定向投递        SendMessageTimeout(WM_LBUTTONDOWN/UP, WM_CHAR, WM_KEYDOWN/UP, WM_MOUSEWHEEL)
③ 全局输入（需授权）      SendInput —— 会移动真实鼠标
```

三条原则：

1. **能拿到 Pattern 就绝不用坐标。** 语义调用不需要前台、不受遮挡影响。
2. **消息投递要发给最深子窗口**（`RealChildWindowFromPoint` 逐层下探），
   发到顶层窗口通常会被忽略；坐标必须是该子窗口的客户区坐标。
3. **返回成功 ≠ 点击被消费。** `delivered=true` 只说明消息被处理，
   是否真的发生业务变化由 `verification` 判断。WPF/Electron/自绘界面经常忽略普通窗口消息。

`--allow-global` 之外，代码里**没有任何**调用 `SendInput` / `SetCursorPos` 的路径；
启动路径也不会调用 `SetForegroundWindow`（唯一例外：用户显式 `--foreground` 或 MSIX 激活）。

## 6. 会话生命周期

```
attach
  ├─ 匹配应用（pid / exe / 包族 / AUMID / 标题 / HWND，精确优先）
  ├─ 选主窗口（可见、未最小化、无 owner、面积最大）
  ├─ 写 SessionRecord（pid / hwnd / exe / 包族 / 帧矩形 / DPI / 时间）
  └─ 可选：拉起 Ghost 守护进程并绑定窗口
                                          ↓ 复用
                                    每次动作只做
                                    「定位 → 执行 → 验证」
```

失效判定（都会明确报 `session_stale`，不拿死句柄硬点）：

- 窗口句柄不存在 / `IsWindow` 为假；
- 句柄被别的进程复用（比对 pid）；
- 超过 24 小时未使用（`session gc`）。

## 7. 截图双后端

| 后端 | 何时用 | 限制 |
|---|---|---|
| Windows.Graphics.Capture | 默认（Win10 1903+） | 最小化窗口无合成表面；受 DRM 保护内容为黑；需要 D3D11 设备 |
| PrintWindow(`PW_RENDERFULLCONTENT`) | 上一路径失败时自动降级 | 同步 GDI，可能阻塞目标几百毫秒；部分 GPU 重绘界面拿到空白 |

降级一定写进 `warnings`，并如实标注 `method`。
`GraphicsCaptureBackend` 里对 `session.IsBorderRequired` 用反射设置：
该属性只在 Win11 22H2+ 存在，当前投影（19041 契约）里可能没有，不能让一个可选优化拖垮整个捕获。

## 8. 经验记忆

- key：`pkg:<PackageFamily>` 优先，退化到 `exe:<路径>|class:<窗口类>`。
- 元素记忆只存：`AutomationId` → `Path` → `Name`，以及**验证成功过的执行路径**（`uia_invoke` / `wm_message`）。
- 坐标只作为 `lastSeenRect` 的调试参考，**不参与定位**。
- 复用前必须复验（名称/类型/自动化 id 对得上）；对不上就当没命中，退回实时查找。

## 9. 与 Browser Use 的分工

| 任务 | 工具 |
|---|---|
| 网页导航、DOM 读取、网页点击、表单、滚动、标签页 | WorkBuddy Browser Use（`agent-browser` CLI） |
| 桌面应用、原生窗口、UIA、Ghost、跨应用辅助 | `wbcu.exe` |

不重复开发 Chromium 自动化。混合任务由 WorkBuddy 串接，**不引入阻塞式统一门禁**。
Windows 上是否暴露产品级 Browser Use 通道取决于当前构建与 flag，**本仓库不假设、不编造**。

## 10. 明确未验证的部分（不要当成已支持）

- 真机 GUI 验收（Calculator / 记事本 / 资源管理器、遮挡、并发用户输入）—— 需要交互式 Windows 桌面；
- Graphics Capture 的实际取帧质量与 DPI 混合显示器表现；
- `Interop.UIAutomationClient` 在特定第三方应用上的 Pattern 行为差异；
- Windows on ARM64 运行时表现（已配置 `win-arm64` 目标，未实测）。

这些项在 `wbcu.exe capabilities --json` 里会如实显示为 `not_tested`。
