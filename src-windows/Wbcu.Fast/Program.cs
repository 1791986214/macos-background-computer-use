using System.Diagnostics;
using System.IO.Pipes;
using System.Text;
using System.Text.Json;

namespace Wbcu.Fast;

/// <summary>
/// 热路径客户端：只做「解析参数 → 连 Worker → 发一条 JSON → 打印结果」。
///
/// 刻意不引用任何 COM / WinRT / UIA 程序集 —— 那正是 wbcu 冷启动 750–1180ms 的来源。
///
/// 用法：
///   wbcuf capture --id s2611xxxx --out shot.png [--json]
///   wbcuf capture --hwnd 0x1A2B3C --out shot.png
///   wbcuf ping
///   wbcuf status
///
/// 退出码：
///   0  成功
///   2  Worker 不可用（调用方应回退到 wbcu）—— 输出里带 fallbackReason
///   1  其它失败
/// </summary>
public static class Program
{
    private static string PipeName =>
        "wbcu-worker-" + Environment.UserName.Replace(" ", "_");

    public static int Main(string[] argv)
    {
        var t0 = Stopwatch.GetTimestamp();

        if (argv.Length == 0 || argv[0] is "-h" or "--help")
        {
            Console.WriteLine("wbcuf capture --id <session>|--hwnd <0x..> --out <path>");
            Console.WriteLine("wbcuf ping | status");
            return 0;
        }

        var cmd = argv[0];
        var opt = ParseOptions(argv.Skip(1));

        try
        {
            return cmd switch
            {
                "ping" => Send(new { op = "ping" }, opt),
                "status" => Send(new { op = "status" }, opt),
                "capture" => Capture(opt, t0),
                "bench" => Bench(opt),
                _ => Error("unknown_command", $"未知命令：{cmd}"),
            };
        }
        catch (Exception ex)
        {
            return Error("client_error", ex.GetType().Name + ": " + ex.Message);
        }
    }

    /// <summary>
    /// 压力测试：进程内循环连管道，测的是**纯 IPC 往返**（不含进程启动）。
    ///   wbcuf bench --n 1000 --op ping
    ///   wbcuf bench --n 100 --op capture --id s2611xxxx
    /// 输出 P50 / P95 / P99 / 最大 / 失败率。
    /// </summary>
    private static int Bench(Dictionary<string, string> opt)
    {
        var n = int.TryParse(opt.GetValueOrDefault("n", "1000"), out var v) ? v : 1000;
        var opName = opt.GetValueOrDefault("op", "ping") ?? "ping";
        opt.TryGetValue("id", out var sid);
        opt.TryGetValue("hwnd", out var hwnd);

        string? targetHwnd = hwnd;
        if (string.IsNullOrEmpty(targetHwnd) && !string.IsNullOrEmpty(sid))
            targetHwnd = ResolveHwndFromSession(sid!);

        var times = new List<double>(n);
        var fails = 0;
        var swAll = Stopwatch.StartNew();

        for (var i = 0; i < n; i++)
        {
            object payload = opName switch
            {
                "capture" => new { op = "capture", hwnd = targetHwnd },
                "status" => new { op = "status" },
                _ => new { op = "ping" },
            };

            var t = Stopwatch.GetTimestamp();
            var reply = SendRaw(payload, 300, 8000);
            var ms = Elapsed(t);

            if (reply == null) fails++;
            else reply.Dispose();

            times.Add(ms);
        }

        swAll.Stop();
        times.Sort();

        double Pct(double p)
        {
            if (times.Count == 0) return 0;
            var idx = (int)Math.Ceiling(p / 100.0 * times.Count) - 1;
            return times[Math.Clamp(idx, 0, times.Count - 1)];
        }

        var result = new Dictionary<string, object?>
        {
            ["ok"] = fails == 0,
            ["data"] = new Dictionary<string, object?>
            {
                ["op"] = opName,
                ["n"] = n,
                ["fail"] = fails,
                ["failRate"] = Math.Round(fails * 100.0 / Math.Max(1, n), 2) + "%",
                ["p50"] = Math.Round(Pct(50), 2),
                ["p95"] = Math.Round(Pct(95), 2),
                ["p99"] = Math.Round(Pct(99), 2),
                ["max"] = Math.Round(times.Count > 0 ? times[^1] : 0, 2),
                ["min"] = Math.Round(times.Count > 0 ? times[0] : 0, 2),
                ["avg"] = Math.Round(times.Count > 0 ? times.Average() : 0, 2),
                ["wallMs"] = Math.Round(swAll.Elapsed.TotalMilliseconds, 1),
                ["pipe"] = PipeName,
            },
        };

        Console.WriteLine(JsonSerializer.Serialize(result));
        return fails == 0 ? 0 : 1;
    }

