# 变更记录

格式遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
版本号遵循语义化版本。

## [Unreleased]

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
