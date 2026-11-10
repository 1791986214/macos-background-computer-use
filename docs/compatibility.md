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
