---
name: workbuddy-third-hand
version: 0.6.1
description: WorkBuddy Third Hand —— 给 WorkBuddy 的第三只手，macOS 与 Windows 双平台。用各自平台的原生技术（macOS：ScreenCaptureKit + Accessibility + 进程级事件投递；Windows：Windows.Graphics.Capture + UI Automation + 定向窗口消息）在后台操作指定应用，优先不抢占用户真实鼠标、不切换前台、不抢键盘焦点，并且每次操作都读值验证。当用户要求「帮我操作另一个应用」「在后台完成桌面任务」「不要影响我正在用的鼠标」「读一下另一个应用里的信息」「点一下那个按钮」「同时在两个应用里干活」「用虚拟鼠标操作某个窗口」，或需要在计算器 / 记事本 / 文件资源管理器 / Finder / 文本编辑 / Electron 应用里做自动化时使用。
agent_created: true
---

# WorkBuddy Third Hand

给 WorkBuddy 的第三只手：在后台操作**别的**应用，而用户可以继续用鼠标和键盘。

核心承诺（也是验收标准）：**真实鼠标零位移、前台应用不切换、键盘焦点不被抢**，
同时目标应用里的 UI 真的发生了变化 —— 而且这个变化是被**读值验证**过的，不是「命令返回 0 就算成功」。

> **Third Hand is a tool sharpener, not a gatekeeper.** 它不加审批、不加阻塞、不做前台守卫；
> 它只负责把事情做对，并把「做到了没」如实报出来。

---

## 〇、第一步：判断平台（v0.6.0）

一个技能，两个引擎，**动作语义相同、底层能力不同**。开工前先确认自己在哪个系统上：

```bash
# macOS
wbcu version

# Windows（PowerShell / cmd）
wbcu.exe version
```

| 平台 | 引擎 | 二进制 | 底层技术 |
|---|---|---|---|
| macOS 14+ | `macos-ax` | `wbcu` | Accessibility + ScreenCaptureKit + CGEvent 定向投递 |
| Windows 10 22H2 / 11 | `windows-uia` | `wbcu.exe` | UI Automation + Windows.Graphics.Capture + 定向窗口消息 |

判据（不要靠猜）：

- macOS 上 `uname -s` 返回 `Darwin`，可执行文件是 `wbcu`。
- Windows 上 `$env:OS` 为 `Windows_NT`，可执行文件是 `wbcu.exe`。
- **不要拿 macOS 的命令去推断 Windows 的行为**，反之亦然。两边都有同名动作，但可用性不同：
  先跑 `wbcu capabilities --json`（或 `wbcu.exe capabilities --json`），按返回的
  `supported / partial / unsupported / not_tested` 决定用什么手段。

### 两平台能力差异（必须知道，不要假设一致）

| 动作 | macOS | Windows | 说明 |
|---|---|---|---|
| 语义操作（按控件标识点击） | ✅ AXPress | ✅ UIA Invoke/Toggle/Value | 首选路径，两边都不需要前台 |
| 后台点击无 Pattern 控件 | ✅ 进程级定向投递，对遮挡免疫 | ⚠️ 只能投递窗口消息，很多框架会忽略 | Windows 上成功率取决于目标框架 |
| 后台输入文本 | ✅ 写 AXValue | ✅ UIA ValuePattern；WM_CHAR 只在部分控件生效 | 优先 ValuePattern |
| 窗口截图（后台） | ✅ ScreenCaptureKit | ✅ Graphics Capture / PrintWindow 兜底 | 最小化窗口两边都取不到 |
| 虚拟光标 | ✅ NSPanel 覆盖层 | ✅ 分层窗口 + UpdateLayeredWindow | 纯显示，不代表点击成功 |
| 全局输入兜底 | `--allow-global` | `--allow-global` | **会移动真实鼠标**，必须用户明确同意 |

> Windows 引擎在 v0.6.0 交付的是**源码 + 交叉编译验证 + 纯逻辑单测**；
> 真机 GUI 验收（Calculator / 记事本 / 资源管理器、并发用户输入）需要一台有交互桌面的
> Windows 机器跑 `testapps\wbcu-guitests.exe`。**在本机跑过之前，`capabilities` 会如实把
> 相关项标成 `not_tested`，不要对外宣称已验证。**

---

## 一、先判断该不该用

按这个顺序想，**不要跳步**：

| 顺序 | 手段 | 什么时候用 |
|---|---|---|
| 1 | CLI / API / 连接器 | 目标系统有接口（git、curl、企业微信、云盘…）→ 直接调，不用 GUI |
| 2 | AppleScript / `open` / 快捷键（Win：PowerShell / COM / 应用自带 CLI） | 系统级、语义明确、无需看界面 |
| 3 | **本技能（后台 Computer Use）** | 只有 GUI 能完成，且用户不想被打扰 |
| 4 | 请用户自己点 | 需要人的判断、涉及不可逆高风险操作 |

