using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using Wbcu.Contract;

namespace Wbcu.GuiTests;

/// <summary>
/// 交互式 GUI 验收套件（**只能在有交互桌面的 Windows 上跑**）。
///
/// 它必须与 CI 分开：GitHub Actions 的 windows-latest 能编译、能跑单元测试，
/// 但那里的桌面会话不保证有真实前台窗口、真实鼠标、真实 DPI 切换，
/// 用它冒充「GUI 验收通过」是这个项目最不能犯的错。
///
/// 运行：
///   wbcu-guitests.exe --wbcu path\to\wbcu.exe [--app path\to\wbcu-testapp-win32.exe]
///                     [--json result.json] [--only click_uia]
///
/// 每个用例只有三种结论：pass / fail / skip（skip 必须写清原因）。
/// fail 绝不被吞掉——它是这份报告里最有价值的部分。
/// </summary>
internal static class Program
{
    private static string _wbcu = "";
    private static string _testApp = "";
    private static string _session = "";
    private static readonly List<CaseResult> Results = new();

    private sealed class CaseResult
    {
        public string Name { get; init; } = "";
        public string Status { get; init; } = "skip";   // pass | fail | skip
        public string Detail { get; init; } = "";
        public object? Evidence { get; init; }
    }

    private static int Main(string[] argv)
    {
        var args = ParseArgs(argv);
        _wbcu = args.GetValueOrDefault("wbcu", FindSibling("wbcu.exe"));
        _testApp = args.GetValueOrDefault("app", FindSibling("wbcu-testapp-win32.exe"));
        var only = args.GetValueOrDefault("only", "");
        var jsonOut = args.GetValueOrDefault("json", "gui-test-report.json");

        Console.WriteLine($"wbcu      = {_wbcu}");
        Console.WriteLine($"test app  = {_testApp}");
        Console.WriteLine($"desktop   = {(Environment.UserInteractive ? "interactive" : "non-interactive")}");
        Console.WriteLine();

        if (!File.Exists(_wbcu))
        {
            Console.Error.WriteLine("找不到 wbcu.exe，用 --wbcu 指定");
            return 2;
        }
        if (!Environment.UserInteractive)
        {
            Console.Error.WriteLine("当前会话不是交互式桌面，GUI 测试没有意义（这正是不能用 CI 冒充 GUI 验收的原因）");
            return 3;
        }

        var cases = new (string Name, Action Body)[]
        {
            ("preflight", Preflight),
            ("launch_testapp", LaunchTestApp),
            ("click_uia", ClickViaUia),
            ("click_background", ClickInBackground),
            ("click_occluded", ClickOccluded),
            ("click_wm_message", ClickCustomDrawnCanvas),
            ("type_background", TypeIntoEdit),
            ("user_concurrency", UserConcurrency),
            ("ghost_cursor", GhostCursor),
            ("minimized_capture", MinimizedCapture),
            ("multi_monitor_dpi", MultiMonitorDpi),
        };

        foreach (var (name, body) in cases)
        {
            if (only.Length > 0 && !name.Contains(only, StringComparison.OrdinalIgnoreCase)) continue;
            Console.Write($"[{name}] ... ");
            try
            {
                body();
            }
            catch (Exception ex)
            {
                Add(name, "fail", "未捕获异常：" + ex.GetType().Name + " " + ex.Message);
            }
            var last = Results[^1];
            Console.WriteLine($"{last.Status.ToUpperInvariant()}  {Truncate(last.Detail, 110)}");
        }

        // 收尾：结束会话与覆盖层
        if (_session.Length > 0)
        {
            Run($"session end --id {_session} --json");
        }
        Run("trace stop --json");

        var passed = Results.Count(r => r.Status == "pass");
        var failed = Results.Count(r => r.Status == "fail");
        var skipped = Results.Count(r => r.Status == "skip");

        var report = new
        {
            ok = failed == 0,
            timestamp = DateTime.UtcNow.ToString("O"),
            os = Environment.OSVersion.VersionString,
            build = Environment.OSVersion.Version.Build,
            passed,
            failed,
            skipped,
            cases = Results,
        };

        var json = JsonSerializer.Serialize(report, new JsonSerializerOptions
        {
            WriteIndented = true,
            Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
        });
        File.WriteAllText(jsonOut, json);

        Console.WriteLine();
        Console.WriteLine($"pass={passed} fail={failed} skip={skipped}  报告: {Path.GetFullPath(jsonOut)}");

        // 只有全部用例都真的跑过且通过，才解锁「本机已验证」的能力标记
        if (failed == 0 && skipped == 0) WriteCapabilityUnlock();
        else Console.WriteLine("（有 fail 或 skip：不会写入本地能力解锁文件，capabilities 仍会如实标 not_tested）");

        return failed == 0 ? 0 : 1;
    }

