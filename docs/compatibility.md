# 兼容性

按 macOS 版本与已知回归记录。**没验证过的版本不写「应该可以」。**

## 版本支持

| macOS | 状态 | 说明 |
|---|---|---|
| 26.x（实测 26.6, 25G72） | ✅ 已实测 | 全部能力按 `capability-matrix.md` 验证 |
| 27.x | Not Tested | 本机只有 27.0 SDK，无 27 系统。相关判据已做冗余（见下） |
| ≤ 25 | Not Tested | 未测。`SCScreenshotManager` 需要 14+，理论上 14–25 可用但未验证 |

## macOS 27 相关风险点

### 1. 共享指示器可能变形

macOS 26 上它是 `AXWindow(subrole=AXDialog, title="Window", 66×20)` + `AXButton("WindowSharingSessionButton")`，
且排在 `kAXWindows` 第 0 位。

27 上形态可能变化（尺寸、subrole、层级）。本引擎的判据**不依赖单一特征**：

```
pid 匹配 && layer==0 && 宽≥120 && 高≥60 && 名称不含 WindowSharingSessionButton
```

任一特征失效，其余仍能排除。但如果 27 把它做成「正常尺寸的标准窗口」，
这条判据就会失效 —— 届时需要用标题或 subrole 再加一层。**升级后请重跑
`tests/regression/verify.sh`，它会打印 `kAXWindows` 实际内容。**

### 2. 事件字段 51 / 58

未文档化。Apple 没有保证语义。引擎同时保留了两条路径：

- 字段 51（窗口号）+ 字段 58
- 字段 51 + `CGEventSetWindowLocation`（窗口局部坐标）

一条失效另一条通常仍可用。但两条都失效时，定向投递会「静默成功、实际无效」——
这正是必须靠观察层（AX 指纹对比）兜底的原因。**永远不要关掉 `--verify` 去跑生产任务。**

### 3. `_AXUIElementGetWindow`

未文档化符号，用于把 AX 窗口映射到 `CGWindowID`。
经 `dlsym` 动态解析，拿不到时返回 nil，上层回落到 CGWindowList 判据，不会崩。

## SDK / 工具链

| 组合 | 结果 |
|---|---|
| CLT + MacOSX26.5.sdk + Swift 6.3.3 | ✅ 正常 |
| CLT + 默认 SDK（本机指向 27.0）+ Swift 6.3.3 | ❌ 编译失败（版本不匹配） |

`scripts/build.sh` 会优先挑 26.5 SDK，不存在时才回落。换机器时若编译报 SDK 相关错误，
先看这一段。

## 已知行为差异（不是 bug）

| 现象 | 版本 | 说明 |
|---|---|---|
| 指示器在窗口被完全遮挡时“看不见” | 26.x | 像素不可见，但 AX 元素仍在。判「是否在共享」以 AX 为准 |
| 指示器被截进被捕获画面 | 26.x | Agent 看截图时会看到左上角紫胶囊，别当成 App UI |
| 非激活窗口首击被吞 | 26.x | 用于激活窗口。引擎已加 `mouseMoved` 预热，仍失败就再点一次 |

## 回归触发条件

以下情况**必须重跑** `./tests/run-all.sh all`：

- 升级 macOS 大版本
- 升级 Xcode / Command Line Tools
- 目标应用大版本更新（尤其 Electron 类）
- 修改 `Targeted.swift`（事件字段）、`Apps.swift`（主窗口判据）、`Ghost.swift`（层级与坐标）

---

## v0.4.3：未文档化字段的适用边界（写进代码，不靠记忆）

`src/InputDispatcher/LegacyFields.swift`（`EventFieldCompat`）把 51/58/91/92 与
私有符号 `CGEventSetWindowLocation` 的可靠性收敛成一套可查状态：

