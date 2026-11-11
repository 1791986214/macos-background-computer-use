# 部署回执 · WorkBuddy Third Hand v0.4.2

> 供第三方审查。所有结论都标注了**判定方式**；没有实测过的一律写 `Not Tested`。

| 项 | 值 |
|---|---|
| 版本 | **0.4.2** |
| 提交 | `c2a031e` `fix: 虚拟光标绑定目标窗口 + 投递结果不再静默成功（v0.4.2）` |
| 标签 | `v0.4.2` |
| 日期 | 2026-11-12 |
| 环境 | macOS 26.6 (25G72)，MacBook M5 arm64，`MacOSX26.5.sdk` + Swift 6.3.3 |
| 二进制 | `bin/wbcu`，888 328 B，SHA256 `2c8da6c183a851d7…` |
| 判据 | 目标 UI **实际变化**（受控夹具的计数/文本），不是命令返回码 |
| 零干扰判据 | 物理鼠标位移 < 1.5 px + `frontmostApplication` 不变 + `targetActive=false` + `idle` 探针确认期间无用户输入 |

---

## 1. 修改文件

| 文件 | 性质 | 说明 |
|---|---|---|
| `src/GhostCursor/Ghost.swift` | 重写窗口层 | 整屏 `NSPanel` → 126×126 跟随小窗；flipped 视图；同步布局；空闲自动隐藏 |
| `src/InputDispatcher/Visibility.swift` | **新增** | `TargetWindowVisibilityManager`，可见性/遮挡/最小化判定 |
| `src/InputDispatcher/Targeted.swift` | 改 | 投递前查可见性；`ActionOutcome` 增加裁决字段；新增 `actionReport`、`failureReasonFor`、`cmdVis`；`ghostGoto` 带 pid |
| `src/SessionManager/Session.swift` | 改 | 复用 `actionReport`；失败退出码 3 |
| `src/SessionManager/Perf.swift` | 改 | `StageTiming` 增加 `visibilityMs` |
| `src/main.swift` | 改 | 版本 0.4.2；注册 `vis` 子命令 |
| `scripts/build.sh` | 改 | overlay Info.plist 版本号 |
| `tests/integration/Fixture.swift` | 改 | 全事件监视器（记录窗口号 + 字段 51/58/91/92 + locationInWindow）；文件控制通道（minimize/hide）；Web 按钮真实矩形（JS `getBoundingClientRect`） |
| `tests/integration/Cover.swift` | **新增** | 遮挡/前台夹具（一个可摆到任意位置的「别的 App」） |
| `tests/integration/Poster.swift` | 改 | `keywin` 模式（AX 设 main/focused 后投递）、`--minimize` |
| `tests/integration/matrix-v042.sh` | **新增** | 9 例投递行为矩阵 |
| `tests/lib-lab.sh` | **新增** | 实验台公共函数（起目标/遮挡/几何/计数/空闲守卫） |
| `tests/regression/{cursor-window-bounds,background-targeted-click,window-switch-isolation,occlusion-behavior,ghost-cleanup}.sh` | **新增** | 5 条验收回归 |
| `tests/regression/no-focus-steal.sh` | 改 | 修两处未定义变量（`$FINAL`/`$MISMATCH`），此前在 `set -u` 下中途崩、属「假通过」 |
| `tests/run-all.sh` | 改 | `all` 模式纳入 5 条新回归 |

---

## 2. 光标结构变化

### 2.1 v0.4.1（问题所在，源码原文）

```swift
panel = GhostPanel(contentRect: screen.frame, ...)   // Ghost.swift:212
view  = GhostView(frame: screen.frame)               // Ghost.swift:226
panel.orderFrontRegardless()                         // :231
```

面板与画布都是**整屏**。透明 ≠ 无感：它是用户前台窗口上方一整块全屏窗口，
任何窗口级合成 / 录屏 / 窗口列表都能看到它；光标每次移动，整块区域都要重绘。

### 2.2 v0.4.2

| 维度 | v0.4.1 | v0.4.2 |
|---|---|---|
| 窗口尺寸 | `screen.frame`（整屏） | **126×126**（`GHOST_WIN_SIZE`） |
| 画布 | `GhostView(frame: screen.frame)` | `GhostView(126×126)`，**flipped**（左上原点，y 向下，与 CGEvent 同向） |
| 定位 | 窗口固定在原点，只在画布上画 | **窗口跟着光标走**：`origin = 全局点 − 尖端偏移`，夹屏后用实际窗口原点反推尖端 |
| 遮挡行为 | 无判断，`draw()` 只看 `model.visible` | 每帧前查 `pointVisible`；不归目标窗口 → **整窗 `orderOut`** |
| 空闲 | 一直挂着 | 1.8 s 无命令自动隐藏（对齐 Codex `onscreen=false`） |
| 层级 | 102 | 102（不变） |
| 焦点 | LSUIElement | LSUIElement（不变，v0.4.1 的修复保留） |

硬件/系统侧依据：Codex `Software Cursor` 实测 `wid=730 layer=102 alpha=1.0 126×126 @584,696`，
空闲 `onscreen=false`。本轮把尺寸与空闲行为对齐到同一档。

