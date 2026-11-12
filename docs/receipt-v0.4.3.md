# 部署回执 · WorkBuddy Third Hand v0.4.3

> 可靠性审计版。上一版回答「能不能在后台点中」，这一版回答
> **「怎么证明点对了」「用户在用电脑时还成不成立」「判定本身有没有漏」**。
> 所有结论都标了判定方式；没测的一律写 `Not Tested`。

| 项 | 值 |
|---|---|
| 版本 | **0.4.3** |
| 分支 | `feat/v0.4.3-reliability-audit`（基线 `c2a031e` = v0.4.2） |
| 环境 | macOS 26.6 (25G72)，MacBook M5 arm64，`MacOSX26.5.sdk` + Swift 6.3.3 |
| 显示器 | **单块内建屏** 1470×956 @2x（多屏真机场景因此 Not Tested） |
| 安装状态 | **未安装到 `~/.local/bin`** —— 按你的要求不覆盖 v0.4.2 的稳定安装；验证用的是仓库内 `bin/wbcu` |
| 判据 | 目标 UI 的实际状态（`precondition → actual`），不是命令返回码 |

---

## 1. 实际检查的源码位置

| 文件 | 审计结论 |
|---|---|
| `src/GhostCursor/Ghost.swift` | 定位用 `NSScreen.screens.first` + 主屏夹取 → 副屏会画错位（已修） |
| `src/InputDispatcher/Visibility.swift` | `layer == target.layer` 漏掉高层级浮层（已修）；Dock 报全屏 bounds 会误判（已处理） |
| `src/InputDispatcher/Targeted.swift` | 焦点取证 54ms 在关键路径；AX 指纹被算进 `dispatch`；光标 socket 往返被算进 `dispatch`（均已修） |
| `src/SessionManager/Session.swift` | 学习条件只认 `changed`，`already_satisfied` 学不到（已修） |
| `src/Support.swift` / `Probe.swift` | 另有 2 处手写 y 翻转 → 已收敛到统一转换器 |
| `tests/integration/*` | 夹具缺少「同一应用第二窗口」「浮层面板」入口（已补） |

---

## 2. 发现的真实问题

| # | 问题 | 证据 | 级别 |
|---|---|---|---|
| 1 | 「UI 变了」被当作成功，误点抓不到 | 点 8 时 UI 确实变了，v0.4.2 会判成功 | P0 |
| 2 | 幂等操作被冤枉成失败 | 「全部清除」在显示已为 0 时无变化 → v0.4.2 判 failure | P0 |
| 3 | 没有并发使用的归因手段 | 只能断言 `frontBefore != frontAfter`，正是你指出的错误做法 | P0 |
| 4 | 高层级浮层漏判 | 旧规则按 `layer` 相等过滤，NSPanel(3)/Popover 被忽略 | P1 |
| 5 | Dock 报 `1470×956` 全屏 bounds | `wbcu occlusion` 实测输出 | P1 |
| 6 | 副屏坐标会被夹回主屏 | `Ghost.positionWindow` 用主屏宽高做 clamp | P1 |
| 7 | 未文档化字段无边界声明 | 51/58/91/92 散落在投递函数里，换系统版本无退让 | P1 |
| 8 | 显示值含 LRM 与千分位 | 计算器返回 `‎7,778`，逐字符比较误判 | P1（实测发现） |
| 9 | 焦点取证 54ms 在关键路径 | `timing.focusMs` P50 53.8ms | 性能 |
| 10 | AX 指纹被算进 dispatch | `dispatchMs` P50 106ms，其中大部分是扫树 | 计时诚实性 |
| 11 | `osascript set miniaturized` 报 -10006 | 夹具无法造真实最小化状态（v0.4.2 遗留假状态风险） | 测试有效性 |

---

## 3. 修复方案与代码差异

### 3.1 新增模块（4 个）