| 机制 | 行为 |
|---|---|
| 版本闸门 | 只在已验证的大版本（**14 / 15 / 26**）上默认允许「坐标投递优先」 |
| 未知大版本 | 默认 **AXPress 优先**；某应用在本机成功 ≥2 次后才敢用坐标投递 |
| 逐应用退让 | 连续 3 次「投递后验证失败」→ 该应用降级为 AX 优先 |
| 符号缺失 | `CGEventSetWindowLocation` 解析不到 → 坐标路径直接视为不完整，AX 优先 |
| 复位 | `wbcu compat --reset`；状态存 `~/.wbcu/compat.json` |

查看当前判定：`wbcu compat`（含 OS 大版本、是否已验证、逐应用计数）。

**字段 58 的语义仍未确认**。我们写常量 `12345` 且实测可用，但回读真实物理事件时
该字段是 5.8e13 量级，说明它不是「固定魔数」语义。**不要据此推断系统行为**，
也不要把这条经验外推到别的 macOS 版本。

### 大版本升级后的清单

1. `wbcu compat` —— 确认 `osVerified=false`
2. `tests/integration/matrix-v042.sh` —— 9 例投递矩阵重跑
3. `tests/regression/occlusion-layers.sh` —— 层级遮挡判定重跑
4. 通过后再把新大版本加进 `verifiedOSMajors`

---

## v0.4.3：遮挡判定的已知近似

| 近似 | 影响 | 结论 |
|---|---|---|
| 遮挡用**窗口矩形**判定，不做像素级判定 | 半透明窗口、圆角窗口会被整体算作遮挡或整体忽略 | 保守方向：宁可少画光标 |
| 可见比例用 15×15 采样 | ±1 格误差（约 0.4%） | 只用于报告与状态分级，不用于精确断言 |
| 系统外壳（layer ≥ 20 且面积 ≥ 屏幕 55%）不参与面积 | Dock 实测报 `1470×956` 全屏 bounds，按矩形算会让所有窗口「被遮挡」 | 在报告里单列 `suspectedShell` |
| 只比较「同一 Space 内的屏上窗口」 | 其它 Space 的窗口不可见，判定为 `off_screen` | 未做真机跨 Space 验证（Not Tested） |

排查一条遮挡判定时，直接用 `wbcu occlusion --window <id> --x <x> --y <y>`，
输出里会列出完整 z 序与每个候选遮挡者的 layer / alpha / bounds。

---

## v0.5.0：真实应用里的两个「不稳定」实测

### 1. 计算器的清除键连 AXIdentifier 都会变

| 状态 | identifier | 描述 |
|---|---|---|
| 干净（刚启动） | `AllClear` | 全部清除 |
| 已有输入 | `Clear` | 清除 |

所以「按 identifier 点就一定稳定」这个假设**不成立**。可用的结论是：
identifier 比**文字标签**稳定（标签会在 清除 / 全部清除 / C 之间切），
但它仍然可能随状态变。脚本里应当两个都试，或者干脆在干净状态下开始。

### 2. 计算器的结果行是「按下动作后才出现的新元素」

| 时刻 | AXStaticText 数量 | 主元素（默认读到） | 结果在哪 |
|---|---|---|---|
| 输入中 | 1 | 当前输入（如 `125`） | 同元素 |
| 按下 `=` 之后 | 2 | 表达式行 `125×8` | **第二个**元素 `1,000` |

这解释了为什么「按下等号却说没变化」。v0.5.0 的按值搜索兜底就是为这个场景加的；
`role:AXStaticText[1]` 也能直接指定，但**下标会随元素数量变化而失效**，优先用按值搜索。

### 3. 会话复用的语义

`session start` 默认复用同 App 的活会话（返回 `reused: true`）。
如果需要一份干净的新会话（例如要重算整树指纹做基线），显式加 `--new`。
复用时只刷新窗口 frame，不重算指纹 —— 因此 `lastFingerprint` 可能来自上一次动作，
它只作为「弱验证」的兜底基线；有 `--expect` 时不会用到它。
