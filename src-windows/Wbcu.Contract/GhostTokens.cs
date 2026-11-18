namespace Wbcu.Contract;

/// <summary>
/// Ghost Cursor 的**视觉设计令牌**（Design Tokens）。
///
/// 目的：把「承载窗口有多大」「箭头画多大」「光晕多大」三件事彻底解耦。
/// 以前这三者共用一个 sizePx，导致箭头被画成窗口那么大（实测 55×78px，
/// 是标准光标的 2–3 倍），描边和光晕跟着一起放大。
///
/// 单位约定：
///   - 所有 Dip 后缀的值都是**设备无关像素**（96 DPI 下的逻辑像素）。
///   - 渲染时统一乘 scale（= 目标窗口 DPI / 96），所以 100%–200% 缩放下
///     箭头看起来一样大，热点也始终对得上。
///
/// 跨平台：macOS 侧对应 src/GhostCursor/Ghost.swift 的 GHOST_* 常量。
/// 两个平台的原生绘制技术不同（NSPanel vs UpdateLayeredWindow），但数值口径一致。
/// 改动这里的数值时，请同步 docs/ghost-cursor-tokens.md。
/// </summary>
public static class GhostTokens
{
    // ── 承载窗口 ────────────────────────────────────────────────
    /// <summary>覆盖层窗口边长（DIP）。够放箭头 + 光晕，但又小到不会挡住内容。</summary>
    public const double OverlayWidthDip = 126;
    public const double OverlayHeightDip = 126;

    // ── 箭头本体 ────────────────────────────────────────────────
    /// <summary>箭头图形宽度（DIP）。Codex Computer Use 口径量级，约标准光标大小。</summary>
    public const double CursorGlyphWidthDip = 20;
    /// <summary>箭头图形高度（DIP）。</summary>
    public const double CursorGlyphHeightDip = 24;

    /// <summary>
    /// 热点在覆盖层内的位置（DIP）。
    /// 箭头尖端落在这里，是「真实点击坐标」与「视觉位置」的唯一对齐锚点。
    /// 取 24 是因为光晕半径 28、箭头重心偏右下约 10，尖端再靠左就会被窗口边缘裁掉光晕。
    /// </summary>
    public const double TipXDip = 24;
    public const double TipYDip = 24;

    // ── 描边与填充 ──────────────────────────────────────────────
    /// <summary>描边线宽（DIP）。细到能压住浅色背景，又不至于变成黑边框。</summary>
    public const double StrokeWidthDip = 1.75;

    /// <summary>填充不透明度：近白半透明，透出一点背景，不糊住内容。</summary>
    public const double FillAlpha = 0.98;

    /// <summary>描边不透明度：深灰蓝，克制，不用纯黑。</summary>
    public const double StrokeAlpha = 0.88;

    // ── 光晕 ────────────────────────────────────────────────────
    /// <summary>光晕直径（DIP）。远小于窗口边长，留出柔和衰减空间。</summary>
    public const double GlowDiameterDip = 56;
    /// <summary>光晕峰值不透明度。低到能感觉到「有光」，高到不会形成色块。</summary>
    public const double GlowOpacity = 0.22;

    // ── 动效 ────────────────────────────────────────────────────
    /// <summary>点击反馈动画时长（ms）。短促，像一次轻点，不是一次呼吸。</summary>
    public const int ClickAnimationMs = 120;
    /// <summary>目标帧率。60fps 才能让 120ms 的动画看起来连贯。</summary>
    public const int TargetFps = 60;
    /// <summary>是否绘制拖尾。关闭：拖尾在窗口内容上会形成"重影"观感。</summary>
    public const bool CursorTrail = false;

    // ── 配色 ────────────────────────────────────────────────────
    public const byte FillR = 255, FillG = 255, FillB = 255;
    public const byte StrokeR = 30, StrokeG = 34, StrokeB = 44;
    public const byte GlowR = 130, GlowG = 170, GlowB = 250;

    /// <summary>帧间隔（ms），由 TargetFps 推导。</summary>
    public static int TickMs => Math.Max(1, 1000 / TargetFps);

    /// <summary>光晕中心在箭头图形内的相对位置（0..1，按 glyph 宽高比例）。</summary>
    public const double GlowCenterX = 0.40;
    public const double GlowCenterY = 0.42;
}