本技能是**第 3 档**，不是万能替代品。能在终端里干的事不要动 GUI。

### 网页 vs 原生：先选对工具

| 目标 | 用什么 | 调用方式 |
|---|---|---|
| 网页内点击 / 输入 / 滚动 / DOM 读取 / 截图 | **`agent-browser`** | `agent-browser open <url>` → `snapshot` / `click` / `fill` / `scroll` / `screenshot` |
| 网页内容只读抓取（不需要执行 JS） | `WebFetch` / `WebSearch` | 直接调用，最省 |
| 页面展示给用户看 | `present_files`（内置右侧面板） | 渲染 HTML/URL |
| 原生桌面应用 | 本技能（`wbcu` / `wbcu.exe`） | 后台、不抢前台 |
| 混合任务 | 各自做自己那段 | WorkBuddy 负责串 |

**`agent-browser` 是 WorkBuddy 自带的 Browser Use 通道**（Vercel agent-browser CLI + 官方插件）。

```bash
export PATH="/Users/lang/.workbuddy/binaries/node/versions/22.22.2-6/bin:$PATH"   # macOS 本机路径示例
agent-browser open https://example.com     # 起 daemon（同一任务内复用）
agent-browser snapshot                     # 读 DOM / 可点元素
agent-browser click "@e3"                  # 或 CSS selector
agent-browser fill "#q" "关键词"
agent-browser get text "#result"           # 读结果验证
agent-browser close                        # 任务结束必须关，避免残留 Chromium
```

**红线不变：不要用坐标点击去点网页元素。** 网页有 DOM 就走 DOM，页面一滚动坐标就点错，
而且读不到页面状态来验证。

---

## 二、开工前必做

### macOS

```bash
wbcu capabilities --json     # ① 能力与权限：AX / 屏幕录制 / 输入注入各自是否可用
wbcu guard --list            # ② 已授权应用白名单
wbcu launch --app <bundleId> --json          # ③ 需要时才启动；**别用 open -a**
wbcu session start --app <bundleId> --json   # ④ 建会话
```

### Windows

```powershell
wbcu.exe capabilities --json                 # ① 能力矩阵（含 not_tested 的诚实标注）
wbcu.exe apps --json                         # ② 运行中的应用（pid / 窗口数 / 是否前台）
wbcu.exe launch --app calc --json            # ③ 后台启动（SW_SHOWNOACTIVATE）
wbcu.exe attach --app calc --json            # ④ 建会话（同名会话自动复用，--new 强制新建）
```

`launch` 与 `start/open` 的区别是硬区别：后台启动使用 `SW_SHOWNOACTIVATE` / `activates=false`，
用户前台不动；**已经在跑就什么都不做**。

- 权限不足 → 明确告诉用户缺哪一项，**不要试图绕过**（Windows 上不存在「提权绕过 UIPI」这种选项）。
- 会话 id 形如 `s26010112000012ab`。**两种寻址都行**：`--id <sid>` 或 `--app <令牌>`。
  **不要每步重新 attach。**
- Windows 应用令牌可以是：pid、`calc.exe`、`calc`、包族名、AUMID、窗口标题片段、`0x1A2B`（HWND）。
- `launch` 会按 用户路径 → System32 → App Paths → PATH 找可执行文件，并校验 PE 头；
  找不到就报 `app_not_found`，**不会**随便命中 PATH 里的同名脚本。也可以用系统自己启动再 `attach`。
- 结果 JSON 是**纯 ASCII**（中文转义成 `\uXXXX`），任何代码页下都能直接解析；
  0.6.0 时代的「按 GBK 解」不需要了。

---

## 三、标准工作流

### macOS

```bash
SID=$(wbcu session start --app com.apple.calculator --json | jq -r .session.id)

wbcu session inspect --id $SID --max 200          # 先 AX 树（便宜、精确）
wbcu session capture --id $SID --out /tmp/cap.png  # 需要像素再截图

wbcu session click --app com.apple.calculator --identifier Multiply --exact
wbcu session click --id $SID --text "全部清除" --exact
wbcu session click --id $SID --element 12
wbcu session click --id $SID --x 388 --y 557 --label "7"

wbcu session type --id $SID --text "要填的内容" --element 18
wbcu session verify --id $SID --expect "42"

# 把期望挂在动作上（v0.4.3+）：四分类 success / already_satisfied / failure / inconclusive
wbcu session click --id $SID --identifier One --exact --expect 7 --expect-el role:AXStaticText
wbcu session click --id $SID --text "全部清除" --exact --expect 0 --expect-el role:AXStaticText --idempotent

wbcu session end --id $SID
```

