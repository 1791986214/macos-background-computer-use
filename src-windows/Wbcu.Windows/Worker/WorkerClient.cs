using System.Diagnostics;
using System.IO.Pipes;
using System.Text;
using System.Text.Json;

namespace Wbcu.Windows.Worker;

public sealed record WorkerCapture(bool Ok, string Method, int Width, int Height, string? Failure, string[] Warnings);

/// <summary>
/// CLI 侧的 Worker 客户端。
///
/// 行为约定：
///   - 每次操作先尝试连上常驻 Worker（超时很短，连不上就当场回落本地执行）。
///   - 回落是静默的：Worker 没启动、崩了、版本不匹配，都不影响正确性，只影响速度。
///   - 绝不因为 Worker 不可用而阻塞或报错给调用方。
/// </summary>
public static class WorkerClient
{
    /// <summary>按当前用户名隔离管道，避免多用户会话互相串。</summary>
    public static string PipeName =>
        "wbcu-worker-" + Environment.UserName.Replace(" ", "_");

    private static readonly object Gate = new();
    private static long _lastStartAttemptMs;

    /// <summary>Worker 是否活着（用 ping 探测，2 秒缓存由调用方控制）。</summary>
    public static bool IsAlive(int timeoutMs = 40)
    {
        var reply = SendRaw(new { op = "ping" }, timeoutMs);
        return reply != null;
    }

    /// <summary>确保 Worker 在跑。首次调用会拉起后台进程；后续只是探测。</summary>
    public static bool Ensure(int timeoutMs = 40)
    {
        if (IsAlive(timeoutMs)) return true;

        // 避免高并发下同时拉多个 worker
        lock (Gate)
        {
            if (Environment.TickCount64 - _lastStartAttemptMs < 1500) return false;
            _lastStartAttemptMs = Environment.TickCount64;

            try
            {
                var exe = Environment.ProcessPath;
                if (string.IsNullOrEmpty(exe)) return false;

                var psi = new ProcessStartInfo
                {
                    FileName = exe,
                    Arguments = $"__worker --pipe \"{PipeName}\"",
                    UseShellExecute = false,
                    CreateNoWindow = true,
                    WindowStyle = ProcessWindowStyle.Hidden,
                    // 必须重定向：否则 worker 继承调用方 stdout/stderr，
                    // 调用方（PowerShell 管道、GUI 测试、任何 ReadToEnd）会等不到 EOF 而永久挂起。
                    RedirectStandardOutput = true,
                    RedirectStandardError = true,
                    RedirectStandardInput = true,
                };

                var p = Process.Start(psi);
                if (p == null) return false;

                // 给 Worker 一点启动时间（.NET 冷启动 ~800ms），探测超时放宽到 400ms：
                // 首次连接要等 JIT 完成，40ms 的探测窗口会一直判定"不在"，然后白白回落到本地执行。
                var sw = Stopwatch.StartNew();
                while (sw.ElapsedMilliseconds < 3500)
                {
                    if (IsAlive(400)) return true;
                    Thread.Sleep(80);
                }
                return false;
            }
            catch
            {
                return false;
            }
        }
    }

    public static WorkerCapture? Capture(IntPtr hwnd, string? outPath, int timeoutMs = 150)
    {
        var reply = SendRaw(new
        {
            op = "capture",
            hwnd = "0x" + hwnd.ToInt64().ToString("X"),
            @out = outPath,
        }, timeoutMs);

        if (reply is not { } doc) return null;

        try
        {
            var root = doc.RootElement;
            var ok = root.TryGetProperty("ok", out var okEl) && okEl.GetBoolean();
            var method = root.TryGetProperty("method", out var m) ? m.GetString() ?? "worker" : "worker";
            var data = root.TryGetProperty("data", out var d) ? d : default;

            var w = data.ValueKind == JsonValueKind.Object && data.TryGetProperty("width", out var we) ? we.GetInt32() : 0;
            var h = data.ValueKind == JsonValueKind.Object && data.TryGetProperty("height", out var he) ? he.GetInt32() : 0;

            string? failure = root.TryGetProperty("failureReason", out var fr) ? fr.GetString() : null;

            var warnings = new List<string>();
            if (root.TryGetProperty("warnings", out var wa) && wa.ValueKind == JsonValueKind.Array)
            {
                foreach (var item in wa.EnumerateArray())
                {
                    var s = item.GetString();
                    if (!string.IsNullOrEmpty(s)) warnings.Add("[worker] " + s);
                }
            }

            return new WorkerCapture(ok, method, w, h, failure, warnings.ToArray());
        }
        finally
        {
            doc.Dispose();
        }
    }

    public static bool Shutdown(int timeoutMs = 200)
    {
        var reply = SendRaw(new { op = "shutdown" }, timeoutMs);
        return reply != null;
    }

    /// <summary>发一条命令，拿到 JSON 后由调用方 Dispose。连不上返回 null。</summary>
    private static JsonDocument? SendRaw(object op, int timeoutMs)
    {
        try
        {
            using var pipe = new NamedPipeClientStream(".", PipeName, PipeDirection.InOut, PipeOptions.None);
            pipe.Connect(timeoutMs);

            using var writer = new StreamWriter(pipe, new UTF8Encoding(false), 8192, leaveOpen: true) { AutoFlush = true };
            using var reader = new StreamReader(pipe, new UTF8Encoding(false), false, 8192, leaveOpen: true);

            writer.WriteLine(JsonSerializer.Serialize(op));
            var line = reader.ReadLine();
            if (string.IsNullOrWhiteSpace(line)) return null;

            return JsonDocument.Parse(line);
        }
        catch
        {
            return null;
        }
    }
}
