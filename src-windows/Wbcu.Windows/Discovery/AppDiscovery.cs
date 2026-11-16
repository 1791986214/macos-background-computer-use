namespace Wbcu.Windows.Discovery;

/// <summary>
/// 应用发现与匹配。
///
/// 匹配顺序刻意与 macOS 的 findRunningApp 对齐（精确优先，模糊最后），
/// 避免 "Safari" 撞到 "SafariPlatformSupport.Helper" 这类误配在 Windows 上重演
/// （Windows 上的对应坑：calc 撞 calc 的辅助进程、Edge 撞 Edge 的更新器）。
/// </summary>
public sealed class AppInfo
{
    public int Pid { get; init; }
    public string Name { get; init; } = "";
    public string Exe { get; init; } = "";
    public string PackageFamily { get; init; } = "";
    public int WindowCount { get; init; }
    public bool Foreground { get; init; }
    public bool Minimized { get; init; }

    public Dictionary<string, object?> ToJson() => new()
    {
        ["pid"] = Pid,
        ["name"] = Name,
        ["exe"] = Exe,
        ["packageFamily"] = PackageFamily,
        ["windows"] = WindowCount,
        ["foreground"] = Foreground,
        ["minimized"] = Minimized,
    };
}

public static class AppDiscovery
{
    public static List<AppInfo> List()
    {
        var wins = WindowEnumerator.TopLevel();
        var fgPid = 0;
        Win32.Native.GetWindowThreadProcessId(Win32.Native.GetForegroundWindow(), out var fgp);
        fgPid = (int)fgp;

        return wins
            .GroupBy(w => w.Pid)
            .Select(g =>
            {
                var first = g.First();
                return new AppInfo
                {
                    Pid = g.Key,
                    Name = first.ProcessName,
                    Exe = first.Exe,
                    PackageFamily = first.PackageFamily,
                    WindowCount = g.Count(),
                    Foreground = g.Key == fgPid,
                    Minimized = g.All(w => w.Minimized),
                };
            })
            .OrderByDescending(a => a.Foreground)
            .ThenByDescending(a => a.WindowCount)
            .ThenBy(a => a.Name, StringComparer.OrdinalIgnoreCase)
            .ToList();
    }

    /// <summary>
    /// 按 token 找应用。token 可以是 pid / exe 路径 / exe 名 / 进程名 / 包族名 / 窗口标题片段。
    /// 返回该应用最可能是「主窗口」的那个窗口。
    /// </summary>
    public static (AppInfo App, WindowInfo Window)? Find(string token)
    {
        if (string.IsNullOrWhiteSpace(token)) return null;
        var t = token.Trim();
        var wins = WindowEnumerator.TopLevel(includeInvisible: true);
        if (wins.Count == 0) return null;

        // 0) 直接是 HWND？
        if (WindowEnumerator.TryParseHwnd(t, out var hwnd))
        {
            var w0 = WindowEnumerator.Get(hwnd);
            if (w0 == null) return null;
            var app0 = ToApp(w0, wins);
            return (app0, w0);
        }

        var tl = t.ToLowerInvariant();

        // 1) pid
        if (int.TryParse(t, out var pid))
        {
            var w = PickMain(wins.Where(x => x.Pid == pid));
            if (w != null) return (ToApp(w, wins), w);
        }

        // 2) 精确 exe 路径
        var byPath = wins.FirstOrDefault(x => x.Exe.Equals(t, StringComparison.OrdinalIgnoreCase));
        if (byPath != null) return (ToApp(byPath, wins), byPath);

        // 3) 精确 exe 名（补 .exe）
        var exeName = tl.EndsWith(".exe") ? tl : tl + ".exe";
        var byExe = PickMain(wins.Where(x =>
            string.Equals(System.IO.Path.GetFileName(x.Exe), exeName, StringComparison.OrdinalIgnoreCase)));
        if (byExe != null) return (ToApp(byExe, wins), byExe);

        // 4) 精确进程名
        var byProc = PickMain(wins.Where(x =>
            string.Equals(x.ProcessName, tl, StringComparison.OrdinalIgnoreCase)));
        if (byProc != null) return (ToApp(byProc, wins), byProc);

        // 5) 包族名精确
        var byPkg = PickMain(wins.Where(x =>
            string.Equals(x.PackageFamily, t, StringComparison.OrdinalIgnoreCase)));
        if (byPkg != null) return (ToApp(byPkg, wins), byPkg);

        // 6) 包族名包含（UWP 常用 calculator / windowscalculator 之类片段）
        var byPkgPart = PickMain(wins.Where(x =>
            x.PackageFamily.Length > 0 && x.PackageFamily.ToLowerInvariant().Contains(tl)));
        if (byPkgPart != null) return (ToApp(byPkgPart, wins), byPkgPart);

        // 7) 窗口标题包含（最后手段；明确排除 helper/updater 类进程）
        var byTitle = PickMain(wins.Where(x =>
            x.Title.ToLowerInvariant().Contains(tl) &&
            !x.ProcessName.Contains("helper", StringComparison.OrdinalIgnoreCase) &&
            !x.ProcessName.Contains("update", StringComparison.OrdinalIgnoreCase)));
        if (byTitle != null) return (ToApp(byTitle, wins), byTitle);

        return null;
    }

    private static AppInfo ToApp(WindowInfo w, List<WindowInfo> all)
    {
        Win32.Native.GetWindowThreadProcessId(Win32.Native.GetForegroundWindow(), out var fgp);
        var group = all.Where(x => x.Pid == w.Pid).ToList();
        return new AppInfo
        {
            Pid = w.Pid,
            Name = w.ProcessName,
            Exe = w.Exe,
            PackageFamily = w.PackageFamily,
            WindowCount = group.Count,
            Foreground = w.Pid == (int)fgp,
            Minimized = group.Count > 0 && group.All(x => x.Minimized),
        };
    }

    /// <summary>
    /// 选主窗口：优先「可见、未最小化、有标题、无 owner、面积最大」。
    /// 不优先「前台」—— 因为后台操作的前提恰恰是目标不在前台。
    /// </summary>
    public static WindowInfo? PickMain(IEnumerable<WindowInfo> candidates)
    {
        return candidates
            .Where(w => w.Visible && !w.Minimized && w.Owner == IntPtr.Zero && w.Frame.Width > 80 && w.Frame.Height > 60)
            .OrderByDescending(w => w.Title.Length > 0 ? 1 : 0)
            .ThenByDescending(w => (long)w.Frame.Width * w.Frame.Height)
            .FirstOrDefault()
            ?? candidates
                .Where(w => w.Visible && w.Owner == IntPtr.Zero)
                .OrderByDescending(w => (long)w.Frame.Width * w.Frame.Height)
                .FirstOrDefault()
            ?? candidates.OrderByDescending(w => (long)w.Frame.Width * w.Frame.Height).FirstOrDefault();
    }
}
