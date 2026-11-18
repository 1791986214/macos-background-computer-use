# Ghost Cursor 设计令牌（Design Tokens）

Windows 与 macOS 用不同的原生技术绘制虚拟光标（Windows：`WS_EX_LAYERED` +
`UpdateLayeredWindow` 自绘 DIB；macOS：`NSPanel` + Core Graphics），但**视觉口径必须一致**。

本文件是这套口径的唯一说明。Windows 侧的实现常量在
`src-windows/Wbcu.Contract/GhostTokens.cs`，改数值时两处同步。

## 单位与缩放

所有尺寸都是 **DIP**（设备无关像素，96 DPI 下的逻辑像素）。渲染时统一乘
`scale = 目标窗口 DPI / 96`，因此：

- 100%–200% 缩放下，箭头看起来一样大；
- 热点始终落在真实点击坐标上（偏差 0px，DWM 口径实测）。

## 令牌表

| 令牌 | 值 | 说明 |
|---|---|---|
| `OverlayWidthDip` / `OverlayHeightDip` | 126 | 承载窗口边长。只是画布，**不是**箭头尺寸 |
| `CursorGlyphWidthDip` | 20 | 箭头图形宽 |
| `CursorGlyphHeightDip` | 24 | 箭头图形高 |
| `TipXDip` / `TipYDip` | 24 / 24 | 热点在窗口内的位置；窗口原点 = 目标点 − 该偏移 |
| `StrokeWidthDip` | 1.75 | 描边线宽（1.5 在浅色底上偏细，实测提亮到 1.75 才读得清） |
| `FillAlpha` | 0.98 | 箭头填充不透明度（近白实心；0.92 在浅色底上会糊成空心） |
| `StrokeAlpha` | 0.88 | 描边不透明度（深灰蓝，非纯黑） |
| `GlowDiameterDip` | 56 | 光晕直径 |
| `GlowOpacity` | 0.22 | 光晕峰值不透明度 |
| `ClickAnimationMs` | 120 | 点击反馈环时长 |
| 反馈环半径 | 10 → 26 DIP | 随 progress 扩散；**圆心是热点，不是位图中心** |
| 反馈环配色 | 深色外圈 + 亮白内圈 | 浅底/深底各靠一层可见 |
| `TargetFps` | 60 | 帧率（`TickMs = 1000 / TargetFps = 16`） |
| `CursorTrail` | false | 拖尾关闭——在窗口内容上会形成重影观感 |
| `FillRGB` | 255,255,255 | 箭头填充 |
| `StrokeRGB` | 30,34,44 | 描边 |
| `GlowRGB` | 130,170,250 | 光晕（冷蓝） |
| `GlowCenterX/Y` | 0.40 / 0.42 | 光晕圆心在 glyph box 内的相对位置 |

## 约束（硬性）

1. **承载窗口、箭头、光晕三者尺寸互相独立。** 绝不能用窗口边长推导箭头尺寸——
   v0.6.1 及以前的「巨大箭头」就是这么来的（126px 位图里画出 59×91px 的箭头）。
2. **不画投影。** 深色 + 偏移 = 视觉重影。
3. **只画一个箭头。** 单会话单实例，`ghost start` 已有 `IsAlive` 幂等检查。
4. **光晕必须收敛到 0。** 用 `(1-t)²` 衰减，避免窗口边缘出现方形硬切。
5. **不因视觉尺寸变化而改动后台输入坐标。** 输入坐标由引擎负责，视觉层只做显示。

## 与 macOS 的关系

`src/GhostCursor/Ghost.swift` 目前使用自己的常量（`GHOST_WIN_SIZE = 126`、
`GHOST_TIP = (24,24)`），与本表的窗口尺寸和热点一致，但箭头比例仍是旧口径
（箭头接近占满窗口）。本次只调整 Windows，**未改动 macOS**。

后续若要让两端视觉完全对齐，只需把 macOS 的箭头绘制改为按本表的
`CursorGlyphWidth/Height` 独立计算，窗口与热点无需变动。

## 验证方法

渲染是纯函数（`CursorRaster.RenderCursor(sizePx)`），可以脱离窗口直接验证：

```bash
# 单元测试：缓冲尺寸 / 四角透明 / 有不透明像素 / 预乘
dotnet test src-windows/Wbcu.Tests/Wbcu.Tests.csproj -c Release

# 尺寸与性能：输出各 DPI 档位的箭头实际像素包围盒、每帧耗时
# （见 src-windows 与 Wbcu.Contract 的引用关系，自行挂一个 console 工程即可）
```

真机侧核对窗口属性：

| 检查项 | 期望 |
|---|---|
| overlay 窗口数 | 1（多次 `ghost move` / `click` 后仍为 1） |
| 窗口尺寸 | `126 × scale` |
| 窗口原点 | 目标坐标 − `(24,24) × scale` |
| exStyle | `LAYERED \| TRANSPARENT \| NOACTIVATE \| TOOLWINDOW \| TOPMOST` |
| `frontAppPreserved` | `true` |
| `physicalCursorPreserved` | `true` |
