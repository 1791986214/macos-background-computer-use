# macOS Background Computer Use

### Independent Cursor · Background Automation · AI Agent Integration

一个面向 macOS AI Agent 的后台桌面自动化项目：在尽量不干扰用户真实鼠标、前台窗口与键盘焦点的前提下，完成跨应用的观察、交互与任务执行。

> 🚧 **项目状态：Experimental**
>
> 后台交互能力随 macOS 版本、应用框架与系统授权而不同。**已实测范围见 [`docs/capability-matrix.md`](docs/capability-matrix.md)，未测试的一律标 `Not Tested`，不当作"支持"。**

## ✨ 项目简介

传统桌面自动化（cliclick、pyautogui、AppleScript `click at`）依赖全局指针位置：先把真实鼠标移过去、再发全局事件。结果是用户被打断、目标窗口必须置顶、被遮挡就点不到。

本项目换一条路：**把事件直接投递进目标进程**，并让 AI 拥有一个与物理鼠标完全解耦的逻辑光标。

**Your mouse stays yours. Your agent gets its own cursor.**

三层职责严格分离，任一层失效不影响其余两层：

| 层 | 职责 | 失效后果 |
|---|---|---|
| 可视化（Ghost Cursor） | 让人看见 Agent 在点哪 | 看不见，操作照常 |
| 输入执行（Dispatcher） | 让目标应用真的响应 | 报错，不假装成功 |
| 观察验证（AX / SCK） | 确认界面到底变没变 | 无法断言，如实报告 |

## 🚀 核心能力

### 1. Background Window Capture

基于 Apple ScreenCaptureKit，按窗口而非整屏捕获。

- 窗口级捕获（`SCContentFilter(desktopIndependentWindow:)`）
- 单帧截图与持续 `SCStream`
- Retina 缩放适配（按 `pointPixelScale` 换算，像素尺寸 = 逻辑尺寸 × scale）
- 窗口移动/缩放后重新解析归属，避免记错目标
- 能识别并排除 macOS 的窗口共享指示器（见下方「一个真实的坑」）

### 2. Background UI Interaction

Accessibility 语义优先，进程级投递兜底。

- AX 树读取、按坐标在**目标应用自己的树里**定位可按下元素
- 语义操作：`AXPress` / `AXValue` 读写
- 进程级投递：`postToPid` + 窗口号（字段 51）+ 窗口局部坐标
- 操作后对比 AX 指纹验证结果（`changed` / `no_observable_change` / `not_requested`）
- 被完全遮挡的窗口仍可点击（实测指针距目标 553px 时成功）

**实测结论**：并非所有应用都接受进程级后台事件。WKWebView 的 WebContents 拒绝坐标事件，
但它的 AX 树里有 `AXWebArea → AXButton`，走语义路径可点；非激活窗口没有 field editor，
按键无处落地，文本要写 `AXValue`。这些差异都记录在能力矩阵里，不靠猜。

### 3. Independent Ghost Cursor

独立于物理鼠标的软件光标，只负责可视化。

- 独立逻辑坐标，锚定 `windowId + 窗口局部坐标`（窗口移动时 100ms 周期重算跟随）
- 透明无边框 Overlay，`ignoresMouseEvents = true` 事件全穿透
- `.accessory` 策略，不进 Dock、不抢焦点
- 层级 102：盖得住普通窗口与菜单，不盖系统 HUD / 通知中心
- `easeOutCubic` 0.24s 移动动画，点击涟漪 + 状态反馈（成功绿环 / 失败红环）
- 关闭显示不影响后台操作（两层解耦，可单独验证）

实现方式：AppKit `NSView.draw(_:)` + 60fps `Timer` 驱动动画，不依赖 Core Animation。

### 4. AI Agent Integration

对外两种入口，指向同一个引擎：

- **CLI**：`wbcu session start/capture/inspect/click/type/key/cursor/verify/end`
- **MCP**：16 个 `cu_*` 工具（`cu_session` 为推荐入口）

会话状态落盘而非常驻 daemon：每条命令一个进程，单条崩了不影响会话，也不会留下半死进程。

### 5. Reusable Skills

操作策略、能力边界与调用方式封装为 Agent Skill，跨会话、跨项目复用。
见 [`skills/macos-background-computer-use/`](skills/macos-background-computer-use/)。

## 🏗️ 系统架构

```text
                    AI Agent / WorkBuddy
                            │
              ┌─────────────┴─────────────┐
              │        CLI  /  MCP        │
              └─────────────┬─────────────┘
                            │
                  Computer Use Session          ← 状态落盘，命令间复用
                            │
        ┌───────────────────┼───────────────────┐
        │                   │                   │
  Window Capture     Accessibility       Cursor State
  (ScreenCaptureKit)  (AX 树 / 定位)     (逻辑坐标，锚定窗口)
        │                   │                   │
        │            UI Resolver                │
        │                   │                   ▼
        │        Background Input Dispatcher   Ghost Cursor
        │        (AX → postToPid → 全局HID)     (独立 daemon)
        │                   │                   │
        │                   ▼                   ▼
        │            Target Application     Cursor Overlay
        │                   │              (NSView + Timer)
        └───────────────────┤
                            ▼
                   Action Verification
                   (AX 指纹前后对比 → 三态)
```

