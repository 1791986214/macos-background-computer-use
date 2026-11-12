# 能力矩阵（实测）

**规则：没实测过的一律写 `Not Tested`，不许标 Supported。**

## 测试环境

| 项 | 值 |
|---|---|
| 机器 | MacBook（Apple Silicon, arm64） |
| macOS | 26.6 (Build 25G72) |
| 工具链 | CommandLineTools，Swift 6.3.3，编译用 `MacOSX26.5.sdk` |
| 引擎版本 | 0.4.3 |
| 判据 | 目标 UI **实际变化**（读 AX 值），不是命令返回码 |
| 零干扰判据 | 真实鼠标零位移 + 前台应用不变 + `targetActive == false` + `idle` 探针确认期间无用户输入 |

---

## 一、系统应用

### Calculator（计算器）— `com.apple.calculator`

| 能力 | 结果 | 备注 |
|---|---|---|
| 窗口捕获（单帧） | ✅ | 460×816 @2x（Retina 正确） |
| 窗口捕获（持续 SCStream） | ✅ | 触发系统紫色共享指示器 |
| AX 树读取 | ✅ | 36–38 节点，按钮有 `identifier`（`Seven`/`Equals`/`AllClear`） |
| AX 语义点击 | ✅ | `7+8=15`、`6×7=42` 均验证通过 |
| 被遮挡时操作 | ✅ | 被 WorkBuddy 窗口完全覆盖仍成功 |
| 定向坐标点击 | ✅ | 字段 51+58 路径 |
| 虚拟光标 | ✅ | 锚定窗口，遮挡时仍浮在目标上 |
| 前台焦点影响 | 无 | `targetActive=false`，前台不变 |
| 文本输入 | Not Tested | 计算器无文本输入框 |

### TextEdit（文本编辑）— `com.apple.TextEdit`

| 能力 | 结果 | 备注 |
|---|---|---|
| AX 树读取 | ✅ | `AXTextArea` 可读值 |
| AXValue 写入 | ✅ | 后台写入中文/emoji 成功，读回一致 |
| 后台按键输入 | ❌ | 非激活窗口没有 field editor，按键无处落地 |
| `cmd+n`（DocumentController） | ✅ | 不依赖 key window，走应用级命令 |
| `cmd+w`（performClose:） | ❌ | 需要 key window。改用 AX 点「关闭按钮」 |
| 窗口捕获 | ✅ | — |

**两者差异的原因**：`cmd+n` 由 `NSDocumentController` 在应用级处理；`cmd+w` 走
`performClose:`，需要 key window 与 responder chain 落地。所以「后台快捷键不可用」
是个过于笼统的结论 —— 要按**事件处理路径**分类，不是按快捷键分类。

### Finder（访达）— `com.apple.finder`

| 能力 | 结果 | 备注 |
|---|---|---|
| AX 树读取 | ✅ | 含边栏、列表区、路径栏 |
| AX 语义动作（侧边栏切目录） | ⚠️ | `AXCell` 声明了 `AXOpen` 但执行返回 `attributeUnsupported`（系统级瑕疵） |
| 坐标点击兜底 | ✅ | 目标窗口在最上层时有效 |
| 被遮挡时切换目录 | Not Tested | 需要坐标路径，遮挡下未单独验证 |

### Safari — `com.apple.Safari`

| 能力 | 结果 |
|---|---|
| 全部 | Not Tested |

未测原因：需要用户交互（首次启动、标签页状态），本轮未做受控实验。
不给「推测可用」这种结论。

---

## 二、框架差异（用受控 fixture 测的）

fixture 见 `tests/integration/Fixture.swift`：同一窗口里放 NSButton / NSTextField /
自绘 Canvas / WKWebView / 拖拽区，全部带稳定 `AXIdentifier`。

| 目标 | AX 语义 | 定向投递 | 遮挡下 | 说明 |
|---|---|---|---|---|
| `NSButton`（标准） | ✅ | ✅ | ✅ | 最稳，首选 |
| 计数器按钮 + 文本回显 | ✅ | ✅ | ✅ | 可用 AXValue 验证 |
| 自绘 `NSView`（Canvas） | ❌ 无 `AXPress` | ✅ | ✅ | 必须目标视图 `acceptsFirstMouse=true` |
| `WKWebView` 内按钮 | ✅ `AXWebArea → AXButton` | ❌ | ✅(AX) | 坐标事件对它完全无效 |
| 拖拽（`NSDraggingSession`） | — | ⚠️ | ⚠️ | `mouseDown` 送达，但会话不建立 |
| 双击 | — | ✅ | ✅ | `clickState` 1→2 |
| 右键 | — | ⚠️ | — | 无上下文菜单时无法观测，不能判定 |

