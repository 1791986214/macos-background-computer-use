namespace Wbcu.Contract;

/// <summary>
/// Ghost Cursor 的**纯像素渲染**。不碰任何窗口 API，因此可以在 macOS / CI 上直接单测。
///
/// 视觉口径（Codex Computer Use 风格）：
///   - 承载位图 126 DIP，但**箭头只占 20×24 DIP**，光晕直径 56 DIP。
///     三者分别受 GhostTokens 控制，绝不共用同一个尺寸。
///   - 浅色半透明填充 + 极细描边（1.5 DIP），无黑色投影。
///   - 低不透明度柔和光晕（0.22），边缘自然衰减到 0。
///
/// 历史坑（v0.6.1 及以前）：箭头多边形用 0..1 归一化坐标，直接乘位图边长，
/// 于是 126px 的位图里箭头被画成 55×78px；描边按 1.4% 位图宽算，也跟着变粗；
/// 还叠了一层向右下偏移的深色投影，观感就是"巨大 + 黑边 + 重影 + 遮挡内容"。
/// 现在几何按 DIP 独立计算，与位图边长无关。
///
/// 输出格式：32bpp BGRA，**已预乘 alpha**（UpdateLayeredWindow + AC_SRC_ALPHA 要求预乘）。
///
/// 重要边界：这只是「显示」。它的存在不代表任何点击成功——
/// 点击是否成功只由 InputDispatcher 的投递结果 + 结果验证决定。
/// </summary>
public static class CursorRaster
{
    /// <summary>
    /// 箭头多边形，坐标单位是**箭头自身的 glyph box**（归一化到
    /// CursorGlyphWidthDip × CursorGlyphHeightDip），尖端在 (0,0)，向右下展开。
    /// 不再是 0..1 的整窗口坐标——这是本次修形的关键。
    /// </summary>
    private static readonly (double X, double Y)[] Arrow =
    {
        (0.00, 0.00),   // 尖端（热点）
        (0.00, 0.89),   // 左边落底
        (0.32, 0.69),   // 左下内收
        (0.52, 1.00),   // 尾钩最下
        (0.75, 0.94),   // 尾钩外侧
        (0.54, 0.63),   // 尾钩内收
        (1.00, 0.63),   // 右肩
    };

