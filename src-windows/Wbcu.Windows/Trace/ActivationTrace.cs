using System.Text;
using System.Text.Json;
using Wbcu.Contract;
using Wbcu.Windows.Discovery;
using Wbcu.Windows.Win32;

namespace Wbcu.Windows.Trace;

/// <summary>
/// 激活追踪：回答一个具体问题 —— 「这次操作到底有没有把用户的前台抢走？」
///
/// 实现要点（与 macOS v0.5.0 的 Trace 同构）：
///   - 用事件驱动的 SetWinEventHook(EVENT_SYSTEM_FOREGROUND)，不轮询。
///     Windows 上轮询同样会被节流，而且会漏掉快速切换。
///   - 每条命令执行前写 t0、退出前写 t1（atexit 语义），归因窗口是**闭区间 [t0-50ms, t1]**。
///     早期 macOS 版本用 1.5s 窗口，把脚本事后自己 activate 的行为算成引擎的锅，这里不重犯。
///   - 归因优先级：落在某个命令窗口内且事件来自我们 → wbcu；
///     否则看真实输入年龄（<400ms）→ user；再否则 → external。
/// </summary>
public static class ActivationTrace
{
    public static string EventsFile => Path.Combine(Paths.Trace, "events.ndjson");
    public static string MarksFile => Path.Combine(Paths.Trace, "marks.ndjson");
    public static string PidFile => Path.Combine(Paths.Trace, "daemon.pid");

    private static string? _command;
    private static long _t0;
    private static bool _marked;

    public static void MarkStart(string command)
    {
        _command = command;
        _t0 = Environment.TickCount64;
        _marked = true;
    }

    /// <summary>退出时补写 t1。所有命令路径都要经过这里（Program 的 finally）。</summary>
    public static void MarkEnd()
    {
        if (!_marked || _command == null) return;
        _marked = false;
        try
        {
            if (!Directory.Exists(Paths.Trace)) return;
            var rec = new Dictionary<string, object?>
            {
                ["t0"] = _t0,
                ["t1"] = Environment.TickCount64,
                ["command"] = _command,
                ["pid"] = Environment.ProcessId,
            };
            File.AppendAllText(MarksFile, Json.Serialize(rec) + Environment.NewLine, Encoding.UTF8);
        }
        catch { }
    }

    /// <summary>追踪守护进程。纯旁观者：只挂钩子 + 落盘，不碰任何窗口状态。</summary>
    public static int Daemon()
    {
        Directory.CreateDirectory(Paths.Trace);
        File.WriteAllText(PidFile, Environment.ProcessId.ToString());

        var proc = new Native.WinEventDelegate((hook, evt, hwnd, idObject, idChild, thread, time) =>
        {
            if (evt != Native.EVENT_SYSTEM_FOREGROUND) return;

            var info = WindowEnumerator.Get(hwnd);
            var rec = new Dictionary<string, object?>
            {
                ["t"] = Environment.TickCount64,
                ["hwnd"] = hwnd.ToInt64() == 0 ? "0x0" : "0x" + hwnd.ToInt64().ToString("X"),
                ["pid"] = info?.Pid ?? 0,
                ["exe"] = info?.Exe ?? "",
                ["name"] = info?.ProcessName ?? "",
                ["title"] = info?.Title ?? "",
                ["inputAgeMs"] = Native.LastInputAgeMs(),
            };
            try
            {
                File.AppendAllText(EventsFile, Json.Serialize(rec) + Environment.NewLine, Encoding.UTF8);
            }
            catch { }
        });

        var hook = Native.SetWinEventHook(Native.EVENT_SYSTEM_FOREGROUND, Native.EVENT_SYSTEM_FOREGROUND,
                                          IntPtr.Zero, proc, 0, 0,
                                          Native.WINEVENT_OUTOFCONTEXT | Native.WINEVENT_SKIPOWNPROCESS);
        if (hook == IntPtr.Zero)
        {
            Console.Error.WriteLine("trace: SetWinEventHook 失败");
            return 3;
        }

        while (Native.GetMessageW(out var msg, IntPtr.Zero, 0, 0) > 0)
        {
            Native.TranslateMessage(ref msg);
            Native.DispatchMessageW(ref msg);
        }

        Native.UnhookWinEvent(hook);
        try { File.Delete(PidFile); } catch { }
        return 0;
    }

