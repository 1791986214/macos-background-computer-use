> ⚠️ **部分结论已在 v0.4.2 被推翻**（2026-11-12）
>
> 本文档保留历史原样以便对照，但以下两条**不要**再当作现状：
>
> 1. 第 2 节/第 105 行「坐标投递在非前台时静默失败」—— v0.4.2 用受控夹具 9 例 + 真机计算器复验，
>    未能复现；原记录起因是**点错了坐标**（`--x 88 --y 157` 不是「7」按钮位置）与不可观测的判据。
> 2. 第 1 节对 Ghost Cursor 的描述基于「整屏透明面板」的实现，该实现已在 v0.4.2 改为 126×126 跟随小窗。
>
> 现状请看 [`receipt-v0.4.2.md`](./receipt-v0.4.2.md)。

# 交接回执 · v0.4.1（供第三方审查）

**出具时间**：2026-11-11 10:35（GMT+8）
**目的**：把「虚拟光标显示范围」与「切换窗口影响点击」这两个现象完整交底，供另一位 AI 审查定位。
**本文档只做交底，不含结论性修复**；凡是我没验证的，都明确标成「假设」。

---

## 0. 一句话现状

虚拟光标是一个**覆盖整块屏幕**的透明窗体（`NSPanel`，`contentRect = screen.frame`），
坐标取的是目标窗口的全局位置。所以当目标窗口被用户的前台窗口盖住时，
光标仍然画在**最上层**——看起来就是在用户的前台窗口上乱飞。

同时，**坐标投递**在目标窗口不处于前台时实测会静默失败（返回 ok 但界面没变），
而 **AX 语义投递**在同条件下成功。这两条路径的可靠性差异，很可能就是
「我切窗口就影响你点击」的直接原因。

---

## 1. 用户原话（现象描述）

> 我切换窗口还会影响你点击，这没道理。
> codex 那个 computer use 是直接拉起窗口后再注入虚拟鼠标，一边捕获一边用虚拟鼠标点击，
> 能看到鼠标是虚化且在窗口范围的，并不会影响用户鼠标，用户切换窗口也不会影响。
> 而不是我现在看到你在操作计算机，但是我能看到虚拟鼠标在我前台窗口飞来飞去。

拆成三个可检验的断言：

| # | 用户观察 | 性质 |
|---|---|---|
| A | 虚拟光标出现在**用户的前台窗口**上，而不是只在目标窗口内 | 视觉 |
| B | 光标应当是「虚化 + 限定在窗口范围」 | 期望形态 |
| C | 用户切换窗口会影响点击 | 功能 |

---

## 2. 我们的实现（v0.4.1 实际代码）

### 2.1 光标的物理形态

| 属性 | 值 | 代码位置 |
|---|---|---|
| 载体 | 独立进程 `ThirdHandOverlay.app`（`LSUIElement`） | `scripts/build.sh` |
| 窗口类型 | `NSPanel`，`.borderless + .nonactivatingPanel` | `src/GhostCursor/Ghost.swift:212` |
| **窗口尺寸** | **`screen.frame`（整块屏幕）** | `Ghost.swift:212` |
| **画布尺寸** | **`screen.frame`（整块屏幕）** | `Ghost.swift:226` |
| 窗口层级 | `102`（≈ popUpMenu+1） | `Ghost.swift:220` |
| 鼠标事件 | `ignoresMouseEvents = true`（全穿透） | `Ghost.swift` panel 配置 |
| 空间行为 | `.canJoinAllSpaces / .stationary / .fullScreenAuxiliary / .ignoresCycle` | 同上 |
| 绘制 | `NSView.draw` 矢量：白填充箭头 + 紫描边 + 20px 光晕 + 文字标签 | `Ghost.swift:138` 起 |
| 刷新 | 60fps `Timer` + 每帧 `displayIfNeeded()` | `Ghost.swift` setup |

### 2.2 坐标与锚定

```swift
// Ghost.swift:54
func refreshAnchor() {
    guard anchored, let wid = windowId, let f = windowFrame(wid) else { return }
    target = CGPoint(x: f.minX + anchorLocal.x, y: f.minY + anchorLocal.y)
}
```

- 每 **100ms** 按 `windowId` 重算一次窗口位置，再叠加**窗口内相对坐标**（`anchorLocal`）。
- 绘制时把全局坐标 `toView()` 转换到视图坐标（`Ghost.swift:133`）。
- **没有任何"当前点是否仍在目标窗口矩形内"的判断，也没有遮挡判断。**
  `draw()` 只检查 `model.visible`（`Ghost.swift:139`）。

### 2.3 点击的两条路径