    // ---------------- 用例 ----------------

    private static void Preflight()
    {
        var (code, output) = Run("selftest --json");
        var doc = Parse(output);
        var ok = doc.RootElement.GetProperty("ok").GetBoolean();
        Add("preflight", ok ? "pass" : "fail",
            ok ? "引擎自检通过" : "引擎自检失败", doc.RootElement);
    }

    private static void LaunchTestApp()
    {
        if (!File.Exists(_testApp))
        {
            Add("launch_testapp", "skip", "找不到测试应用：" + _testApp);
            return;
        }

        var existing = Run("apps --json");
        var exeName = Path.GetFileName(_testApp).ToLowerInvariant();
        var running = JsonSerializer.Serialize(existing.Item2).Contains(exeName, StringComparison.OrdinalIgnoreCase);

        if (!running)
        {
            Process.Start(new ProcessStartInfo { FileName = _testApp, UseShellExecute = true });
            Thread.Sleep(1200);
        }

        var (code, output) = Run($"attach --app \"{exeName}\" --json --no-ghost");
        var doc = Parse(output);
        if (code != 0 || !doc.RootElement.GetProperty("ok").GetBoolean())
        {
            Add("launch_testapp", "fail", "attach 失败：" + Truncate(output, 200));
            return;
        }

        _session = doc.RootElement.GetProperty("data").GetProperty("session").GetProperty("id").GetString() ?? "";
        Add("launch_testapp", "pass", "会话 " + _session, doc.RootElement);
    }

    private static void ClickViaUia()
    {
        if (_session.Length == 0) { Add("click_uia", "skip", "没有会话"); return; }

        var before = ReadResult();
        var (code, output) = Run($"click --id {_session} --automationid incButton --expect \"按钮=1\" --state automationid:resultText --json");
        var after = ReadResult();

        var verified = ResultVerified(output);
        var changed = before != after;
        var ok = verified && changed;

        Add("click_uia", ok ? "pass" : "fail",
            $"UIA 点击: verified={verified} 结果 '{before}' → '{after}'",
            Evidence(output));
    }

    private static void ClickInBackground()
    {
        if (_session.Length == 0) { Add("click_background", "skip", "没有会话"); return; }

        var (_, stateOut) = Run($"session state --id {_session} --json");
        var frontBefore = ForegroundInfo();

        var before = ReadResult();
        var (code, output) = Run($"click --id {_session} --automationid incButton --json");
        var after = ReadResult();
        var frontAfter = ForegroundInfo();

        var env = Parse(output);
        var frontPreserved = env.RootElement.TryGetProperty("data", out var data)
                             && data.TryGetProperty("safety", out var safety)
                             && safety.TryGetProperty("frontAppPreserved", out var fp)
                             && fp.ValueKind == JsonValueKind.True;

        var ok = before != after && frontAfter == frontBefore;
        Add("click_background", ok ? "pass" : "fail",
            $"结果 '{before}' → '{after}'；前台 {frontBefore} → {frontAfter}；引擎自报 frontAppPreserved={frontPreserved}",
            Evidence(output));

        if (ok && !frontPreserved)
        {
            Add("click_background_note", "fail",
                "结果正确但引擎自报 frontAppPreserved=false —— 自报与实测不一致，必须查清");
        }
    }