| 文件 | 职责 |
|---|---|
| `src/InputDispatcher/ExpectedState.swift` | `ExpectedStateVerifier`：precondition/target/action/expected/actual/method/confidence + 四分类 |
| `src/InputDispatcher/DisplayGeometry.swift` | `DisplayCoordinateTransformer`：CG/AppKit/窗口局部/捕获像素 四空间互转 |
| `src/InputDispatcher/LegacyFields.swift` | `EventFieldCompat`：51/58/91/92 + 私有符号的版本闸门与逐应用退让 |
| `src/Accessibility/Focus.swift` | `FocusProbe`：keyWindow / focusedUIElement（单次 IPC） |
| `src/SessionManager/Diag.swift` | `wbcu displays / compat / focus` 三个只读诊断命令 |

### 3.2 关键差异

```
- // 旧：同层才算遮挡
- blockers = above.filter { $0.layer == target.layer && $0.alpha > 0.02 }
+ // 新：按真实前后次序，只排除自身覆盖层与系统外壳
+ blockers = above.filter { $0.id != targetId && !isOwnOverlay($0)
+                           && $0.alpha > 0.02 && $0.bounds.intersects(target.bounds)
+                           && !looksLikeShell($0) }
```

```
- // 旧：主屏夹取
- guard let screen = NSScreen.screens.first else { return }
- originCG.x = max(0, min(originCG.x, screen.frame.width - GHOST_WIN_SIZE))
+ // 新：按点选屏，在该屏 CG 矩形内夹取
+ let disp = DisplayCoordinateTransformer.display(containingCG: model.display)
+ originCG.x = max(disp.cgFrame.minX, min(originCG.x, disp.cgFrame.maxX - GHOST_WIN_SIZE))
```

```
- // 旧：变了就算成功
- if let c = out.changed { out.ok = c }
+ // 新：四分类，显式期望优先
+ out.verifyReport = ExpectedStateVerifier.evaluate(...)
+ out.result = out.verifyReport!.result.rawValue   // success/already_satisfied/failure/inconclusive
+ out.ok = out.verifyReport!.result.ok
```

```
- out.physicalCursorPreserved = hypot(...) < 1.5
+ // 动作窗口内有真实硬件输入 → 归属不明，记 null 而不是给个假答案
+ let userBusy = min(sinceMove, sinceClick, sinceKey) < elapsedSec + 0.05
+ out.physicalCursorPreserved = userBusy ? (moved < 1.5 ? true : nil) : (moved < 1.5)
```

---

## 4. 跑过的测试

### 4.1 单元（任何机器可跑）

```
./bin/wbcu selftest   →   53/53 通过
  [1..8] 原有参数/AX/坐标/会话/错误码 27 项
  [9]    坐标空间 DisplayCoordinateTransformer   15 项（新增）
  [10]   期望状态 ExpectedStateVerifier          11 项（新增）
./tests/unit/run.sh   →   源码卫生 6 项全绿
```

### 4.2 GUI 回归（6 条，全部实跑）

| 测试 | 结果 |
|---|---|
| `cursor-window-bounds.sh` | ✅ 126×126、尖端在窗口内、hide/空闲隐藏、贴边夹屏 |
| `background-targeted-click.sh` | ✅ count 0→1、`method=targeted`、最小化后 `failureReason=target_minimized` |
| `window-switch-isolation.sh` | ✅ 点击途中切窗口仍命中、前台始终是用户应用、光标不漂移 |
| `occlusion-behavior.sh` | ✅ `fully_occluded`、光标整窗隐藏、禁止 `ok=true + uiChanged=false` |
| `occlusion-layers.sh` | ✅ layer=3 / layer=8 / 部分遮挡（可见 0.467）/ 同应用第二窗口 / 遮挡下光标抑制但点击生效 |
| `ghost-cleanup.sh` | ✅ socket / 进程 / 窗口全部清干净 |

### 4.3 真实应用矩阵

| 应用 | AXPress | 坐标投递 | 期望状态 | 备注 |
|---|---|---|---|---|
| Calculator | ✅ 干净状态点 7 → 显示 7（success） | ✅ (654,511) → success | ✅ 误点判 failure | 清除键标签在「全部清除/C」间切换 |
| TextEdit | n/a | Not Tested | ✅ AXValue 往返一致 | 后台按键需 field editor |
| Finder | Not Tested | Not Tested | Not Tested | AX 树 863 节点可读；无稳定标识 |
| Safari | Not Tested | Not Tested | Not Tested | 涉及用户浏览会话与登录态，需单独授权 |
| Electron | Not Tested | Not Tested | Not Tested | 本机无安全可驱动的实例 |

