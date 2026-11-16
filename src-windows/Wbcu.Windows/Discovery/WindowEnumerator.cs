using System.Diagnostics;
using System.Text;
using Wbcu.Windows.Win32;

namespace Wbcu.Windows.Discovery;

/// <summary>一个顶层窗口的完整快照。字段口径与 macOS 的 WindowInfo 对齐。</summary>
public sealed class WindowInfo
{
    public IntPtr Hwnd { get; init; }
    public int Pid { get; init; }
    public string Exe { get; init; } = "";
    public string ProcessName { get; init; } = "";
    public string Title { get; init; } = "";
    public string Class { get; init; } = "";
    public string PackageFamily { get; init; } = "";
    public string AppUserModelId { get; init; } = "";

    /// <summary>屏幕物理像素（已用 DWMWA_EXTENDED_FRAME_BOUNDS 校正，去掉了 Win10 的隐形边框）。</summary>
    public Native.RECT Frame { get; init; }
    public int Dpi { get; init; } = 96;
    public double Scale => Dpi / 96.0;

    public bool Visible { get; init; }
    public bool Minimized { get; init; }
    public bool Maximized { get; init; }
    public bool Cloaked { get; init; }
    public IntPtr Owner { get; init; }

    /// <summary>Z 序（0 = 最上层）。用于遮挡判断。</summary>
    public int ZOrder { get; init; }

    public bool IsCandidate =>
        Visible && !Cloaked && Owner == IntPtr.Zero && Frame.Width > 0 && Frame.Height > 0;

    public string HwndHex => "0x" + Hwnd.ToInt64().ToString("X");

    public Wbcu.Contract.WbRect ToRect() =>
        new(Frame.Left, Frame.Top, Frame.Width, Frame.Height);

    public Dictionary<string, object?> ToJson() => new()
    {
        ["hwnd"] = HwndHex,
        ["pid"] = Pid,
        ["exe"] = Exe,
        ["process"] = ProcessName,
        ["title"] = Title,
        ["class"] = Class,
        ["packageFamily"] = PackageFamily,
        ["aumid"] = AppUserModelId,
        ["frame"] = new[] { Frame.Left, Frame.Top, Frame.Width, Frame.Height },
        ["dpi"] = Dpi,
        ["scale"] = Math.Round(Scale, 3),
        ["visible"] = Visible,
        ["minimized"] = Minimized,
        ["maximized"] = Maximized,
        ["cloaked"] = Cloaked,
        ["zOrder"] = ZOrder,
    };

    public override string ToString() => $"{HwndHex} [{Class}] \"{Title}\" pid={Pid} {Frame}";
}

public static class WindowEnumerator
{
    /// <summary>
    /// 枚举顶层窗口。EnumWindows 本身按 Z 序从上到下返回，
    /// 我们把这个顺序记下来用于遮挡判断（不需要额外查询）。
    /// </summary>
    public static List<WindowInfo> TopLevel(bool includeInvisible = false)
    {
        var list = new List<WindowInfo>();
        var z = 0;
        var procCache = new Dictionary<int, (string Exe, string Name, string Pkg, string Aumid)>();

        Native.EnumWindows((hwnd, _) =>
        {
            Native.GetWindowThreadProcessId(hwnd, out var pid);
            if (pid == 0) return true;

            var visible = Native.IsWindowVisible(hwnd);
            if (!visible && !includeInvisible) return true;

            if (!procCache.TryGetValue((int)pid, out var p))
            {
                p = ProcessInfo.Describe((int)pid);
                procCache[(int)pid] = p;
            }

            list.Add(Build(hwnd, (int)pid, p, z));
            z++;
            return true;
        }, IntPtr.Zero);

        return list;
    }

    public static WindowInfo? Get(IntPtr hwnd)
    {
        if (hwnd == IntPtr.Zero || !Native.IsWindow(hwnd)) return null;
        Native.GetWindowThreadProcessId(hwnd, out var pid);
        var p = ProcessInfo.Describe((int)pid);
        return Build(hwnd, (int)pid, p, -1);
    }

    public static WindowInfo? Get(string hwndHex)
    {
        if (!TryParseHwnd(hwndHex, out var h)) return null;
        return Get(h);
    }

    public static bool TryParseHwnd(string? s, out IntPtr hwnd)
    {
        hwnd = IntPtr.Zero;
        if (string.IsNullOrWhiteSpace(s)) return false;
        var t = s!.Trim();
        long v;
        if (t.StartsWith("0x", StringComparison.OrdinalIgnoreCase))
        {
            if (!long.TryParse(t.Substring(2), System.Globalization.NumberStyles.HexNumber, null, out v)) return false;
        }
        else if (!long.TryParse(t, out v)) return false;

        hwnd = new IntPtr(v);
        return Native.IsWindow(hwnd);
    }