### 关于 `acceptsFirstMouse`

自绘视图最初怎么都点不到，查下来不是投递问题，是 **AppKit 语义**：
非激活窗口的第一次点击，系统会问视图「要不要接受」，默认 `false` 就吞掉用于激活窗口。
`NSButton` 默认 `true`，所以标准控件能点，自绘视图不能。

第三方 App 的这个开关改不了 → 对自绘界面只能走 AX，或请用户把窗口露出来。

即使开着它，首击仍偶发被吞（用于激活）。引擎里加了带窗口上下文的 `mouseMoved` 预热来规避。

---

## 三、未测试项（明确标注）

| 项 | 状态 | 缺什么 |
|---|---|---|
| Electron / Chromium 应用 | Not Tested | 需要真实 Electron App；Chromium 需 `AXManualAccessibility` 才建树 |
| 多显示器坐标 | Not Tested（仅单测） | 只有 `windowLocal/windowGlobal` 的负坐标单测通过；实机多屏未跑 |
| 窗口跨屏移动时的光标跟随 | Not Tested | 需要双屏环境 |
| macOS 27 | Not Tested | 本机只有 27.0 SDK，没有 27 系统 |
| 触控板手势 / 三指拖移 | Not Tested | — |
| 全屏应用（Space） | Not Tested | — |
| 屏幕共享指示器在 macOS 27 的形态 | Not Tested | 判据写了 subrole+标题+尺寸三重冗余，但未在 27 上验证 |

---

## 四、紫胶囊（WindowSharingSessionButton）专项

| 观测项 | 结果 |
|---|---|
| 触发条件 | 仅**窗口级 SCStream 持续**捕获；单帧 `SCScreenshotManager` 不触发（4 次采样紫色像素恒为 0） |
| 出现延迟 | 捕获开始后约 1.2s |
| 视觉 | 标题栏左上角紫胶囊，主色约 `(99,87,245)` ≈ `#6357F5`，bbox 约 130×38 |
| AX 形态（macOS 26.6） | `AXWindow(subrole=AXDialog, title="Window", 66×20)` + `AXButton("WindowSharingSessionButton")` |
| 位置 | `kAXWindows` **第 0 位**（真窗口在后） |
| 目标 App 窗口数 | 捕获中 1 → 2，停止后回 1 |
| 是否被截进画面 | **会**，出现在被捕获画面的左上角 |
| 窗口被完全遮挡时 | 像素看不到，但 AX 元素仍在 → 判「是否在共享」以 AX 为准 |
| 停止捕获后 | 约 1.2s 内消失，AX 元素与窗口数同时复原 |

**没有伪造**：引擎不绘制任何紫色元素。可见即系统所见。

---

## 五、复现实验

```bash
# 单元（任何机器）
./tests/run-all.sh unit

# 会话层端到端（需要授权 + 桌面）
./tests/integration/session.sh

# 完整矩阵
./tests/run-all.sh all
```

---

## 六、v0.4.2 投递行为矩阵（受控夹具）

夹具：`tests/integration/build/TestTarget.app`（NSButton / 自绘 CanvasView / WKWebView 按钮）。
遮挡：`tests/integration/build/Cover.app`（另一个 App，窗口可摆到任意位置）。
判据：目标 UI **实际变化**（`state.json` 的计数），不是返回码。

| 用例 | 目标状态 | 投递方式 | 控件 | UI 真的变了 |
|---|---|---|---|---|
| E1 | 前台 | 51+58+窗口局部坐标 | NSButton | ✅ |
| E2 | 后台不遮挡 | 同上 | NSButton | ✅ |
| E3 | 后台且完全遮挡 | 同上 | NSButton | ✅ |
| E4 | 后台且完全遮挡 | AXPress | NSButton | ✅ |
| E5 | 后台不遮挡 | 坐标投递 | 自绘 Canvas | ✅ |
| E6 | 被遮挡 + AX 设 main/focused | 坐标投递 | NSButton | ✅ |
| E7 | 被遮挡 | 坐标投递 | 自绘 Canvas | ✅ |
| E8 | 被遮挡 | 坐标投递 | WKWebView 按钮 | ✅ |
| E9 | 被遮挡 | AXPress | WKWebView 按钮 | ❌ `-25206`（无 AXPress） |