---

## 5. 未通过 / 未测试项目

| 项 | 状态 | 原因与风险 |
|---|---|---|
| 多显示器真机（右/左/上/下、混合缩放） | **Not Tested** | 本机只有一块内建屏。只验证了纯函数与选屏逻辑；副屏真机行为未知 |
| Safari 内操作 | **Not Tested** | 会动到用户正在用的浏览会话，需授权后单独执行 |
| Electron / 多窗口应用 / 自绘重界面 | **Not Tested** | 无安全可驱动实例 |
| Popover / Tooltip / 菜单的遮挡 | **部分覆盖** | 用 layer=3/8 的 NSPanel 近似；真正的 Popover 未单独构造 |
| 半透明遮挡物的像素级判定 | **未实现** | 只按整窗 alpha 阈值；文档写明是保守估计 |
| 跨 Space 的窗口 | **Not Tested** | 判定路径有（`off_screen`），未造真机场景 |
| 目标被遮挡时的 `visibleFraction` 绝对精度 | **估算** | 15×15 采样，±1 格误差 |
| `/tmp/wbcu-lab` 之外的真实业务应用（ERP/WPF 类） | **Not Tested** | 未在本轮范围内 |

**发布风险**：多显示器是最大未知项。代码路径已按点选屏，但真机没验过；
在副屏上使用前建议先用 `wbcu displays` 确认几何，再看 `wbcu vis` 的输出是否符合直觉。

---

## 6. 并发用户操作测试记录

工具：`tests/concurrency/ActivityProbe.swift`（listen-only 事件 tap）+ `analyze.py`（归因）

### 6.1 运行 1 —— 默认（AX 优先）

```
用户输入事件 968 条（mouseMoved / leftMouseDown / keyDown / scroll）
前台采样 260 次；前台变化 0 次
Agent 动作 8 次：{'success': 8}，method=['ax']
会话流中的注入事件：0
```

### 6.2 运行 2 —— 强制坐标投递 + 脚本中途切前台

```
用户输入事件 977 条
前台变化 3 次：用户 1（leftMouseDown: Finder→Codex）/ 脚本 2（harness 登记）/ Agent 0
Agent 动作 8 次：{'success': 8}，method=['targeted']
会话流中的注入事件：0
```

两次都通过全部 10 项断言，包括：目标计数按预期增长、目标窗口 ID 全程不变、
目标 keyWindow/第一响应者不变、无归因于 Agent 的前台变化。

**归因规则**（写死在 `analyze.py`，避免事后解释）：
前台变化时刻前 0.4s 内有用户输入 → `user`；在 ±1.5s 内有 harness 登记 → `harness`；否则 → `agent`。

**能力边界**：这套测试要求用户真的在操作电脑。跑之前会等最多 40s 检测真实输入，
没有就记 `Not Tested`（`concurrency-report.json` 里 `notTested: true`），不给「通过」。

---

## 7. 多显示器测试结果

| 场景 | 方式 | 结果 |
|---|---|---|
| 单显示器 Retina | 真机（本机） | ✅ 点翻转、窗口局部、捕获像素往返 |
| 外接屏在右侧 | 纯函数（注入假显示器） | ✅ 归属与换算正确 |
| 外接屏在左侧（负 X） | 纯函数 | ✅ 归属正确，y 仍用主屏高翻转 |
| 外接屏在上方（负 Y） | 纯函数 | ✅ 归属正确 |
| 两侧缩放不同（2x / 1x） | 纯函数 | ✅ 捕获像素换算正确 |
| 窗口跨屏边界 | 纯函数 | ✅ 窗口局部坐标以窗口原点为准，与屏幕无关 |
| Ghost 在副屏右缘 | 纯函数 | ✅ 夹取落在该屏内（不再被夹回主屏） |