    private static int Capture(Dictionary<string, string> opt, long t0)
    {
        opt.TryGetValue("id", out var sid);
        opt.TryGetValue("hwnd", out var hwndArg);

        if (string.IsNullOrEmpty(hwndArg) && !string.IsNullOrEmpty(sid))
        {
            hwndArg = ResolveHwndFromSession(sid!);
            if (string.IsNullOrEmpty(hwndArg))
                return Error("session_not_found", $"会话 {sid} 不存在或已失效");
        }

        if (string.IsNullOrEmpty(hwndArg))
            return Error("bad_args", "需要 --id 或 --hwnd");

        opt.TryGetValue("out", out var outPath);
        if (string.IsNullOrEmpty(outPath))
        {
            var dir = Path.Combine(Path.GetTempPath(), "wbcu");
            Directory.CreateDirectory(dir);
            outPath = Path.Combine(dir, $"shot-{DateTime.Now:HHmmss}-{hwndArg!.Replace("0x", "")}.png");
        }

        var reply = SendRaw(new { op = "capture", hwnd = hwndArg, @out = outPath }, 120);
        if (reply == null)
        {
            return Error("worker_unreachable", "Worker 未运行或管道不可达", exit: 2);
        }

        using (reply)
        {
            var ms = Elapsed(t0);
            Emit(reply.RootElement, ms, opt.ContainsKey("json") || true);
            var ok = reply.RootElement.TryGetProperty("ok", out var okEl) && okEl.GetBoolean();
            return ok ? 0 : 1;
        }
    }

    private static int Send(object payload, Dictionary<string, string> opt)
    {
        var t0 = Stopwatch.GetTimestamp();
        var reply = SendRaw(payload, 120);
        if (reply == null) return Error("worker_unreachable", "Worker 未运行或管道不可达", exit: 2);

        using (reply)
        {
            Emit(reply.RootElement, Elapsed(t0), true);
            return 0;
        }
    }

    private static void Emit(JsonElement root, double clientMs, bool asJson)
    {
        // 在 Worker 返回的 JSON 外层补上客户端侧耗时与传输信息，
        // 让调用方能区分「Worker 内耗时」和「客户端+传输耗时」。
        var doc = new Dictionary<string, object?>();
        foreach (var p in root.EnumerateObject())
        {
            doc[p.Name] = p.Value.ValueKind switch
            {
                JsonValueKind.Object => JsonSerializer.Deserialize<Dictionary<string, object?>>(p.Value.GetRawText()),
                JsonValueKind.Array => JsonSerializer.Deserialize<List<object?>>(p.Value.GetRawText()),
                JsonValueKind.String => p.Value.GetString(),
                JsonValueKind.Number => p.Value.TryGetInt64(out var l) ? l : p.Value.GetDouble(),
                JsonValueKind.True => true,
                JsonValueKind.False => false,
                _ => null,
            };
        }

        doc["transport"] = new Dictionary<string, object?>
        {
            ["client"] = "wbcuf",
            ["clientMs"] = Math.Round(clientMs, 2),
            ["pipe"] = PipeName,
        };

        Console.OutputEncoding = Encoding.UTF8;
        Console.WriteLine(JsonSerializer.Serialize(doc));
    }

    private static int Error(string code, string reason, int exit = 1)
    {
        var doc = new Dictionary<string, object?>
        {
            ["ok"] = false,
            ["errorCode"] = code,
            ["failureReason"] = reason,
            ["fallback"] = exit == 2 ? "use wbcu" : null,
        };
        Console.WriteLine(JsonSerializer.Serialize(doc));
        return exit;
    }

    private static double Elapsed(long t0) =>
        (Stopwatch.GetTimestamp() - t0) * 1000.0 / Stopwatch.Frequency;

    private static JsonDocument? SendRaw(object payload, int timeoutMs, int readTimeoutMs = 5000)
    {
        NamedPipeClientStream? pipe = null;
        try
        {
            pipe = new NamedPipeClientStream(".", PipeName, PipeDirection.InOut, PipeOptions.None);
            pipe.Connect(timeoutMs);

            var writer = new StreamWriter(pipe, new UTF8Encoding(false), 8192, leaveOpen: true) { AutoFlush = true };
            var reader = new StreamReader(pipe, new UTF8Encoding(false), false, 8192, leaveOpen: true);

            writer.WriteLine(JsonSerializer.Serialize(payload));

            // 读带超时：worker 卡死时不能把调用方一起拖住（v0.6.5 的 150 秒挂死就是这里）
            var readTask = Task.Run(() =>
            {
                try { return reader.ReadLine(); }
                catch { return null; }
            });

            if (!readTask.Wait(readTimeoutMs)) return null;

            var line = readTask.Result;
            return string.IsNullOrWhiteSpace(line) ? null : JsonDocument.Parse(line);
        }
        catch
        {
            return null;
        }
        finally
        {
            try { pipe?.Dispose(); } catch { }
        }
    }

    /// <summary>从会话文件里读出目标窗口句柄（与 wbcu 共用同一份 session 存储）。</summary>
    private static string? ResolveHwndFromSession(string sessionId)
    {
        try
        {
            var dir = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "wbcu", "sessions");
            var path = Path.Combine(dir, sessionId + ".json");
            if (!File.Exists(path)) return null;

            using var doc = JsonDocument.Parse(File.ReadAllText(path));
            return doc.RootElement.TryGetProperty("windowHandle", out var h) ? h.GetString() : null;
        }
        catch
        {
            return null;
        }
    }

    private static Dictionary<string, string> ParseOptions(IEnumerable<string> args)
    {
        var map = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        string? key = null;

        foreach (var a in args)
        {
            if (a.StartsWith("--", StringComparison.Ordinal))
            {
                if (key != null) map[key] = "true";
                key = a[2..];
            }
            else if (key != null)
            {
                map[key] = a;
                key = null;
            }
        }
        if (key != null) map[key] = "true";

        return map;
    }
}