    /// <summary>
    /// 渲染一枚光标。sizePx 为输出位图边长（正方形，物理像素）。
    /// 缩放系数由 sizePx / OverlayWidthDip 反推，因此 126→100%、252→200%。
    /// </summary>
    public static byte[] RenderCursor(int sizePx)
    {
        if (sizePx < 8) sizePx = 8;
        var buf = new byte[sizePx * sizePx * 4];

        var scale = sizePx / GhostTokens.OverlayWidthDip;
        var glyphW = GhostTokens.CursorGlyphWidthDip * scale;
        var glyphH = GhostTokens.CursorGlyphHeightDip * scale;
        var tipX = GhostTokens.TipXDip * scale;
        var tipY = GhostTokens.TipYDip * scale;

        var glowR = GhostTokens.GlowDiameterDip * scale / 2.0;
        var glowCx = tipX + glyphW * GhostTokens.GlowCenterX;
        var glowCy = tipY + glyphH * GhostTokens.GlowCenterY;

        // 描边半宽（物理像素）。1.5 DIP 的线，两侧各 0.75 DIP。
        var strokeHalf = Math.Max(0.75, GhostTokens.StrokeWidthDip * scale / 2.0);

        // 只扫「箭头 bbox ∪ 光晕圆」的包围盒，其余留全透明。
        // 既保证角落干净，也让高 DPI（252px 位图）下的每帧开销可控。
        var minX = (int)Math.Floor(Math.Min(tipX, glowCx - glowR)) - 2;
        var maxX = (int)Math.Ceiling(Math.Max(tipX + glyphW, glowCx + glowR)) + 2;
        var minY = (int)Math.Floor(Math.Min(tipY, glowCy - glowR)) - 2;
        var maxY = (int)Math.Ceiling(Math.Max(tipY + glyphH, glowCy + glowR)) + 2;
        minX = Math.Max(0, minX); minY = Math.Max(0, minY);
        maxX = Math.Min(sizePx - 1, maxX); maxY = Math.Min(sizePx - 1, maxY);

        const int Sub = 4; // 每像素 4x4 超采样，用于抗锯齿

        for (var py = minY; py <= maxY; py++)
        {
            for (var px = minX; px <= maxX; px++)
            {
                var coverFill = 0.0;
                var coverEdge = 0.0;
                var haloSum = 0.0;

                for (var sy = 0; sy < Sub; sy++)
                {
                    for (var sx = 0; sx < Sub; sx++)
                    {
                        // 采样点落在物理像素坐标系
                        var fx = px + (sx + 0.5) / Sub;
                        var fy = py + (sy + 0.5) / Sub;

                        // 光晕：按物理距离衰减，与箭头尺寸无关
                        var hx = fx - glowCx;
                        var hy = fy - glowCy;
                        var t = Math.Sqrt(hx * hx + hy * hy) / glowR;
                        if (t < 1)
                        {
                            // (1-t)^2：中心饱满、边缘完全收敛，不留硬边
                            var k = 1 - t;
                            haloSum += k * k * GhostTokens.GlowOpacity;
                        }

                        // 箭头本体：转到 glyph 归一化坐标（0..1），与位图尺寸彻底解耦
                        var u = (fx - tipX) / glyphW;
                        var v = (fy - tipY) / glyphH;

                        if (u >= -0.1 && u <= 1.1 && v >= -0.1 && v <= 1.1)
                        {
                            if (PointInPolygon(u, v)) coverFill += 1;
                            // 描边判定：把物理线宽换算回 glyph 归一化单位
                            var distNorm = DistanceToPolygon(u, v);
                            var halfU = strokeHalf / glyphW;
                            var halfV = strokeHalf / glyphH;
                            if (distNorm <= Math.Max(halfU, halfV)) coverEdge += 1;
                        }
                    }
                }

                var n = Sub * Sub;
                var fill = coverFill / n;
                var edge = Math.Min(1.0, coverEdge / n);
                var halo = haloSum / n;

                // 合成顺序：光晕 → 填充 → 描边（无投影，避免"重影"）
                double r = 0, g = 0, b = 0;
                var a = 0.0;

                if (halo > 0)
                    Blend(ref r, ref g, ref b, ref a,
                          GhostTokens.GlowR, GhostTokens.GlowG, GhostTokens.GlowB, halo);

                if (fill > 0)
                    Blend(ref r, ref g, ref b, ref a,
                          GhostTokens.FillR, GhostTokens.FillG, GhostTokens.FillB,
                          fill * GhostTokens.FillAlpha);

                if (edge > 0)
                    Blend(ref r, ref g, ref b, ref a,
                          GhostTokens.StrokeR, GhostTokens.StrokeG, GhostTokens.StrokeB,
                          edge * GhostTokens.StrokeAlpha);

                if (a <= 0) continue;

                var i = (py * sizePx + px) * 4;
                var alpha = (byte)Math.Clamp(a * 255.0, 0, 255);
                // 预乘
                buf[i + 0] = (byte)Math.Clamp(b * a, 0, 255);
                buf[i + 1] = (byte)Math.Clamp(g * a, 0, 255);
                buf[i + 2] = (byte)Math.Clamp(r * a, 0, 255);
                buf[i + 3] = alpha;
            }
        }

        return buf;
    }

