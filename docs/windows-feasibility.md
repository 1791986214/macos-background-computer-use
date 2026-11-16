# Third Hand 能不能跑 Windows？——实测结论与移植评估

> ⚠️ **本文结论已被 v0.6.0 取代（2026-11-16）**
>
> 本文回答的是「**能不能把现有的 Swift 引擎拿到 Windows 上跑**」——答案是仍然不能，下面的证据全部有效。
> 但它被误读成了「Third Hand 永远没有 Windows 版」，这是错的。
> v0.6.0 的做法是**为 Windows 新写一个原生引擎**（C# + UI Automation + Graphics Capture），
> 与 macOS 引擎共享同一份跨平台契约与同一个技能。见
> [`docs/windows-architecture.md`](windows-architecture.md) 与 [`contract/README.md`](../contract/README.md)。

**结论：不能（指复用 Swift 二进制）。** 不是「编译一下」的问题，而是**引擎四层全部绑定 macOS 私有框架**，
Windows 版等于重写引擎。下面是证据、移植工作量，以及 Windows 用户现在该用什么。

> 验证日期 2026-11-16 ｜ 引擎 v0.5.2 ｜ 本机 macOS 26.6 / arm64

---

## 一、为什么不能（可复核的证据）

### 1.1 二进制是 Mach-O，不是 PE

```
$ file bin/wbcu
bin/wbcu: Mach-O 64-bit executable arm64
```

Mach-O 是 macOS 的可执行格式，Windows 只认 PE（`.exe`）。
`LC_BUILD_VERSION platform 1` = macOS 平台。Windows 连「加载」这一步都过不去。

### 1.2 依赖全是 macOS 独占框架

| 框架 | 引用文件数 | Windows 有吗 |
|---|---|---|
| `AppKit`（窗口、面板、菜单） | 20 | ❌ |
| `CoreGraphics`（CGEvent、窗口列表） | 15 | ❌ |
| `ApplicationServices`（AXUIElement 辅助功能） | 10 | ❌ |
| `ScreenCaptureKit`（窗口捕获） | 3 | ❌ |
| `NSWorkspace`（应用/前台状态） | 22 处调用 | ❌ |

这些不是「换个名字就能编」的差异 —— 它们对应的是完全不同的系统机制：

| Third Hand 依赖的能力 | macOS 机制 | Windows 对应机制（完全不同） |
|---|---|---|
| 读界面元素树 | Accessibility（AXUIElement） | UI Automation（UIA / COM） |
| 语义点击按钮 | `AXUIElementPerformAction` | UIA `InvokePattern` |
| 后台定向投递点击 | `CGEventPostToPid` + 事件字段 51/58 | `PostMessage(WM_LBUTTONDOWN)` 或 UIA |
| 窗口截图 | `SCScreenshotManager` / `SCStream` | `PrintWindow` / Windows.Graphics.Capture |
| 枚举窗口与层级 | `CGWindowListCopyWindowInfo` | `EnumWindows` + `GetWindowLong(GWL_EXSTYLE)` |
| 独立虚拟光标覆盖层 | `NSPanel` + `.nonactivatingPanel` + `LSUIElement` | WS_EX_LAYERED + WS_EX_NOACTIVATE + WS_EX_TOOLWINDOW |
| 判断前台归属 | `NSWorkspace.frontmostApplication` | `GetForegroundWindow` + 进程名 |

### 1.3 本机工具链没有 Windows 目标

```
$ swiftc -print-target-info → arm64-apple-macosx26.0
$ ls /Library/Developer/CommandLineTools/SDKs/ → MacOSX*.sdk（只有 macOS）
```

即便装 Swift for Windows，上表那四层框架在 Windows 上**不存在**，
Swift 标准库能编，GUI/自动化框架编不了。

### 1.4 代码里没有任何 Windows 分支

```
grep -rn "user32|SendInput|UIAutomation|GetForegroundWindow|PrintWindow" src/  → 0 处
find . -iname "*.exe" -o -iname "*.dll"                                        → 0 个
```

所以不存在「藏了一个 Windows 版本没启用」的情况。

---

## 二、移植到底要写多少