    private static WindowInfo Build(IntPtr hwnd, int pid,
                                    (string Exe, string Name, string Pkg, string Aumid) p, int z)
    {
        var frame = FrameOf(hwnd);
        var dpi = (int)Native.GetDpiForWindow(hwnd);
        if (dpi <= 0) dpi = 96;

        Native.DwmGetWindowAttribute(hwnd, Native.DWMWA_CLOAKED, out int cloaked, sizeof(int));

        return new WindowInfo
        {
            Hwnd = hwnd,
            Pid = pid,
            Exe = p.Exe,
            ProcessName = p.Name,
            Title = Native.GetWindowText(hwnd),
            Class = Native.GetClassName(hwnd),
            PackageFamily = p.Pkg,
            AppUserModelId = p.Aumid,
            Frame = frame,
            Dpi = dpi,
            Visible = Native.IsWindowVisible(hwnd),
            Minimized = Native.IsIconic(hwnd),
            Maximized = Native.IsZoomed(hwnd),
            Cloaked = cloaked != 0,
            Owner = Native.GetWindow(hwnd, Native.GW_OWNER),
            ZOrder = z,
        };
    }

    /// <summary>
    /// 窗口外框。优先用 DWM 的 extended frame bounds：
    /// 老式 GetWindowRect 在 Win10 上会把一圈 7px 的隐形拖拽边算进去，
    /// 用它换算点击坐标会整体偏移（这是很多 RPA 点偏的根因）。
    /// </summary>
    public static Native.RECT FrameOf(IntPtr hwnd)
    {
        if (Native.DwmGetWindowAttribute(hwnd, Native.DWMWA_EXTENDED_FRAME_BOUNDS,
                                        out Native.RECT r, System.Runtime.InteropServices.Marshal.SizeOf<Native.RECT>()) == 0
            && r.Width > 0 && r.Height > 0)
        {
            return r;
        }
        Native.GetWindowRect(hwnd, out var fallback);
        return fallback;
    }

    /// <summary>该屏幕点上最上层的窗口（用于判断 Ghost Cursor 是否被别的东西压住）。</summary>
    public static IntPtr WindowAt(int x, int y) =>
        Native.WindowFromPoint(new Native.POINT(x, y));

    /// <summary>
    /// 目标窗口在某个屏幕点是否可见（未被别的窗口压住）。
    /// 只看「最上层窗口是不是自己或自己的子窗口」，不修改任何窗口状态。
    /// </summary>
    public static bool IsPointOnWindow(IntPtr target, int x, int y)
    {
        var top = WindowAt(x, y);
        if (top == IntPtr.Zero) return false;
        if (top == target) return true;

        // 逐级向上找 owner/父窗口，判断是否属于目标
        var cur = top;
        for (var guard = 0; guard < 16 && cur != IntPtr.Zero; guard++)
        {
            if (cur == target) return true;
            var owner = Native.GetWindow(cur, Native.GW_OWNER);
            if (owner == IntPtr.Zero) break;
            cur = owner;
        }
        return false;
    }
}

public static class ProcessInfo
{
    public static (string Exe, string Name, string Pkg, string Aumid) Describe(int pid)
    {
        var exe = ExePath(pid);
        var name = "";
        try
        {
            using var p = Process.GetProcessById(pid);
            name = p.ProcessName;
        }
        catch
        {
            if (!string.IsNullOrEmpty(exe)) name = Path.GetFileNameWithoutExtension(exe);
        }

        var (pkg, aumid) = PackageIds(pid);
        return (exe, name, pkg, aumid);
    }

    public static string ExePath(int pid)
    {
        var h = Native.OpenProcess(Native.PROCESS_QUERY_LIMITED_INFORMATION, false, pid);
        if (h == IntPtr.Zero) return "";
        try
        {
            var sb = new StringBuilder(1024);
            uint size = (uint)sb.Capacity;
            return Native.QueryFullProcessImageNameW(h, 0, sb, ref size) ? sb.ToString() : "";
        }
        finally
        {
            Native.CloseHandle(h);
        }
    }

    public static (string PackageFamily, string Aumid) PackageIds(int pid)
    {
        var h = Native.OpenProcess(Native.PROCESS_QUERY_LIMITED_INFORMATION, false, pid);
        if (h == IntPtr.Zero) return ("", "");
        try
        {
            uint len = 0;
            var rc = Native.GetPackageFamilyName(h, ref len, null);
            // ERROR_INSUFFICIENT_BUFFER = 122
            if (rc == 122 && len > 0)
            {
                var sb = new StringBuilder((int)len);
                if (Native.GetPackageFamilyName(h, ref len, sb) == 0)
                {
                    var pkg = sb.ToString();

                    uint alen = 0;
                    var arc = Native.GetApplicationUserModelId(h, ref alen, null);
                    var aumid = "";
                    if (arc == 122 && alen > 0)
                    {
                        var asb = new StringBuilder((int)alen);
                        if (Native.GetApplicationUserModelId(h, ref alen, asb) == 0) aumid = asb.ToString();
                    }
                    return (pkg, aumid);
                }
            }
            return ("", "");
        }
        finally
        {
            Native.CloseHandle(h);
        }
    }
}