结论：

- **坐标投递对遮挡免疫**。事件直接进目标进程事件队列，由字段 51 决定落到哪个窗口，
  不经过系统级 hit-test，因此不会被挡在前面的窗口截走。
- **AXPress 不是万能的**。Web 内容常常没有 `AXPress`（E9），必须有坐标投递兜底。
- **两者都不能省**，且唯一可信的判据是「UI 是否真的变了」。

### 光标可见性

| 场景 | 光标 | 判定字段 |
|---|---|---|
| 目标前台、点可见 | 显示（126×126 小窗跟随） | `cursor.suppressed=false` |
| 目标后台但点可见 | 显示（样式弱化） | `cursor.background=true` |
| 点被其它窗口盖住 | **整窗隐藏** | `cursor.suppressed=true`、`shown=false` |
| 目标最小化 / 不在当前 Space | **整窗隐藏** | `vis→minimized / off_screen` |
| 空闲 1.8s | 自动隐藏 | `shown=false` |

### 未验证（Not Tested）

- 其它 Space 的窗口、副屏负坐标、屏幕拼接
- Metal / 游戏 / 远程桌面类自绘窗口的坐标投递
- 投递对 key window 与键盘焦点的影响

---

## 七、v0.4.3 期望状态验证矩阵

判据从「UI 变没变」升级为「有没有变成期望的样子」。四分类与置信度：

| 场景 | 期望 | 前置 | 实际 | 结论 | 置信度 |
|---|---|---|---|---|---|
| 点 7，显示变成 7 | `7` | `0` | `7` | `success` | .95 |
| 点 8 但期望 7 | `7` | `0` | `8` | `failure` | .95 |
| 点 7 但界面没反应 | `7` | `0` | `0` | `failure` | .95 |
| 幂等「全部清除」，显示本来就是 0 | `0` | `0` | `0` | `already_satisfied` | .60 |
| 没给期望，UI 有变化 | — | — | — | `success`（弱判据） | .75 |
| 没给期望，UI 无变化 | — | — | — | `inconclusive` | .30 |
| 状态元素读不到 | `7` | — | — | `inconclusive` | .30 |

真机实测（Calculator，macOS 26.6）：

```
干净状态点 7        → success   （显示 "7"）
点 8 但期望 7       → failure   （显示 "8"，note: 目标被错误点击或产生了意外结果）
坐标投递 (654,511)  → success   （method=targeted）
```

坑：计算器显示值是 `‎7,778`（含 U+200E 与千分位逗号）。已做值规范化；
需要逐字节比较用 `--match strict`。

---

## 八、v0.4.3 并发隔离矩阵

工具：`tests/concurrency/`（listen-only 事件 tap + 责任归因）

| 断言 | 默认（AX） | 强制坐标投递 + 中途切前台 |
|---|---|---|
| 真实用户输入事件 | 968 条 | 977 条 |
| Agent 动作成功 | 8/8 | 8/8 |
| 归因于 Agent 的前台变化 | 0 | 0 |
| 会话流中的合成事件 | 0 | 0 |
| 目标计数按预期增长 | ✅ | ✅ |
| 目标窗口 ID 全程不变 | ✅ | ✅ |
| 目标 keyWindow/第一响应者不变 | ✅ | ✅ |

> 归因规则：前台变化前 0.4s 内有用户输入 → user；±1.5s 内有 harness 登记 → harness；否则 → agent。
> 没有真实用户输入时，测试记 `Not Tested`，不给「通过」。

---

## 九、v0.4.3 多显示器（数学验证，非真机）

| 场景 | 验证方式 | 结果 |
|---|---|---|
| 单屏 Retina | 真机 | ✅ |
| 右副屏（x > 主屏宽） | 纯函数 | ✅ |
| 左副屏（负 X） | 纯函数 | ✅ |
| 上方副屏（负 Y） | 纯函数 | ✅ |
| 混合缩放 2x/1x | 纯函数 | ✅ |
| 跨屏窗口 | 纯函数 | ✅ |
| Ghost 在副屏右缘 | 纯函数 | ✅ |

**真机多屏：Not Tested**（本机只有一块内建屏）。