### Windows

```powershell
$s = wbcu.exe attach --app calc --json | ConvertFrom-Json
$sid = $s.data.session.id

wbcu.exe inspect --id $sid --max 200 --json        # UIA 树（含 patterns / automationId / rect）
wbcu.exe capture --id $sid --out cap.png --json    # Graphics Capture，失败自动退回 PrintWindow

# 语义优先：按 automationId 或控件名点击（不需要前台、不受遮挡影响）
wbcu.exe click --id $sid --automationid num7Button --json
wbcu.exe click --id $sid --name "7" --json
wbcu.exe click --id $sid --controltype Button --index 2 --json

# 读值验证：把期望挂在动作上（与 macOS 同一套四分类）
wbcu.exe click --id $sid --name "等于" --expect "15" --state automationid:CalculatorResults --json

wbcu.exe type   --id $sid --text "hello" --automationid 15 --expect "hello" --state automationid:15 --json
wbcu.exe key    --id $sid --combo ctrl+a --json
wbcu.exe scroll --id $sid --dy -3 --json
wbcu.exe verify --id $sid --expect "15" --state automationid:CalculatorResults --json

# 坐标点击必须声明坐标系（v0.6.3+）
#   window = 窗口左上角为原点（AI 从目标窗口截图里读出的坐标就用这个）
#   client = 客户区原点（不含标题栏与边框）
#   screen = 屏幕绝对坐标（默认，向后兼容）
wbcu.exe click --id $sid --x 960 --y 11 --coord-space window --json
wbcu.exe click --id $sid --x 12 --y 40 --coord-space client --json

wbcu.exe session end --id $sid
```

### 截图与遮挡（v0.6.3）

- `capture` 走 **Windows Graphics Capture 持久会话**（`method=graphics_capture_live`），
  绑定的是目标 HWND，**和当前前台窗口无关**：用户切到别的应用、目标被完全遮挡，
  截到的依然是目标窗口自己的画面。
- 连续截图复用同一个会话（Latest Frame Wins），命中时 0 等待；只有首帧要等。
- 降级顺序：持久会话 → 一次性 WGC → PrintWindow。**任何一级都不会退化成截前台窗口**。
  拿不到就如实报错，不做假截图。
- 最小化窗口没有 DWM 合成表面，捕获会明确报告失败，需要先还原窗口。
- 遮挡只影响 Ghost Cursor 的透明度（变淡），**不影响捕获、UIA 与后台输入**。

**验收只看 `verification.result`，不看退出码。** 四分类的读法与 macOS 完全一致：

| result | 含义 | 能不能对用户说「做完了」 |
|---|---|---|
| `success` | 确认产生了预期结果 | ✅ 可以 |
| `already_satisfied` | 操作前就已满足期望（幂等） | ⚠️ 只能说「已经是这个状态」 |
| `failure` | 实际与期望不符 | ❌ 必须如实说失败 |
| `inconclusive` | 证据不足（读不到状态 / 没给期望） | ❌ 不能说成功，补一个 `--expect` 再来 |

---

## 四、操作优先级（硬规则，两平台同一套阶梯）

```
语义动作（AX / UIA Pattern） → 定向投递（进程/窗口消息） → 坐标点击 → 全局输入（需批准）
```

1. **语义优先**：macOS `--element/--text` 走 AXPress；Windows `--automationid/--name` 走 UIA Pattern。
   不激活、不需要坐标、对遮挡免疫。
2. **其次定向投递**：macOS 用 `postToPid` + 窗口局部坐标；Windows 用 `SendMessageTimeout` 发到**最深子窗口**。
   Windows 上请注意：返回成功只表示消息被处理，**不表示点击被消费**（WPF/Electron/自绘界面常常忽略）。
3. **最后才全局输入**：`--allow-global` 会真的移动用户鼠标。**没有用户明确同意，绝不加这个参数。**
   也不许用「先移过去点一下再移回来」伪装无干扰——那是欺骗。

---

## 五、必须遵守的约束

- **鼠标分离**：Agent 光标是独立可视化层，与系统鼠标无关。永远不要读写真实指针位置来「同步」。
- **不切换前台**：除非用户要求，不调 `activate` / `SetForegroundWindow` / `open -a`。
  Windows 上 `--foreground` 与 MSIX 启动会激活窗口 —— 这是系统行为，用了就要在报告里说清楚。
