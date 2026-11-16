namespace Wbcu.Contract;

/// <summary>
/// Ghost Cursor 的**纯像素渲染**。不碰任何窗口 API，因此可以在 macOS / CI 上直接单测。
///
/// 视觉口径与 macOS v0.5.0 保持一致：
///   - 浅色箭头（近白，略带冷调）
///   - 深色细描边（保证在浅色背景上也看得见）
///   - 多层柔和圆形光晕（不是硬边圆）
///
/// 输出格式：32bpp BGRA，**已预乘 alpha**（UpdateLayeredWindow + AC_SRC_ALPHA 要求预乘）。
///
/// 重要边界：这只是「显示」。它的存在不代表任何点击成功——
/// 点击是否成功只由 InputDispatcher 的投递结果 + 结果验证决定。
/// </summary>
public static class CursorRaster
{
    // 箭头多边形（单位方形内，指向左上）
    private static readonly (double X, double Y)[] Arrow =
    {
        (0.22, 0.12),
        (0.22, 0.74),
        (0.36, 0.60),
        (0.45, 0.82),
        (0.55, 0.78),
        (0.46, 0.56),
        (0.66, 0.56),
    };

    // 光晕中心：取箭头近似重心，保证四个角一定落在光晕之外（否则窗口边缘会出现方形硬切）
    private const double HaloCx = 0.38;
    private const double HaloCy = 0.45;
    private const double HaloRadiusRatio = 0.42;
    private const double ShadowRadiusRatio = 0.055;

    /// <summary>
    /// 渲染一枚光标。sizePx 为输出位图边长（正方形，物理像素）。
    /// 返回长度为 sizePx*sizePx*4 的 BGRA 预乘缓冲。
    /// </summary>
    public static byte[] RenderCursor(int sizePx)
    {
        if (sizePx < 8) sizePx = 8;
        var buf = new byte[sizePx * sizePx * 4];
        var haloRadius = sizePx * HaloRadiusRatio;
        var outlineHalf = Math.Max(1.0, sizePx * 0.014);

        const int Sub = 4; // 每像素 4x4 超采样，用于抗锯齿
        var inv = 1.0 / sizePx;

        for (var py = 0; py < sizePx; py++)
        {
            for (var px = 0; px < sizePx; px++)
            {
                var coverFill = 0.0;
                var coverEdge = 0.0;
                var haloSum = 0.0;
                var shadowSum = 0.0;

                for (var sy = 0; sy < Sub; sy++)
                {
                    for (var sx = 0; sx < Sub; sx++)
                    {
                        var u = (px + (sx + 0.5) / Sub) * inv;
                        var v = (py + (sy + 0.5) / Sub) * inv;

                        var inside = PointInPolygon(u, v);
                        var dist = DistanceToPolygon(u, v);

                        if (inside) coverFill += 1;
                        // 描边：边界两侧各半个线宽（内部内侧更明显）
                        if (dist <= outlineHalf * inv) coverEdge += 1;

                        var hx = (u - HaloCx) * sizePx;
                        var hy = (v - HaloCy) * sizePx;
                        var t = Math.Sqrt(hx * hx + hy * hy) / haloRadius;
                        if (t < 1)
                        {
                            // 平滑衰减：中段更饱满，边缘更柔（近似 macOS 的多层光晕）
                            var k = 1 - t;
                            haloSum += k * k * 0.46;
                        }

                        // 柔和投影：向右下偏移一点点的模糊轮廓，保证浅色背景上也看得见
                        var sxu = u - 0.020;
                        var syv = v - 0.055;
                        var sdist = DistanceToPolygon(sxu, syv);
                        var sNorm = sdist / ShadowRadiusRatio;
                        if (sNorm < 1)
                        {
                            var k = 1 - sNorm;
                            shadowSum += k * k * 0.34;
                        }
                    }
                }

                var n = Sub * Sub;
                var fill = coverFill / n;
                var edge = Math.Min(1.0, coverEdge / n);
                var halo = haloSum / n;
                var shadow = shadowSum / n;

                // 合成顺序：投影 → 光晕 → 箭头填充 → 描边
                double r = 0, g = 0, b = 0;
                var a = 0.0;

                if (shadow > 0) Blend(ref r, ref g, ref b, ref a, 22, 26, 34, shadow);
                if (halo > 0) Blend(ref r, ref g, ref b, ref a, 130, 170, 250, halo);

                if (fill > 0)
                {
                    // 箭头主体：近白
                    var fr = 250.0;
                    var fg = 250.0;
                    var fb = 252.0;
                    var fa = fill;
                    Blend(ref r, ref g, ref b, ref a, fr, fg, fb, fa);
                }

                if (edge > 0)
                {
                    // 描边：深灰蓝
                    Blend(ref r, ref g, ref b, ref a, 38, 42, 52, edge * 0.92);
                }

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
    /// 与 CursorRaster.RenderCursor 同尺寸，用于「鼠标按下」的视觉反馈。
    /// </summary>
    public static byte[] RenderClickRing(int sizePx, double progress)
    {
        if (sizePx < 8) sizePx = 8;
        progress = Math.Clamp(progress, 0, 1);
        var buf = new byte[sizePx * sizePx * 4];
        var c = sizePx / 2.0;
        var radius = sizePx * (0.16 + 0.30 * progress);
        var thickness = Math.Max(1.5, sizePx * 0.02);
        var fade = 1.0 - progress;

        for (var py = 0; py < sizePx; py++)
        {
            for (var px = 0; px < sizePx; px++)
            {
                var dx = px + 0.5 - c;
                var dy = py + 0.5 - c;
                var d = Math.Sqrt(dx * dx + dy * dy);
                var band = Math.Abs(d - radius);
                if (band > thickness) continue;

                var k = (1 - band / thickness) * fade * 0.85;
                var i = (py * sizePx + px) * 4;
                var a = Math.Clamp(k, 0, 1);
                // 偏冷白
                buf[i + 0] = (byte)(235 * a);
                buf[i + 1] = (byte)(240 * a);
                buf[i + 2] = (byte)(255 * a);
                buf[i + 3] = (byte)(a * 255);
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