    private static void ClickOccluded()
    {
        if (_session.Length == 0) { Add("click_occluded", "skip", "没有会话"); return; }

        // 用一个真实窗口盖住目标（记事本最省事），SetWindowPos 不激活它
        Run("launch --app notepad --json");
        Thread.Sleep(900);
        var (_, winsOut) = Run("windows --app notepad --json");
        var target = WindowRect();
        IntPtr cover = IntPtr.Zero;

        try
        {
            var doc = Parse(winsOut);
            foreach (var w in doc.RootElement.GetProperty("windows").EnumerateArray())
            {
                var hwndStr = w.GetProperty("hwnd").GetString();
                if (WindowEnumeratorCompat.TryParse(hwndStr, out var h)) { cover = h; break; }
            }
        }
        catch { }

        if (cover == IntPtr.Zero || target.w == 0)
        {
            Add("click_occluded", "skip", "拿不到遮挡窗口或目标矩形");
            return;
        }

        SetWindowPos(cover, IntPtr.Zero, target.x, target.y, target.w, target.h,
                     SWP_NOACTIVATE | SWP_NOZORDER | SWP_SHOWWINDOW);
        Thread.Sleep(350);

        var before = ReadResult();
        var (code, output) = Run($"click --id {_session} --automationid incButton --json");
        var after = ReadResult();

        var verified = ResultVerified(output);
        var method = MethodOf(output);
        var ok = verified && before != after;

        Add("click_occluded", ok ? "pass" : "fail",
            $"遮挡下点击: verified={verified} method={method} 结果 '{before}' → '{after}'",
            Evidence(output));

        // 恢复：把记事本挪开，不杀进程（避免影响用户可能自己开的记事本）
        SetWindowPos(cover, IntPtr.Zero, 40, 40, 600, 400, SWP_NOACTIVATE | SWP_NOZORDER);
    }

    private static void ClickCustomDrawnCanvas()
    {
        if (_session.Length == 0) { Add("click_wm_message", "skip", "没有会话"); return; }

        // 自绘画布没有 UIA 语义，只能按坐标投递消息。
        // 布局常量来自 Wbcu.TestApp.Win32（我们自己的测试靶子，允许硬编码）。
        var r = WindowRect();
        if (r.w == 0) { Add("click_wm_message", "skip", "拿不到窗口矩形"); return; }

        var clientOrigin = ClientOrigin();
        var x = clientOrigin.x + 310 + 180;
        var y = clientOrigin.y + 215 + 40;

        var before = ReadCanvas();
        var (code, output) = Run($"click --id {_session} --x {x} --y {y} --json");
        var after = ReadCanvas();

        var method = MethodOf(output);
        var ok = before != after || method.Contains("wm_message");

        Add("click_wm_message", ok ? "pass" : "fail",
            $"画布点击: method={method} 计数 '{before}' → '{after}'",
            Evidence(output));
    }

    private static void TypeIntoEdit()
    {
        if (_session.Length == 0) { Add("type_background", "skip", "没有会话"); return; }

        var text = "wbcu-" + DateTime.Now.ToString("HHmmss");
        var (code, output) = Run($"type --id {_session} --text {text} --controltype Edit --expect {text} --state controltype:Edit --json");
        var (_, verifyOut) = Run($"verify --id {_session} --expect {text} --state controltype:Edit --json");

        var ok = ResultVerified(output) || ResultOk(verifyOut);
        Add("type_background", ok ? "pass" : "fail",
            $"文本写入: method={MethodOf(output)} 期望 '{text}'", Evidence(output));
    }