- **不抢键盘焦点**：`key` 走定向消息，不进全局事件流。
- **失败就说失败**：`ok:false` / `failure` / `inconclusive` 一律如实报告，禁止编造「已完成」。
- **高风险先问**：删除、提交、发送、支付、覆盖文件——先描述将要发生什么，等用户确认。
- **结束要清理**：`session end --id <sid>`；长任务中断也要 end（或 `ghost stop` + `session end --all`）。

---

## 六、诊断命令

```bash
wbcu capabilities --json     # 能力矩阵（含未实机验证项）
wbcu contract --json         # 跨平台契约：动作名 / 错误码 / 验证口径（两平台同一份）
wbcu doctor                  # 引擎与技能版本一致性、安装路径、UIA/捕获可用性、会话堆积
wbcu selftest --json         # 纯逻辑自检（CI 可跑，不需要交互桌面）
wbcu perf stats              # 实测 P50/P95（没有实测数据就没有数字）
wbcu trace start|report|stop # 前台切换归因：是谁抢了前台
wbcu experience list|show|clear
```

macOS 专属诊断：`occlusion` / `vis` / `displays` / `compat` / `focus` / `session prune`。
Windows 对应手段：`windows --app X`（z 序与几何）、`session state`（DPI 与存活）、
`capabilities`（Graphics Capture 是否可用）。

排错顺序：
1. `result=inconclusive` → 补 `--expect`，别急着换手段。
2. 点不动 → 先 `inspect` 看有没有 Pattern / 元素是否 rect 为 0（虚拟化折叠）。
3. 还是不行 → 看 `capabilities`：`custom_drawn_ui` 与 `electron_apps` 本来就是 `partial`。

---

## 七、能力边界（实测，别硬扛）

### macOS

| 场景 | 结果 | 该怎么绕 |
|---|---|---|
| 标准控件（NSButton / 输入框 / 菜单） | ✅ AX + 定向都成 | 直接用 |
| 被其他窗口完全遮挡 | ✅ 定向投递可点 | 照常操作 |
| 自绘视图（Canvas） | ⚠️ 取决于是否 `acceptsFirstMouse` | 先 AX；不行请用户把窗口露出来 |
| WKWebView 里的按钮 | ✅ 走 AX | 坐标事件对它无效 |
| 非激活窗口里打字 | ❌ 没有 field editor | 用 `session type`（写 AXValue） |
| 依赖 key window 的快捷键（Cmd+W） | ❌ 常无效 | 改用 AX 点关闭按钮 |

### Windows

| 场景 | 结果 | 该怎么绕 |
|---|---|---|
| 原生 Win32 控件（Button/Edit/CheckBox/ComboBox） | ✅ UIA Pattern 齐全 | 直接用 `--automationid` |
| WPF / WinUI 3 控件 | ✅ UIA Provider 完整 | 同上 |
| 自绘界面（Canvas / 游戏 / 部分国产客户端） | ⚠️ 无 Pattern，只能窗口消息或坐标 | 先 `inspect` 确认；失败如实报 |
| Electron 应用 | ⚠️ 默认关闭无障碍树 | 能读到树就用 UIA；读不到报限制 |
| 最小化窗口 | ❌ 无合成表面，截图必失败 | 先还原窗口（`ShowWindow`），或只做语义操作 |
| 受 DRM 保护的窗口 | ❌ 截图为黑 | 不尝试绕过，直接报 `capture_failed` |
| 目标以管理员身份运行（UIPI） | ❌ 消息与 UIA 被挡 | 如实报 `permission_denied`，**不做提权** |
| MSIX 应用启动 | ⚠️ `ActivateApplication` 一定带到前台 | 报告里说明；或用已运行的实例 |

**遇到新兼容性问题不要绕开就忘**：记录「应用 + 版本 + 症状 + 最小复现」，写进
`docs/capability-matrix.md`（macOS）/ `docs/windows-capability-matrix.md`（Windows）。

---

## 八、给用户看的东西

- 虚拟光标可关：`--no-ghost` 或 `ghost hide`，**关掉不影响操作**。
- Windows 上覆盖层是独立进程（`ghost status` 可查），点击穿透、不接受用户点击、不抢前台。
- 结束报告要包含：做了什么、每步 `verification.result`、真实鼠标是否移动、前台是否变化、有没有残留进程/会话。

---

## 九、参考

- 最小可照抄流程：`examples/quickstart.md`
- 命令行与退出码：`references/api.md`
- 架构：`docs/architecture.md`
- 安装：`docs/installation.md`（macOS）/ `docs/windows-installation.md`（Windows）
- 能力矩阵：`docs/capability-matrix.md`（macOS）/ `docs/windows-capability-matrix.md`（Windows）
- 跨平台契约：`contract/README.md`（动作、结果、验证口径的唯一权威定义）