| 模块 | 现状（macOS） | Windows 需重写 | 说明 |
|---|---|---|---|
| 窗口发现 / 层级 / 遮挡判定 | `Visibility.swift` + CGWindowList | ✅ 全部 | UIA 与 Win32 混合，语义不同 |
| 界面元素树与路径 | `AX.swift`（68 处 AXUIElement） | ✅ 全部 | UIA TreeWalker，路径模型要重设计 |
| 语义动作 | AXPress | ✅ 全部 | InvokePattern / LegacyIAccessible |
| 后台定向输入 | CGEvent + 字段 51/58 | ✅ 全部 | PostMessage 的命中测试完全不同 |
| 窗口捕获 | ScreenCaptureKit | ✅ 全部 | PrintWindow 对 GPU 合成窗口常截黑 |
| 虚拟光标 | NSPanel + LSUIElement | ✅ 全部 | 分层窗口 + 命中穿透 |
| 期望状态验证 | 纯逻辑（比较/规范化/四分类） | ⭕ 可复用 | 与平台无关 |
| 经验库（路径 + 身份校验） | 纯逻辑 + 平台路径 | ⭕ 半复用 | 路径模型要换 |
| 激活追踪 / 归因 | NSWorkspace 通知 | 🔁 重写 | WinEventHook（EVENT_SYSTEM_FOREGROUND） |
| 性能计时 / 测试方法 | 纯逻辑 | ⭕ 可复用 | — |
| CLI 协议 / JSON 结构 | 纯逻辑 | ⭕ 可复用 | 可以保持命令名一致 |

**量级判断（按现有 7777 行 Swift 代码推算）**：
真正能复用的只有「验证逻辑 + CLI 壳 + 测试方法」，约占 25–30%；
其余 5000+ 行是平台绑定，要在 Windows 上重新实现。这不是一个补丁，是一个**独立的 Windows 引擎**。

---

## 三、Windows 用户现在该用什么

### 方案 A（推荐）：用 WorkBuddy 产品自带的 Computer Use

产品里有一个**与平台无关**的 computer use 开关，门控是：

```js
requireFlags: ['localEnvironment', 'macOrWindowsPlatform', 'computerUseEnabled']
```

`macOrWindowsPlatform` 说明 **Windows 是官方支持平台**，能力由 `computerUseRuntimeHost` 注入
（不是本仓库的 Third Hand）。Windows 用户应当优先用它，而不是等 Third Hand 移植。

> 入口同「浏览器操控」：设置 → **扩展**（这个构建里注册在 `tab: extensions`，不是「智能体」）。
> 需要 `computerUseEnabled` 为真才会渲染；本机未开启，无法在 macOS 上代你验证 Windows 侧表现。

### 方案 B：用现成的 Windows 自动化（临时/轻量）

| 需求 | 工具 | 备注 |
|---|---|---|
| 点击标准控件、读文本 | PowerShell + UIAutomation（`UIAutomationClient`） | 系统自带，零依赖 |
| 简单键鼠回放 | AutoHotkey v2 | 全局 HID，会抢鼠标 |
| Python 生态 | pywinauto / uiautomation | 开发快，分发要带 Python |
| 后台不抢焦点点击 | `PostMessage` + `WM_LBUTTONDOWN` | 只对部分控件有效，需按应用验证 |

### 方案 C：真做 Windows 版

如果确实要做，建议**不要移植**，而是按同一套验收标准重写：

1. 先做 200 行的可行性 spike：UIA 读计算器按钮 → `InvokePattern` 点击 → 读回显示值。
   这一步能立刻暴露「这个应用支不支持 UIA」——和 macOS 上 AX 的坑一模一样。
2. spike 通过后再定架构；`wbcu doctor` / `trace` / 期望状态四分类这套方法论可以直接沿用。
3. 保留同一套 CLI 命令名与 JSON 字段，让 Skill 不用改（只改「平台」那一段）。

---

## 四、Not Tested（明确标注）

| 项目 | 状态 | 原因 |
|---|---|---|
| Third Hand 在 Windows 上运行 | **不可用（已验证为平台不兼容）** | 无 Windows 机器；二进制格式与框架依赖已足以判定 |
| WorkBuddy 产品 Computer Use 在 Windows 的实际表现 | **未验证** | 本机 macOS，且该开关未开启 |
| Windows 侧 UIA 对各应用的覆盖率 | 未测 | 需 Windows 环境按 `docs/capability-matrix.md` 的方式重跑 |

---

## 五、一句话

**Third Hand 是 macOS 专用组件**；Windows 用户请用 WorkBuddy 自带的 Computer Use
（官方 flag 含 `macOrWindowsPlatform`），或按方案 B 的本地方案。
想做 Windows 版，按方案 C 重写，别指望交叉编译。