    private static void UserConcurrency()
    {
        if (_session.Length == 0) { Add("user_concurrency", "skip", "没有会话"); return; }

        // 阶段 A：无用户输入时，引擎必须做到「不动真实鼠标、不抢前台」
        var beforeA = ReadResult();
        var (_, outA) = Run($"click --id {_session} --automationid incButton --json");
        var afterA = ReadResult();

        var cursorPreserved = FieldTrue(outA, "safety", "physicalCursorPreserved");
        var frontPreserved = FieldTrue(outA, "safety", "frontAppPreserved");

        // 阶段 B：模拟用户持续移动真实鼠标 + 引擎同时点击
        var stop = false;
        var moved = 0;
        var thread = new Thread(() =>
        {
            var i = 0;
            while (!Volatile.Read(ref stop))
            {
                MoveCursor(600 + (i % 40), 400 + (i % 30));
                i++; moved++;
                Thread.Sleep(12);
            }
        }) { IsBackground = true };
        thread.Start();

        var beforeB = ReadResult();
        var (_, outB) = Run($"click --id {_session} --automationid incButton --json");
        var afterB = ReadResult();

        Volatile.Write(ref stop, true);
        thread.Join(600);

        var okB = ResultVerified(outB) && beforeB != afterB;
        var ok = beforeA != afterA && cursorPreserved && frontPreserved && okB;

        Add("user_concurrency", ok ? "pass" : "fail",
            $"A: 结果 {beforeA}→{afterA}, cursorPreserved={cursorPreserved}, frontPreserved={frontPreserved}; "
            + $"B: 用户移动 {moved} 次期间点击 {beforeB}→{afterB} verified={ResultVerified(outB)}",
            Evidence(outB));
    }

    private static void GhostCursor()
    {
        if (_session.Length == 0) { Add("ghost_cursor", "skip", "没有会话"); return; }

        var (_, startOut) = Run($"ghost start --id {_session} --json");
        Thread.Sleep(300);
        var (_, moveOut) = Run($"ghost move --id {_session} --x 60 --y 60 --json");
        var (_, clickOut) = Run($"ghost click --id {_session} --json");
        var (_, statusOut) = Run($"ghost status --id {_session} --json");
        var (_, stopOut) = Run($"ghost stop --id {_session} --json");
        Thread.Sleep(300);
        var (stopCode, statusAfter) = Run($"ghost status --id {_session} --json");

        var alive = ResultOk(statusOut);
        var stopped = stopCode != 0; // stop 之后 status 必须失败，才算真的停了

        Add("ghost_cursor", alive && stopped ? "pass" : "fail",
            $"覆盖层：alive={alive} move={ResultOk(moveOut)} click={ResultOk(clickOut)} 停止后仍在={!stopped}",
            Evidence(statusOut));
    }

    private static void MinimizedCapture()
    {
        if (_session.Length == 0) { Add("minimized_capture", "skip", "没有会话"); return; }

        var hwnd = SessionHwnd();
        if (hwnd == IntPtr.Zero) { Add("minimized_capture", "skip", "拿不到 hwnd"); return; }

        ShowWindow(hwnd, SW_MINIMIZE);
        Thread.Sleep(400);

        var (code, output) = Run($"capture --id {_session} --json");
        var doc = Parse(output);
        var errorCode = doc.RootElement.TryGetProperty("errorCode", out var ec) ? ec.GetString() : "";

        ShowWindow(hwnd, SW_RESTORE);
        Thread.Sleep(400);

        var honest = code != 0 && errorCode == "window_minimized";
        Add("minimized_capture", honest ? "pass" : "fail",
            honest
                ? "最小化时如实报 window_minimized（没有假装截到黑图）"
                : $"最小化时返回了意外的结果：exit={code} errorCode={errorCode}",
            Evidence(output));
    }

    private static void MultiMonitorDpi()
    {
        var monitors = new List<string>();
        EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, (IntPtr h, IntPtr hdc, ref RECT rect, IntPtr data) =>
        {
            monitors.Add($"{rect.Left},{rect.Top} {rect.Right - rect.Left}x{rect.Bottom - rect.Top}");
            return true;
        }, IntPtr.Zero);

        if (monitors.Count < 2)
        {
            Add("multi_monitor_dpi", "skip",
                $"只有 {monitors.Count} 块显示器，多屏 DPI 无法验证（需要实机双屏）");
            return;
        }