---

## 3. Targeted 投递：10 项复查

上一轮交接列出 10 个待查点。逐条给结论，每条都标判定方式。

| # | 待查点 | 结论 | 判定方式 |
|---|---|---|---|
| 1 | 窗口号是否有效（51 字段） | **正确** | 夹具全事件监视器回读：`f51 == windowNumber == 4173` |
| 2 | 字段 58 该写什么 | **未文档化、语义不明**；写 `12345` 可稳定工作 | 回读：合成事件 `f58=12345`；真实物理事件 `f58` 是 5.8e13 量级，说明它不是常量语义。保留现有取值，标注为风险项 |
| 3 | Y 轴方向 | **正确** | 全局点 y=180 → 事件 `locationInWindow.y=656`，窗口内容高 732，`732−76=656`，与「窗口局部左上原点」一致；按钮被点中 |
| 4 | 点 vs 像素（Retina） | **正确（按 point）** | 2x 屏上直接点中 NSButton；未做像素换算，也不需要 |
| 5 | 标题栏偏移 | **正确** | `windowFrame` 取 `CGWindowList` bounds（含标题栏），`windowLocal` 直接减原点；实测点中 |
| 6 | 非激活窗口拒收（firstMouse） | **不成立，事件不被吞** | 后台未激活时 NSButton 仍触发（E2/E3）；说明进程级投递的 down/up 未被 `acceptsFirstMouse` 拦下 |
| 7 | 遮挡是否打偏到遮挡者 | **不会** | E3/E7/E8：完全遮挡下仍点中目标；事件进目标进程队列，由字段 51 决定落窗，不经过系统 hit-test |
| 8 | 最小化状态 | **会被拒，且现在如实报错** | 夹具真实最小化后：`vis→minimized`，`ok=false`，`failureReason=target_minimized` |
| 9 | 其它 Space / 已关闭窗口 | 代码路径已实现（`off_screen` / `unknown`），**Not Tested** | 未在真机造出跨 Space 状态；不伪造结论 |
| 10 | 是否会改动 key window / 键盘焦点 | **Not Tested** | 本轮未测；如需断言请补 `keyWindow` 前后对比用例 |

---

## 4. 测试记录

### 4.1 投递行为矩阵（`tests/integration/matrix-v042.sh`，可重复）

受控目标：`TestTarget.app`（NSButton / 自绘 CanvasView / WKWebView 按钮）。遮挡由 `Cover.app` 制造。

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
| E9 | 被遮挡 | AXPress | WKWebView 按钮 | ❌ `AXPress -25206` |

> E9 的意义：Web 内容不是都有 `AXPress`，所以 targeted 兜底是必需的；两者必须并存。

### 4.2 五条验收回归（v0.4.2 发布门禁）

| 测试 | 结果 | 关键断言输出 |
|---|---|---|
| `cursor-window-bounds.sh` | **全部通过** | 窗口 126×126；尖端 (555,180) 落在窗口 (531,156)+126×126 内；hide 后 `shown=false`；空闲 2.6s 后 `shown=false`；贴边 `winCGX/Y ≥ 0` |
| `background-targeted-click.sh` | **全部通过** | count 0→1；`method=targeted`；`frontAppPreserved=true`；`physicalCursorPreserved=true`；最小化后 `vis→minimized`、`failureReason=target_minimized` |
| `window-switch-isolation.sh` | **全部通过** | 点击途中切窗口，count 0→1；前台始终 `com.tencent.wbcu.cover`；光标位置 (555,180) 不漂移 |
| `occlusion-behavior.sh` | **全部通过** | `vis→fully_occluded`（可见比例 0）；`pointVisible=false`；`cursor.suppressed=true` 且 `shown=false`；遮挡下点击仍点中且已验证；遮挡解除后恢复显示 |
| `ghost-cleanup.sh` | **全部通过** | stop 后 socket 删除、进程退出、屏上无残留覆盖层窗口 |

### 4.3 其它

- `tests/unit/run.sh`：selftest **27/27**，源码卫生 6 项全绿
- `tests/regression/no-focus-steal.sh`：daemon 启动前台未变、5 次点击全程前台未变、目标未被激活、计算器显示 15；
  收尾阶段因检测到用户真实输入（idle 0s < 耗时 4s）**主动放弃判定**，记为 SKIPPED 而非通过

### 4.4 性能

可见性判定加入后（`visibilityMs`）：

```
mode=ax ok=True vis=background  visibilityMs=14.0 totalMs=265.7   ← 首次，窗口列表冷启动
mode=ax ok=True vis=background  visibilityMs=0.6  totalMs=182.1
mode=ax ok=True vis=background  visibilityMs=0.6  totalMs=165.3
mode=ax ok=True vis=background  visibilityMs=7.6  totalMs=169.4
mode=ax ok=True vis=background  visibilityMs=0.6  totalMs=180.3
```

P50 **0.6 ms**。每次动作只调用一次，无后台扫描线程，v0.4.0 的常驻 SCK / 经验库 / 单次验证策略全部保留。