> 除第一行外全部是**数学验证**，不是真机验证。第三方若有双屏环境，请直接跑
> `wbcu displays` + 一次 `wbcu act` 并比对 `cursor.winCGX/winCGY` 与点击点。

---

## 8. 平均延迟与 P95

场景：`session click --text 7 --exact`（经验命中），Ghost 开启，fast 模式。

| 指标 | P50 | P95 |
|---|---|---|
| **端到端（计算器，真实应用）** | **73.9 ms** | **85.4 ms** |
| resolve（经验命中回查） | 26.9 ms | 31.2 ms |
| dispatch（AXPress） | 2.1 ms | 8.5 ms |
| verify | 11.0 ms | 15.7 ms |
| visibility（新增） | 0.7 ms | 1.2 ms |

对照 v0.4.0 记录的 108 / 124 ms：**更快**。原因是把「不属于输入的成本」从关键路径移走
（焦点取证按需、有期望时不扫整树、光标反馈出计时）。

受控夹具上 P50 167.7 ms —— 其中 101 ms 是夹具自己的 `AXPress` 同步处理时间（同一引擎在计算器上只有 2.1 ms），
属于目标应用差异，不是引擎回归。

资源：Ghost daemon 空闲 **CPU 0.4% / RSS 33 MB**；交互时峰值 5.6%。

---

## 9. 与 v0.4.2 的能力对比

| 维度 | v0.4.2 | v0.4.3 |
|---|---|---|
| 成功判据 | UI 变没变 | **期望状态比对**（四分类 + 置信度） |
| 误点检测 | 不能 | **能**（点 8 期望 7 → failure） |
| 幂等操作 | 判失败 | **already_satisfied**（且不声称点击被消费） |
| 无变化 | 判失败 | **inconclusive**（证据不足，不冤枉） |
| 并发证据 | 「前台没变」弱断言 | **事件时间线 + 责任归因**（0 次归因 Agent） |
| 硬约束断言 | 简单 before≠after | 有真实输入时记 **null（归属不明）** |
| 遮挡判定 | 同层才算 | **按真实 z 序**，浮层/Popover 不再漏 |
| 外壳窗口 | 会误判全屏遮挡 | **suspectedShell** 单列，不参与面积 |
| 副屏坐标 | 夹回主屏 | **按点选屏** |
| 未文档化字段 | 散落、无边界 | **兼容层**：版本闸门 + 逐应用退让 |
| 焦点取证 | 无 | 有（按需，`--focus-check`） |
| 计算器 P50 | 108 ms（v0.4.0 记录） | **73.9 ms** |

---

## 10. Git / PR / 版本

```
分支   feat/v0.4.3-reliability-audit（从 c2a031e 起）
提交   见 git log（代码 + 文档各一次）
版本   0.4.3（未打 tag，未安装 —— 等审查通过）
```

**没有做**的两件事，等你决定：

1. `bash scripts/install.sh`（覆盖 `~/.local/bin/wbcu`）—— 会替换掉稳定版 0.4.2
2. `git tag v0.4.3` + Release —— 门禁要求「审查通过后再合并、发布」

---

## 请重点审这几处

1. **`already_satisfied` 的 `.60` 置信度口径**是否合理：我们明确写「不能证明点击被消费」，
   这个保守程度是否足够？
2. **`looksLikeShell` 的判据**（`layer ≥ 20 且面积 ≥ 屏幕 55%`）会不会漏掉某些真实的
   全屏系统覆盖层？或者反过来把一个真正的大面积浮窗当成外壳而放行？
3. **归因窗口 0.4s** 是否合适：用户点完再切应用可能超过 0.4s，会被误归因成 Agent。
4. **`--focus-check` 默认关闭**是否可接受：打开会让每次点击多 ~27ms，但能抓到
   「应用还在前台、keyWindow 被换掉」这类问题。
5. **多显示器真机**：如果你有双屏，请跑 `wbcu displays` 与一次 `wbcu act`，
   把 `cursor.winCGX/winCGY` 和实际点击位置对比一下 —— 这是目前最大的未知项。