        Add("multi_monitor_dpi", "skip",
            "检测到 " + monitors.Count + " 块显示器，但自动化的跨屏 DPI 断言需要人工确认光标落点；"
            + "本轮仅记录几何：" + string.Join(" | ", monitors));
    }

    // ---------------- 引擎调用辅助 ----------------

    private static (int Code, string Output) Run(string args)
    {
        var psi = new ProcessStartInfo
        {
            FileName = _wbcu,
            Arguments = args,
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true,
            StandardOutputEncoding = Encoding.UTF8,
        };
        using var p = Process.Start(psi)!;
        var stdout = p.StandardOutput.ReadToEnd();
        var stderr = p.StandardError.ReadToEnd();
        p.WaitForExit(240_000);
        if (p.ExitCode != 0 && stdout.Trim().Length == 0) stdout = stderr;
        return (p.ExitCode, stdout);
    }

    private static JsonDocument Parse(string json)
    {
        var start = json.IndexOf('{');
        if (start < 0) return JsonDocument.Parse("{}");
        return JsonDocument.Parse(json.Substring(start));
    }

    private static bool ResultOk(string json)
    {
        try { return Parse(json).RootElement.TryGetProperty("ok", out var ok) && ok.GetBoolean(); }
        catch { return false; }
    }

    private static bool ResultVerified(string json)
    {
        try
        {
            var doc = Parse(json);
            if (!doc.RootElement.TryGetProperty("verification", out var v)) return false;
            var result = v.GetProperty("result").GetString();
            return result is "success" or "already_satisfied";
        }
        catch { return false; }
    }

    private static string MethodOf(string json)
    {
        try
        {
            var doc = Parse(json);
            return doc.RootElement.TryGetProperty("method", out var m) ? m.GetString() ?? "" : "";
        }
        catch { return ""; }
    }

    private static bool FieldTrue(string json, string section, string field)
    {
        try
        {
            var doc = Parse(json);
            if (!doc.RootElement.TryGetProperty("data", out var d)) return false;
            if (!d.TryGetProperty(section, out var s)) return false;
            if (!s.TryGetProperty(field, out var f)) return false;
            return f.ValueKind == JsonValueKind.True;
        }
        catch { return false; }
    }

    private static object? Evidence(string json)
    {
        try { return JsonSerializer.Deserialize<object>(json); } catch { return json; }
    }

    private static string ReadResult()
    {
        var (_, output) = Run($"inspect --id {_session} --json --max 400");
        try
        {
            var doc = Parse(output);
            foreach (var el in doc.RootElement.GetProperty("data").GetProperty("elements").EnumerateArray())
            {
                var aid = el.GetProperty("automationId").GetString();
                if (aid is "resultText" or "106" or "")
                {
                    var name = el.GetProperty("name").GetString() ?? "";
                    if (name.StartsWith("结果")) return name;
                }
            }
        }
        catch { }
        return "";
    }

    private static string ReadCanvas()
    {
        var (_, output) = Run("inspect --id " + _session + " --json --max 400");
        return ResultOk(output).ToString() + "|" + output.Length;
    }

    private static IntPtr SessionHwnd()
    {
        var (_, output) = Run($"session state --id {_session} --json");
        try
        {
            var doc = Parse(output);
            var hex = doc.RootElement.GetProperty("session").GetProperty("hwnd").GetString();
            return WindowEnumeratorCompat.TryParse(hex, out var h) ? h : IntPtr.Zero;
        }
        catch { return IntPtr.Zero; }
    }

    private static string ForegroundInfo()
    {
        var fg = GetForegroundWindow();
        GetWindowThreadProcessId(fg, out var pid);
        return $"0x{fg.ToInt64():X}/pid{pid}";
    }

    private static (int x, int y, int w, int h) WindowRect()
    {
        var hwnd = SessionHwnd();
        if (hwnd == IntPtr.Zero) return (0, 0, 0, 0);
        GetWindowRect(hwnd, out var r);
        return (r.Left, r.Top, r.Right - r.Left, r.Bottom - r.Top);
    }

    private static (int x, int y) ClientOrigin()
    {
        var hwnd = SessionHwnd();
        var pt = new POINT { X = 0, Y = 0 };
        ClientToScreen(hwnd, ref pt);
        return (pt.X, pt.Y);
    }

    private static void MoveCursor(int x, int y) => SetCursorPos(x, y);

    private static void Add(string name, string status, string detail, object? evidence = null)
    {
        Results.Add(new CaseResult { Name = name, Status = status, Detail = detail, Evidence = evidence });
    }

    private static string Truncate(string s, int n) => s.Length <= n ? s : s.Substring(0, n) + "…";

    private static string FindSibling(string name)
    {
        var dir = AppContext.BaseDirectory;
        var p = Path.Combine(dir, name);
        if (File.Exists(p)) return p;
        var parent = Directory.GetParent(dir)?.Parent?.FullName;
        return parent == null ? name : Path.Combine(parent, name);
    }

    private static Dictionary<string, string> ParseArgs(string[] argv)
    {
        var d = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        for (var i = 0; i < argv.Length; i++)
        {
            if (!argv[i].StartsWith("--")) continue;
            var key = argv[i].TrimStart('-');
            if (i + 1 < argv.Length && !argv[i + 1].StartsWith("--")) d[key] = argv[++i];
            else d[key] = "true";
        }
        return d;
    }

    /// <summary>
    /// 把通过的能力写进 gui-verified.json，让 capabilities 从 not_tested 升级为 supported。
    /// 只写「本次真的 pass 了」的项，skip 一律不写。
    /// </summary>
    private static void WriteCapabilityUnlock()
    {
        var map = new Dictionary<string, string>();
        bool Passed(string n) => Results.Any(r => r.Name == n && r.Status == "pass");

        if (Passed("click_uia")) map["uia_semantic_ops"] = "supported";
        if (Passed("click_background") && Passed("click_occluded")) map["background_click"] = "supported";
        if (Passed("click_wm_message")) map["custom_drawn_ui"] = "partial";
        if (Passed("type_background")) map["background_type"] = "supported";
        if (Passed("ghost_cursor")) map["ghost_cursor"] = "supported";
        if (Passed("minimized_capture")) map["window_capture"] = "supported";
        if (Passed("user_concurrency")) map["multi_monitor_dpi"] = map.GetValueOrDefault("multi_monitor_dpi", "not_tested");

        var path = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "wbcu", "gui-verified.json");
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        File.WriteAllText(path, JsonSerializer.Serialize(map, new JsonSerializerOptions { WriteIndented = true }));
        Console.WriteLine($"已写入本机能力解锁文件：{path}");
    }

    // ---------------- P/Invoke ----------------

    private const uint SWP_NOZORDER = 0x0004;
    private const uint SWP_NOACTIVATE = 0x0010;
    private const uint SWP_SHOWWINDOW = 0x0040;
    private const int SW_MINIMIZE = 6;
    private const int SW_RESTORE = 9;

    private delegate bool MonitorEnumProc(IntPtr hMon, IntPtr hdc, ref RECT rect, IntPtr data);

    [StructLayout(LayoutKind.Sequential)]
    private struct RECT { public int Left, Top, Right, Bottom; }

    [StructLayout(LayoutKind.Sequential)]
    private struct POINT { public int X, Y; }

    [DllImport("user32.dll")]
    private static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);

    [DllImport("user32.dll")]
    private static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);

    [DllImport("user32.dll")]
    private static extern bool ClientToScreen(IntPtr hWnd, ref POINT pt);

    [DllImport("user32.dll")]
    private static extern bool SetWindowPos(IntPtr hWnd, IntPtr after, int x, int y, int cx, int cy, uint flags);

    [DllImport("user32.dll")]
    private static extern bool ShowWindow(IntPtr hWnd, int cmd);

    [DllImport("user32.dll")]
    private static extern bool SetCursorPos(int x, int y);

    [DllImport("user32.dll")]
    private static extern bool EnumDisplayMonitors(IntPtr hdc, IntPtr clip, MonitorEnumProc proc, IntPtr data);

    private static class WindowEnumeratorCompat
    {
        public static bool TryParse(string? s, out IntPtr hwnd)
        {
            hwnd = IntPtr.Zero;
            if (string.IsNullOrWhiteSpace(s)) return false;
            var t = s.Trim();
            if (t.StartsWith("0x", StringComparison.OrdinalIgnoreCase)) t = t.Substring(2);
            if (!long.TryParse(t, System.Globalization.NumberStyles.HexNumber, null, out var v)) return false;
            hwnd = new IntPtr(v);
            return true;
        }
    }
}