| 路径 | 实现 | 前置条件 |
|---|---|---|
| `ax`（默认优先） | `AXUIElementPerformAction(el, kAXPressAction)` | 目标 App 暴露可按下元素 |
| `targeted`（AX 失败时） | `CGEvent.postToPid` + 字段 51（窗口号）+ 字段 58 + `CGEventSetWindowLocation(窗口局部坐标)` | 需要 `pid` + `windowId` + 窗口 frame |

`targeted` 实现见 `src/InputDispatcher/Targeted.swift:31`（`targetedClick`），
字段常量在 `Targeted.swift:25-26`，坐标设置走 `cgSetWindowLocation`（`Targeted.swift:20`）。

---

## 3. 实测证据

> 环境：macOS 26.6 (25G72)，MacBook M5 arm64，Able 引擎 v0.4.1（commit `b60e9eb`）。
> 所有命令均为实际执行并记录输出。

### 证据 1：光标**不**限制在目标窗口内（对应断言 A）

```
目标窗口（Calculator）：620,300  230×408
执行：wbcu ghost move --x 400 --y 700 --label 窗口外
结果：screencapture -R330,640,260,120 截到光标 —— 该点在窗口外 300+ px
```

结论：**已确认**。光标画在整屏画布上，可出现在屏幕任意位置，与目标窗口边界无关。
（这也解释了为什么它会"飞在用户前台窗口上"：目标窗口在用户窗口后面，
但光标层在最上面，于是光标看起来落在了用户窗口的区域。）

### 证据 2：目标被遮挡时，两条点击路径结果不同（对应断言 C）

前置：Calculator 被 WorkBuddy 窗口完全覆盖，WorkBuddy 为前台。

| 路径 | 命令 | 结果 |
|---|---|---|
| AX 语义 | `session click --text "全部清除" --exact` | `mode=ax verify=changed exp=hit(stable)` ✅ |
| 坐标投递 | `session click --x 88 --y 157 --mode targeted` | `mode=targeted verify=no_observable_change` ❌ |

随后读值：显示仍为 `0`（未发生预期变化），但命令本身返回 `ok:true`。

结论：**已确认**——`targeted` 路径在目标非前台时会「返回成功但实际无效」。
注意：这个失败是**静默的**，只能靠事后读值发现，命令返回码看不出来。

### 证据 3：切换前台本身不改变 AX 路径的可用性

同一会话内，用户切到 WorkBuddy 后执行 AX 点击，仍 `verify=changed`。
说明「切换窗口」不是直接封死全部点击，而是**先打掉坐标路径**，
再由 AX 路径兜底；一旦 AX 也找不到元素（或该控件不暴露 AXPress），就表现为「点了没反应」。

---

## 4. 与 Codex 实现的对比（关键差异）

早前（同一台机器，2026-11-10）对 Codex 的 Computer Use 做过窗口级取证，
当时的记录为：

```
owner="ChatGPT Computer Use"  name="Software Cursor"
layer=102  alpha=1.0  尺寸 126×126  位置 584,696  onscreen=false（空闲时下屏）
真实系统光标：pid=168  layer=2147483630  23×22
```

> 说明：本次复核时该窗口不存在（CU 服务空闲），上表为当时的实测值，不是推测。

**差异点**：

| 维度 | Codex（实测） | 我们（v0.4.1） |
|---|---|---|
| 光标窗口尺寸 | **126×126**（跟随光标的小窗） | **整屏 1470×956** |
| 空闲行为 | `onscreen=false`（下屏，不占合成） | 常驻整屏透明层 |
| 视觉范围 | 只在光标附近一小块 | 全屏任意点 |
| 层级 | 102 | 102（一致） |

所以「Codex 的光标看着只在窗口里」很可能不是因为它做了裁剪，
而是因为**它的窗口只有 126×126，跟着光标走**，自然不会铺满全屏。

⚠️ 这一点是**推断**，不是结论：我们没能在 Codex 活跃时抓取它的逐帧行为。

**另外纠正一个常见误解**：Codex 并没有把光标「注入」到目标应用里或 ScreenCaptureKit 流里——
它同样是一个**独立窗口**（owner 是 `ChatGPT Computer Use` 进程）。
SCK 只负责取画面，本身无法绘制或注入任何东西。

---

## 5. 根因假设（请审查者重点看这节）