    public static int? DaemonPid()
    {
        if (!File.Exists(PidFile)) return null;
        if (!int.TryParse(File.ReadAllText(PidFile).Trim(), out var pid)) return null;
        try
        {
            using var p = System.Diagnostics.Process.GetProcessById(pid);
            return p.HasExited ? null : pid;
        }
        catch
        {
            return null;
        }
    }

    public static bool StopDaemon()
    {
        var pid = DaemonPid();
        if (pid == null) return false;
        try
        {
            using var p = System.Diagnostics.Process.GetProcessById(pid.Value);
            p.Kill();
            p.WaitForExit(2000);
            return true;
        }
        catch
        {
            return false;
        }
        finally
        {
            try { File.Delete(PidFile); } catch { }
        }
    }

    /// <summary>
    /// 归因报告。输出结构与 macOS 的 trace 报告保持一致：
    /// total / byOwner{wbcu,user,external} / wbcuActivations[] / 采样窗口说明。
    /// </summary>
    public static Dictionary<string, object?> Report(int limit = 200)
    {
        var events = ReadNdjson(EventsFile, limit);
        var marks = ReadNdjson(MarksFile, limit);

        var byOwner = new Dictionary<string, int> { ["wbcu"] = 0, ["user"] = 0, ["external"] = 0, ["unknown"] = 0 };
        var wbcuHits = new List<Dictionary<string, object?>>();

        foreach (var ev in events)
        {
            var t = GetLong(ev, "t");
            var age = GetLong(ev, "inputAgeMs");

            var mark = marks.FirstOrDefault(m => t >= GetLong(m, "t0") - 50 && t <= GetLong(m, "t1"));
            string owner;
            if (mark != null)
            {
                owner = "wbcu";
                wbcuHits.Add(new Dictionary<string, object?>
                {
                    ["command"] = GetString(mark, "command"),
                    ["app"] = GetString(ev, "name"),
                    ["title"] = GetString(ev, "title"),
                    ["atMs"] = t - GetLong(mark, "t0"),
                });
            }
            else if (age >= 0 && age < 400)
            {
                owner = "user";
            }
            else if (age >= 400)
            {
                owner = "external";
            }
            else
            {
                owner = "unknown";
            }

            byOwner[owner]++;
        }

        return new Dictionary<string, object?>
        {
            ["ok"] = true,
            ["events"] = events.Count,
            ["marks"] = marks.Count,
            ["byOwner"] = byOwner,
            ["wbcuActivations"] = wbcuHits.Take(50).ToList(),
            ["daemonRunning"] = DaemonPid() != null,
            ["note"] = "wbcu 归因 = 前台切换发生在某条 wbcu 命令的 [t0-50ms, t1] 窗口内；"
                       + "user = 切换时真实输入年龄 <400ms；external = 其余（系统弹窗、其它软件等）",
        };
    }

    private static List<Dictionary<string, object?>> ReadNdjson(string path, int limit)
    {
        var list = new List<Dictionary<string, object?>>();
        if (!File.Exists(path)) return list;

        foreach (var line in File.ReadLines(path))
        {
            if (string.IsNullOrWhiteSpace(line)) continue;
            try
            {
                var doc = JsonDocument.Parse(line);
                var dict = new Dictionary<string, object?>();
                foreach (var p in doc.RootElement.EnumerateObject())
                {
                    dict[p.Name] = p.Value.ValueKind switch
                    {
                        JsonValueKind.Number => p.Value.TryGetInt64(out var l) ? l : p.Value.GetDouble(),
                        JsonValueKind.Null => null,
                        JsonValueKind.True => true,
                        JsonValueKind.False => false,
                        _ => p.Value.ToString(),
                    };
                }
                list.Add(dict);
            }
            catch { }
        }

        return list.Count > limit ? list.GetRange(list.Count - limit, limit) : list;
    }

    private static long GetLong(Dictionary<string, object?> d, string key)
    {
        if (!d.TryGetValue(key, out var v) || v == null) return 0;
        return v switch
        {
            long l => l,
            double db => (long)db,
            int i => i,
            string s when long.TryParse(s, out var p) => p,
            _ => 0,
        };
    }

    private static string GetString(Dictionary<string, object?> d, string key) =>
        d.TryGetValue(key, out var v) ? v?.ToString() ?? "" : "";
}