    /// <summary>
    /// 点击反馈环：progress 0→1 表示扩散过程。
    ///
    /// 三个约束（都是踩出来的）：
    ///   1) **圆心是热点（箭头尖端），不是位图中心。** 旧版以位图中心画环，
    ///      126px 位图里环心比尖端偏右下约 39px，看起来像「点在了另一个地方」。
    ///   2) **用中亮度蓝，而不是白或黑。** 白色环在浅色桌面上消失，深色环在深色桌面上消失；
    ///      试过「深色外圈 + 亮白内圈」的双层方案，但环只有 1.6px 宽，深色层被压到
    ///      alpha≈0.09，等于没画。中亮度蓝（100,150,255）在两种背景上都有对比度。
    ///   3) **半径按 DIP 收敛**（10→26 DIP），不超过光晕半径，避免糊住箭头本体。
    /// </summary>
    public static byte[] RenderClickRing(int sizePx, double progress)
    {
        if (sizePx < 8) sizePx = 8;
        progress = Math.Clamp(progress, 0, 1);
        var buf = new byte[sizePx * sizePx * 4];

        var scale = sizePx / GhostTokens.OverlayWidthDip;
        var cx = GhostTokens.TipXDip * scale;
        var cy = GhostTokens.TipYDip * scale;

        var radius = (10 + 16 * progress) * scale;
        var thickness = Math.Max(1.2, 1.5 * scale);
        var fade = 1.0 - progress;

        var rMax = radius + thickness + 1;
        var x0 = Math.Max(0, (int)Math.Floor(cx - rMax));
        var x1 = Math.Min(sizePx - 1, (int)Math.Ceiling(cx + rMax));
        var y0 = Math.Max(0, (int)Math.Floor(cy - rMax));
        var y1 = Math.Min(sizePx - 1, (int)Math.Ceiling(cy + rMax));

        for (var py = y0; py <= y1; py++)
        {
            for (var px = x0; px <= x1; px++)
            {
                var dx = px + 0.5 - cx;
                var dy = py + 0.5 - cy;
                var d = Math.Sqrt(dx * dx + dy * dy);
                var band = Math.Abs(d - radius);
                if (band > thickness) continue;

                var k = (1 - band / thickness) * fade * 0.85;
                if (k <= 0.01) continue;

                var i = (py * sizePx + px) * 4;
                buf[i + 0] = (byte)Math.Clamp(255 * k, 0, 255); // B
                buf[i + 1] = (byte)Math.Clamp(150 * k, 0, 255); // G
                buf[i + 2] = (byte)Math.Clamp(100 * k, 0, 255); // R
                buf[i + 3] = (byte)Math.Clamp(k * 255.0, 0, 255);
            }
        }

        return buf;
    }

    private static void Blend(ref double r, ref double g, ref double b, ref double a,
                              double sr, double sg, double sb, double sa)
    {
        var outA = sa + a * (1 - sa);
        if (outA <= 0)
        {
            r = g = b = 0;
            a = 0;
            return;
        }
        r = (sr * sa + r * a * (1 - sa)) / outA;
        g = (sg * sa + g * a * (1 - sa)) / outA;
        b = (sb * sa + b * a * (1 - sa)) / outA;
        a = outA;
    }

    private static bool PointInPolygon(double x, double y)
    {
        var inside = false;
        for (int i = 0, j = Arrow.Length - 1; i < Arrow.Length; j = i++)
        {
            var xi = Arrow[i].X; var yi = Arrow[i].Y;
            var xj = Arrow[j].X; var yj = Arrow[j].Y;
            if ((yi > y) != (yj > y) &&
                x < (xj - xi) * (y - yi) / (yj - yi) + xi)
            {
                inside = !inside;
            }
        }
        return inside;
    }

    private static double DistanceToPolygon(double x, double y)
    {
        var best = double.MaxValue;
        for (int i = 0, j = Arrow.Length - 1; i < Arrow.Length; j = i++)
        {
            best = Math.Min(best, DistanceToSegment(x, y, Arrow[j].X, Arrow[j].Y, Arrow[i].X, Arrow[i].Y));
        }
        return best;
    }

    private static double DistanceToSegment(double px, double py, double ax, double ay, double bx, double by)
    {
        var vx = bx - ax;
        var vy = by - ay;
        var wx = px - ax;
        var wy = py - ay;
        var len2 = vx * vx + vy * vy;
        var t = len2 <= 0 ? 0 : Math.Clamp((wx * vx + wy * vy) / len2, 0, 1);
        var dx = wx - t * vx;
        var dy = wy - t * vy;
        return Math.Sqrt(dx * dx + dy * dy);
    }
}