三处刻意的设计：

1. **捕获不直接喂给输入层**。画面用于视觉定位与人工核对，投递不依赖截图，所以截图失败不影响操作。
2. **光标是独立进程**。它要持续动画，必须有自己的 runloop；但它可以随时死掉，死了只是看不见。
3. **验证是独立一环**。投递 API 返回成功不等于界面变了，必须回读。

## 🛠️ 技术栈

| 技术 | 用途 |
|---|---|
| Swift / AppKit | macOS 原生实现 |
| ScreenCaptureKit | 窗口画面捕获（单帧 + 持续流） |
| Accessibility API | UI 元素读取与语义操作 |
| CoreGraphics | 窗口枚举、坐标换算、事件构造与投递 |
| AppKit（NSView + Timer） | 软件光标绘制与动画 |
| Node.js（零依赖） | MCP 服务器，手写 JSON-RPC over stdio |
| GitHub Actions | 构建 + 单元测试 + 源码卫生检查 |

## 📦 安装

### 环境要求

- macOS 14 或更高（部署目标 14.0；**实测于 macOS 26.6**）
- Xcode Command Line Tools（`xcode-select --install`）
- 无需 Homebrew，无第三方依赖
- 按需授予 **辅助功能** / **屏幕录制**；仅当必须动真实鼠标时才需要 **输入注入**

### 获取源码

```bash
git clone https://github.com/1791986214/macos-background-computer-use.git
cd macos-background-computer-use
```

### 构建与安装

```bash
./scripts/build.sh                 # 产出 bin/wbcu
./scripts/install.sh --skill       # 装到 ~/.local/bin，并安装 Agent Skill
wbcu selftest                      # 27 项纯逻辑自检，不需要任何授权
```

构建脚本会优先使用 `MacOSX26.5.sdk`：本机 macOS 27.0 SDK 与 Command Line Tools 的 Swift 6.3.3
版本不匹配，用默认 SDK 编译失败。不存在该 SDK 时自动回落 `xcrun --show-sdk-path`。

### 授权

```bash
wbcu perm --prompt                              # 触发系统授权弹窗
wbcu guard --app com.apple.calculator --allow    # 按应用授权（第二道闸门）
```

完整步骤（升级、卸载、换机恢复、TCC 归因陷阱）见
[`docs/installation.md`](docs/installation.md) 与 [`docs/permissions.md`](docs/permissions.md)。

### 首次验证

```bash
SID=$(wbcu session start --app com.apple.calculator --json \
      | python3 -c "import sys,json;print(json.load(sys.stdin)['session']['id'])")
wbcu session click --id "$SID" --text "7"   --exact
wbcu session click --id "$SID" --text "加"   --exact
wbcu session click --id "$SID" --text "8"   --exact
wbcu session click --id "$SID" --text "等于" --exact
wbcu session verify --id "$SID" --expect "15"
wbcu session end --id "$SID"
```

全程真实鼠标不动、前台不切、目标应用不激活。

## 🎯 使用场景

**后台办公操作** — 用户正常使用浏览器时，Agent 读取另一个已授权应用的状态并执行操作。

**跨应用工作流** — 从 A 应用取信息，写入 B 应用，每步读值确认，不靠「命令返回 0」。

**桌面 Agent 开发** — 把窗口观察、交互执行、光标展示当成可复用能力，而不是每个任务重写一遍点击逻辑。

**自动化测试** — 在受控 fixture 中验证后台事件投递、输入隔离与窗口坐标映射（见 `tests/integration/`）。

## 🧪 兼容性与测试

本项目**不承诺**所有应用都支持完全无干扰操作。以下为实测结论（macOS 26.6，目标窗口被完全遮挡）：

| 目标 | AX 语义 | 进程级投递 | 备注 |
|---|---|---|---|
| Calculator（AppKit 标准控件） | ✅ | ✅ | `7+8=15`、`6×7=42` 读值验证通过 |
| 自绘 `NSView` | ❌ 无 AXPress | ✅ | 需目标视图 `acceptsFirstMouse=true` |
| `WKWebView` 内按钮 | ✅ | ❌ | 走 `AXWebArea → AXButton` |
| TextEdit 文本框 | ✅ `AXValue` | ❌ 按键 | 非激活窗口无 field editor |
| 拖拽 | — | ⚠️ | `mouseDown` 送达，AppKit 不建立拖拽会话 |
| Electron / Chromium | `Not Tested` | `Not Tested` | 需要真实 Electron App + `AXManualAccessibility` |
| 多显示器 | `Not Tested` | `Not Tested` | 仅有负坐标换算的单测 |
| macOS 27 | `Not Tested` | `Not Tested` | 本机只有 SDK，没有 27 系统 |

