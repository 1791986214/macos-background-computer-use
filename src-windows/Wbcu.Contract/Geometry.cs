namespace Wbcu.Contract;

/// <summary>逻辑点（DIP）。Windows 的 UIA 用物理像素，WPF/DIP 与 macOS 用逻辑点，</summary>
/// 两边的换算必须只有一份实现，否则截图坐标、Ghost Cursor 落点、消息投递会各差一点。
public readonly record struct WbPoint(double X, double Y)
{
    public override string ToString() => $"({X:0.##},{Y:0.##})";
}

/// <summary>矩形，单位由调用方语境决定（屏幕物理像素 / 客户区像素 / 逻辑点）。</summary>
public readonly record struct WbRect(double X, double Y, double W, double H)
{
    public double Right => X + W;
    public double Bottom => Y + H;
    public double Area => Math.Max(0, W) * Math.Max(0, H);
    public bool IsEmpty => W <= 0 || H <= 0;

    public WbPoint Center => new(X + W / 2, Y + H / 2);

    public bool Contains(WbPoint p) => p.X >= X && p.X < Right && p.Y >= Y && p.Y < Bottom;

    public WbRect Intersect(WbRect o)
    {
        var x1 = Math.Max(X, o.X);
        var y1 = Math.Max(Y, o.Y);
        var x2 = Math.Min(Right, o.Right);
        var y2 = Math.Min(Bottom, o.Bottom);
        return x2 <= x1 || y2 <= y1 ? new WbRect(x1, y1, 0, 0) : new WbRect(x1, y1, x2 - x1, y2 - y1);
    }

    public override string ToString() => $"[{X:0.##},{Y:0.##} {W:0.##}x{H:0.##}]";
}

/// <summary>坐标与 DPI 换算。全部是纯函数，能被单元测试锁住。</summary>
public static class Geometry
{
    /// <summary>屏幕全局 → 窗口局部（投递给目标进程的坐标必须是窗口局部）。</summary>
    public static WbPoint WindowLocal(WbPoint global, WbRect frame) =>
        new(global.X - frame.X, global.Y - frame.Y);

    /// <summary>窗口局部 → 屏幕全局（Ghost Cursor 定位、AX/UIA 元素定位用）。</summary>
    public static WbPoint WindowGlobal(WbPoint local, WbRect frame) =>
        new(frame.X + local.X, frame.Y + local.Y);

    /// <summary>DPI → 缩放系数（96 DPI = 1.0）。</summary>
    public static double ScaleFromDpi(int dpi) => dpi <= 0 ? 1.0 : dpi / 96.0;

    /// <summary>逻辑点 → 物理像素。截图像素分析必须走这个。</summary>
    public static WbPoint ToPhysical(WbPoint dip, double scale) => new(dip.X * scale, dip.Y * scale);

    /// <summary>物理像素 → 逻辑点。</summary>
    public static WbPoint ToDip(WbPoint px, double scale) =>
        scale <= 0 ? px : new WbPoint(px.X / scale, px.Y / scale);

    /// <summary>把矩形从客户区坐标搬到屏幕坐标。</summary>
    public static WbRect ClientToScreen(WbRect client, WbRect windowFrame) =>
        new(windowFrame.X + client.X, windowFrame.Y + client.Y, client.W, client.H);

    /// <summary>
    /// 判断某个元素矩形「有多少比例可见」——用于遮挡判断。
    /// 与 macOS 的 occlusion 逻辑同一口径：可见比例低于阈值就认为被遮挡，
    /// 但**不因此就去激活前台**（改成走 UIA 语义操作或如实报 failureReason）。
    /// </summary>
    public static double VisibleRatio(WbRect target, IEnumerable<WbRect> occluders)
    {
        if (target.IsEmpty) return 0;
        var visible = target;
        foreach (var occ in occluders)
        {
            if (occ.IsEmpty) continue;
            var hit = visible.Intersect(occ);
            if (hit.IsEmpty) continue;
            // 逐块扣除过于复杂：这里用「被完全覆盖」与「部分覆盖」两档近似，
            // 结果只用于决定走哪条执行路径，不用于精确渲染。
            if (hit.Area >= visible.Area * 0.995) return 0;
            visible = new WbRect(visible.X, visible.Y, visible.W, visible.H);
        }
        var covered = 0.0;
        foreach (var occ in occluders)
        {
            covered += target.Intersect(occ).Area;
        }
        var ratio = 1.0 - Math.Min(1.0, covered / target.Area);
        return Math.Max(0, ratio);
    }
}