---

## 5. 前台 / 物理鼠标保持情况

| 场景 | 前台 | 物理鼠标 |
|---|---|---|
| 光标 daemon 启动 | 未变 | 未动 |
| 后台 targeted 点击 | 未变（`frontAppPreserved=true`） | 未动（`physicalCursorPreserved=true`） |
| 点击途中有窗口切换 | 始终是用户应用，从未出现 `com.workbuddy.thirdhand.overlay` | 未动 |
| 遮挡场景 | 未变 | 未动 |
| 跨 5 次连续点击 | 未变（`no-focus-steal.sh`） | 未动 |

`actionReport` 每次都返回 `frontBefore` / `frontAfter` / `physicalCursorPreserved`，可事后审计。

---

## 6. 与 Codex 对照结论

| 维度 | Codex（实测） | Third Hand v0.4.2 |
|---|---|---|
| 光标载体 | 独立 `Software Cursor` 窗口，126×126 | 独立跟随小窗，126×126 |
| 层级 | layer 102 | layer 102 |
| 空闲行为 | `onscreen=false` | 1.8s 自动隐藏（`shown=false`） |
| 与目标窗口关系 | 窗口级绑定，绘制范围局限在小窗内 | 绑定 `windowId + 窗口局部坐标`，窗口移动 100ms 重算 |
| 遮挡时 | 未取证 | 判断点归属，不归目标则整窗隐藏 |
| 输入通道 | 未取证（推测进程级） | `postToPid` + 字段 51/58 + 窗口局部坐标 |
| 是否激活目标 | 否 | 否（`targetActivated=false`） |
| 是否移动物理鼠标 | 否 | 否（逐次断言） |

**不可宣称的**：我们没有 Codex 的源码，以上是黑盒实测对齐，不是「实现相同」。
「Codex 用哪种投递方式」我们没有证据，不做推断。

---

## 7. macOS 兼容性限制

| 限制 | 影响 | 应对 |
|---|---|---|
| 字段 51/58/91/92 未文档化 | 系统更新可能失效 | 全部用「UI 是否真的变了」验证；失效时退回 AXPress；`docs/compatibility.md` 记录 |
| `CGEventSetWindowLocation` 需 `dlsym` | 符号消失则降级 | 已做 nil 兜底 |
| 多显示器/异形排布 | 当前统一以主屏高度做 CG↔AppKit 翻转，副屏负坐标场景 **Not Tested** | 已知限制，未验证不宣称 |
| 其它 Space | 判定路径存在，**Not Tested** | `off_screen` 状态可返回，未造真机场景 |
| 最小化窗口 | 坐标投递被拒 | 如实报 `target_minimized`，不再静默 ok |
| 需要 TCC 辅助功能授权 | 无授权时 AX 全链路不可用 | `perm` 自检 + 测试缺授权记 SKIPPED |
| 系统级 hit-test 遇遮挡返回遮挡者 | 定位元素会找错 | `findPressableElement` 只在目标 pid 的树里找 |

---

## 8. Git

```
c2a031e  fix: 虚拟光标绑定目标窗口 + 投递结果不再静默成功（v0.4.2）
4a92ff2  docs: v0.4.1 交接回执（供第三方审查）
77146b5  docs: v0.4.1 部署回执
b60e9eb  fix: 虚拟光标 daemon 不再抢用户前台（v0.4.1）
```

标签 `v0.4.2` 打在本回执所在提交之后（见 `git tag -l`）。

---

## 9. CHANGELOG

`CHANGELOG.md` 已补 `[0.4.2]` 段，含：症状（用户原话）、根因（`screen.frame` 两处）、
修法、可见性模块、结构化裁决、**对 v0.4.1 结论的更正**、顺手修掉的两个测试缺陷、5 条新回归。

---

## 10. 请第三方重点审这几处

1. **`Ghost.swift` 的 `positionWindow()` 与 `view.anchor` 反推**：
   夹屏后尖端是否真的指向原始像素？边缘点（`--x 2 --y 2`）已测，但屏幕拼接场景未测。
2. **`Visibility.swift` 的遮挡者过滤条件** `layer == target.layer && alpha > 0.02`：
   是否漏掉了应该算遮挡的窗口（例如同一 App 的浮层面板）？
3. **"坐标投递对遮挡免疫" 这条结论的外推边界**：
   我们只在 AppKit / 自绘 / WKWebView 三类控件上验证；对 Metal 自绘、游戏、远程桌面类窗口是否成立，**未验证**。
4. **`failureReason` 的分支是否会把「成功但幂等」误判成失败**：
   现在 `verified=false` 一律 `ok=false`，而幂等按钮（如「全部清除」再点一次）本来就不产生变化。
   会话层用 `mode == "ax"` 区分并继续学习，但 `act` 单命令路径会报失败 —— 这是有意的保守，请确认是否可接受。
5. **对 v0.4.1 结论的推翻是否成立**：
   请用 `tests/integration/matrix-v042.sh` 复跑；如果你能构造出「遮挡下 targeted 失败」的最小用例，请直接给出，我们改。