**未经测试的环境不视为已支持。** 完整矩阵：[`docs/capability-matrix.md`](docs/capability-matrix.md)；
版本差异与升级风险：[`docs/compatibility.md`](docs/compatibility.md)。

### 测试分层

```bash
./tests/run-all.sh unit     # 纯逻辑 + 源码卫生，无 GUI / 无授权，CI 每次跑
./tests/run-all.sh          # 再加会话层集成测试（需要授权与真实桌面）
./tests/run-all.sh all      # 再加历史回归矩阵与 fixture 对照
```

**CI 绿不等于功能可用。** 托管 runner 没有图形会话、无法人工授权、也无法保证没人动鼠标，
所以真实交互测试只在授权机器上跑。这条原则写在 `.github/workflows/ci.yml` 的注释里。

## 🔐 安全和隐私

- **不绕过 TCC**：只通过系统允许的方式请求与检查授权，不写 TCC 数据库、不伪造签名。
- **不偷抢输入**：默认路径不移动真实指针；全局 HID 必须显式 `--allow-global` 才会执行。
- **按应用收窄**：TCC 无法表达「只控制这一个 App」，所以在此之上加了应用级白名单，白名单外直接拒绝。
- **不伪装无干扰**：不允许「把鼠标移过去点一下再移回来」。
- **不上传数据**：截图、AX 树、会话状态全部留在本地 `~/.wbcu/`。
- **不可逆操作先确认**：删除、发送、提交、支付由 Skill 层的硬规则约束，不由引擎默默执行。

已知的未文档化依赖（`_AXUIElementGetWindow`、CGEvent 字段 51/58）及其缓解方案，见 [`SECURITY.md`](SECURITY.md)。
**SkyLight / SLS / SLPS 完全未使用。**

## 🗺️ Roadmap

- [x] 原生 Engine API（CLI 会话层 + MCP 16 工具）
- [x] Ghost Cursor 生命周期管理（会话结束时隐藏/释放，崩溃后可恢复）
- [x] WorkBuddy Skill 集成验证（最小环境模拟 + 实机跑通）
- [x] AppKit 后台操作测试（NSButton / 自绘 View / WKWebView 分层结论）
- [x] 被遮挡窗口坐标映射
- [x] CI 自动化（构建 + 单元测试 + 源码卫生）
- [x] 安装 / 升级 / 换机恢复文档
- [ ] SwiftUI 专项测试
- [ ] Electron / Chromium 兼容性研究（`AXManualAccessibility` 路径）
- [ ] 多显示器实机坐标映射
- [ ] 后台拖拽（当前公开 API 实现不了；私有 SkyLight 方案未集成）
- [ ] 正式稳定版本（1.0.0）

## 🧩 一个真实的坑（写下来免得别人再踩）

macOS 26 起，**窗口级持续捕获**会让系统往目标应用的 AX 窗口列表**第 0 位**插入一个：

```
AXWindow (subrole=AXDialog, title="Window", ~66×20)
  └─ AXButton (title="WindowSharingSessionButton")
```

代码里写 `kAXWindows[0]` 当主窗口，后续所有点击都会落到这个胶囊上。
本项目的判据是纯函数（`pickMainWindowRecord`）并有单测：
`pid 匹配 && layer==0 && 宽≥120 && 高≥60 && 名称不含 WindowSharingSessionButton → 取面积最大`。

另外：**单帧截图不触发该指示器，只有持续捕获触发**；它还会被截进被捕获画面本身。

## 📚 参考资料

- [Apple ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit/)
- [Apple Accessibility — AXUIElement](https://developer.apple.com/documentation/applicationservices/axuielement_h)
- [agent-device](https://github.com/callstack/agent-device)
- [Codex](https://github.com/openai/codex)

本项目是独立的技术研究与实现，不包含上述项目的内部或专有代码。

## 🤝 参与贡献

欢迎 Issue、兼容性测试报告与 Pull Request。提交问题请尽量附上：
macOS 版本、目标应用与框架类型、最小复现步骤、**界面实际发生了什么**（这条最关键），
以及脱敏后的 `wbcu capabilities --json` 输出。

约定与流程见 [`CONTRIBUTING.md`](CONTRIBUTING.md)。

## 📄 License

[MIT](LICENSE)。

仓库内无第三方代码、无外部依赖（MCP 服务器为手写零依赖脚本）。唯一涉及的外部技术依赖是
Apple 系统 API 与一个未文档化符号 `_AXUIElementGetWindow`，该符号不属于可再分发代码。

---

**Building less intrusive computer use for macOS AI agents.**

让 AI 在桌面上工作，而不是打断你的工作。
