using Wbcu.Contract;
using Wbcu.Windows.Discovery;
using Wbcu.Windows.Win32;

namespace Wbcu.Windows.Session;

/// <summary>
/// 会话持久化。一个会话 = 一次解析 + 全程复用。
///
/// 为什么要有这一层：v0.4 之前每次动作都重新枚举窗口、重建捕获、重走 UIA 根节点，
/// 单次 300ms 起，而且每次都可能触发目标的重新布局（视觉上的闪烁）。
/// 会话把这部分成本摊到一次，后续动作只做「定位 + 执行 + 验证」。
/// </summary>
public static class SessionStore
{
    public static SessionRecord Create(WindowInfo window, bool ghost)
    {
        var now = DateTime.UtcNow.ToString("O");
        var rec = new SessionRecord
        {
            Id = Paths.NewSessionId(window.Pid, window.HwndHex),
            Platform = Platforms.Windows,
            Engine = Engines.WindowsUia,
            Pid = window.Pid,
            WindowHandle = window.HwndHex,
            Executable = window.Exe,
            AppName = window.ProcessName,
            PackageFamily = window.PackageFamily,
            WindowClass = window.Class,
            Title = window.Title,
            Frame = new double[] { window.Frame.Left, window.Frame.Top, window.Frame.Width, window.Frame.Height },
            Dpi = window.Dpi,
            Scale = window.Scale,
            CreatedAt = now,
            LastUsedAt = now,
            Uses = 1,
            WindowState = window.Minimized ? "minimized" : window.Maximized ? "maximized" : "normal",
            Ghost = ghost,
            GhostPipe = ghost ? GhostPipeName(window.HwndHex) : "",
        };
        Save(rec);
        return rec;
    }

    public static string GhostPipeName(string windowHandle) =>
        "wbcu-ghost-" + Paths.SafeFileName(windowHandle);

    public static void Save(SessionRecord rec)
    {
        var path = Paths.SessionFile(rec.Id);
        File.WriteAllText(path, Json.Serialize(rec, pretty: true));
    }

    public static SessionRecord? Load(string? id)
    {
        if (string.IsNullOrWhiteSpace(id)) return null;
        var path = Paths.SessionFile(id!);
        if (!File.Exists(path)) return null;
        try
        {
            return Json.Deserialize<SessionRecord>(File.ReadAllText(path));
        }
        catch
        {
            return null;
        }
    }

    public static List<SessionRecord> List()
    {
        var list = new List<SessionRecord>();
        foreach (var f in Directory.EnumerateFiles(Paths.Sessions, "*.json"))
        {
            try
            {
                var rec = Json.Deserialize<SessionRecord>(File.ReadAllText(f));
                if (rec != null) list.Add(rec);
            }
            catch { }
        }
        return list.OrderByDescending(r => r.LastUsedAt).ToList();
    }

    public static bool End(string id)
    {
        var path = Paths.SessionFile(id);
        if (!File.Exists(path)) return false;
        try
        {
            File.Delete(path);
            return true;
        }
        catch
        {
            return false;
        }
    }

    public static int EndAll()
    {
        var n = 0;
        foreach (var f in Directory.EnumerateFiles(Paths.Sessions, "*.json").ToList())
        {
            try { File.Delete(f); n++; } catch { }
        }
        return n;
    }

    /// <summary>
    /// 清理失效会话：目标进程已退出，或窗口句柄已无效，或超过保留时间。
    /// 只删记录，不碰任何运行中的进程。
    /// </summary>
    public static (List<string> Removed, int Kept) Prune(TimeSpan maxAge, bool dryRun)
    {
        var removed = new List<string>();
        var kept = 0;
        foreach (var rec in List())
        {
            var stale = false;
            if (DateTime.TryParse(rec.LastUsedAt, out var last) && DateTime.UtcNow - last.ToUniversalTime() > maxAge)
            {
                stale = true;
            }
            if (!stale && !WindowEnumerator.TryParseHwnd(rec.WindowHandle, out _))
            {
                stale = true;
            }

            if (stale)
            {
                if (!dryRun) End(rec.Id);
                removed.Add(rec.Id);
            }
            else
            {
                kept++;
            }
        }
        return (removed, kept);
    }

    /// <summary>
    /// 取会话并校验它还有效。失效时抛出带 session_stale 的 CliError，
    /// 而不是拿着一个死 HWND 继续操作（那会得到一堆莫名其妙的失败）。
    /// </summary>
    public static (SessionRecord Rec, WindowInfo Window) Require(string? id)
    {
        var rec = Load(id);
        if (rec == null)
        {
            throw new Cli.CliError(ErrorCodes.NoSession,
                $"会话不存在：{id ?? "(未指定 --id)"}（先跑 wbcu attach --app <应用>）", Cli.ExitCodes.TargetNotFound);
        }

        if (!WindowEnumerator.TryParseHwnd(rec.WindowHandle, out var hwnd))
        {
            throw new Cli.CliError(ErrorCodes.SessionStale,
                $"会话 {rec.Id} 的窗口已不存在（{rec.WindowHandle}），目标可能已关闭",
                Cli.ExitCodes.TargetNotFound);
        }

        var win = WindowEnumerator.Get(hwnd);
        if (win == null)
        {
            throw new Cli.CliError(ErrorCodes.SessionStale,
                $"会话 {rec.Id} 的窗口句柄已失效", Cli.ExitCodes.TargetNotFound);
        }

        // 句柄复用时会有「同句柄但不同进程」的情况，必须校验 PID
        if (win.Pid != rec.Pid)
        {
            throw new Cli.CliError(ErrorCodes.SessionStale,
                $"窗口句柄被其它进程复用了（会话 pid={rec.Pid}，当前 pid={win.Pid}），请重新 attach",
                Cli.ExitCodes.TargetNotFound);
        }

        rec.LastUsedAt = DateTime.UtcNow.ToString("O");
        rec.Uses++;
        rec.Frame = new double[] { win.Frame.Left, win.Frame.Top, win.Frame.Width, win.Frame.Height };
        rec.WindowState = win.Minimized ? "minimized" : win.Maximized ? "maximized" : "normal";
        Save(rec);

        return (rec, win);
    }
}