| 编号 | 假设 | 支撑 | 状态 |
|---|---|---|---|
| **H1** | 光标用整屏画布，导致视觉上「铺满全屏、可落在任何窗口上」 | 证据 1 + 代码 `Ghost.swift:212/226` | **已验证** |
| **H2** | `targeted` 坐标投递在目标非前台时静默失效 | 证据 2 | **已验证（单点）** |
| **H3** | 用户切换窗口 → 坐标路径失败 → 若 AX 也不可用，则表现为「点击被影响」 | 证据 2+3 的组合 | 假设，未端到端复现用户场景 |
| **H4** | 光标未做「目标窗口不可见/被遮挡时暂停或降透明度」 | 代码里无相关分支 | **已验证（无此逻辑）** |
| **H5** | `refreshAnchor` 只按 windowId 跟随，若窗口被最小化/移出屏幕，光标仍会画在旧坐标 | `Ghost.swift:54` 无可见性判断 | 假设，未测 |

---

## 6. 复现步骤（审查者可直接跑）

```bash
cd /Users/lang/WorkBuddy/macos-background-computer-use
git checkout b60e9eb          # v0.4.1

# 证据 1：光标越界
./bin/wbcu ghost start
./bin/wbcu ghost move --x 400 --y 700 --label 窗口外
screencapture -x -R330,640,260,120 /tmp/outside.png   # 窗口在 620,300 230x408

# 证据 2：遮挡下的两条路径
open -g -a Calculator && sleep 1.5
./bin/wbcu guard --app com.apple.calculator --allow
SID=$(./bin/wbcu session start --app com.apple.calculator --json | python3 -c "import sys,json;print(json.load(sys.stdin)['session']['id'])")
osascript -e 'tell application "WorkBuddy" to activate'   # 制造遮挡
./bin/wbcu session click --id $SID --text "全部清除" --exact --json        # AX：成功
./bin/wbcu session click --id $SID --x 88 --y 157 --mode targeted --json  # 坐标：静默失败
```

---

## 7. 环境与制品

| 项 | 值 |
|---|---|
| 引擎版本 | 0.4.1 |
| 提交 | `b60e9eb`（修复）+ `77146b5`（回执） |
| 二进制 | `~/.local/bin/wbcu`，SHA256 `10e5c2003d22b0baf148a7780e19e20f28e0576bc1b37802b29307b7165262f4` |
| 覆盖层 | `~/.local/share/wbcu/ThirdHandOverlay.app`（`LSUIElement=true`） |
| 源码 | `src/GhostCursor/Ghost.swift`（光标）、`src/InputDispatcher/Targeted.swift`（投递） |
| 关键提交历史 | `v0.4.0` 性能优化；`v0.4.1` 修 daemon 启动抢前台（改 LSUIElement bundle） |

---

## 8. 给审查者的问题清单

1. **H1 是主因吗？** 把整屏画布改成「跟随光标的小窗口（如 160×160）」是否足够让视觉上不再「铺满前台窗口」？是否还需要按目标窗口矩形裁剪？
2. **H2 的失效机制是什么？** `postToPid` + 字段 51/58 + `SetWindowLocation` 在目标非 key window 时被谁吞掉——目标进程、WindowServer，还是事件路由？有没有可验证的替代（例如先 `AXRaise` 但不激活、或使用 `kCGEventFlagMaskNonCoalesced` 等）？
3. **是否必须「拉起目标窗口」？** 用户描述的 Codex 行为包含「先把窗口拉起来」。如果后台投递在遮挡下不可靠，是否应该改为「对目标窗口执行 `AXRaise`/`orderFront`（不激活）后再投递」？这会改变"完全不打扰"的承诺，需要权衡。
4. **H5**：窗口最小化 / 移到别的 Space 时，光标应该隐藏还是跟随？目前没有任何判断。
5. 是否存在我们没考虑到的路径：例如目标窗口在**另一块显示器**、或目标窗口被其他 App 以「始终置顶」覆盖？

---

## 9. 我们明确**没有**做的事（避免误判）

- 没有把光标画进目标应用的窗口（技术上不可能，也不应该）。
- 没有把光标合成进 ScreenCaptureKit 流；SCK 只取画面。窗口级截图不含光标是必然结果。
- 没有移动用户真实鼠标（除显式 `--allow-global`）。
- 没有使用 SkyLight / SLPS 私有 API。

---

## 10. 附：相关证据文件

| 文件 | 内容 |
|---|---|
| `/tmp/outside.png` | 光标落在目标窗口外的截图 |
| `/tmp/final-check.png` | 光标正常显示（白箭头 + 紫标签） |
| `docs/capability-matrix.md` | 各框架下 AX / 坐标投递的实测矩阵 |
| `docs/experience-memory.md` | 经验库格式与失效机制 |
| `tests/regression/no-focus-steal.sh` | 前台不被抢的回归测试（含 idle 干扰判定） |
