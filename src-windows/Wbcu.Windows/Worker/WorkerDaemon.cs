using System.Diagnostics;
using System.IO.Pipes;
using System.Text;
using System.Text.Json;
using Wbcu.Windows.Capture;

namespace Wbcu.Windows.Worker;

/// <summary>
/// **常驻 Worker**：把 WGC 会话、UIA 上下文和帧缓存从「每条命令一个进程」里搬出来。
///
/// 为什么需要它：v0.6.3 的 WGC 热路径本身已经接近 0 等待，但**每次 wbcu 命令都要重新
/// 启动一个 .NET 进程**（实测 750–1180ms）。更关键的是 <see cref="LiveCaptureRegistry"/>
/// 是进程内静态表 —— 进程一退，持久捕获会话就没了。所谓"持久会话"实际只在单条命令内有效。
///
/// 架构：
///   WorkBuddy → wbcu CLI → Named Pipe → 本 Worker → WGC / UIA / Input
///
/// 设计约束：
///   - Named Pipe 只允许当前用户连接（PipeOptions.CurrentUserOnly），不建服务、不要管理员权限。
///   - 单线程串行处理请求：UIA 与 D3D11 immediate context 都不是线程安全的，
///     并发进来只会互相踩。CLI 侧本来就是一条一条发的，串行不会成为瓶颈。
///   - 命令与响应都是单行 JSON，与 ghost daemon 保持同一套约定。
/// </summary>
public static class WorkerDaemon
{
    private static readonly Stopwatch Uptime = Stopwatch.StartNew();

    public static int Run(string pipeName, CancellationToken ct)
    {
        var pidFile = PidFile(pipeName);
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(pidFile)!);
            File.WriteAllText(pidFile, Environment.ProcessId.ToString());
        }
        catch { }

        // 多个监听实例：一个客户端卡住（连上却不发数据、或半路崩溃）不能堵死其他人。
        // 旧版 maxNumberOfServerInstances=1，是 v0.6.5 挂死的第二个成因。
        var listeners = Math.Clamp(Environment.ProcessorCount, 2, 6);
        Log(pipeName, $"start pid={Environment.ProcessId} listeners={listeners}");

        for (var i = 0; i < listeners; i++)
        {
            var slot = i;
            var t = new Thread(() => ListenLoop(pipeName, ct, listeners))
            {
                IsBackground = true,
                Name = $"wbcu-worker-{slot}",
            };
            t.Start();
        }

        // 主线程只负责等待退出信号
        ct.WaitHandle.WaitOne();

        try { File.Delete(pidFile); } catch { }
        try { LiveCaptureRegistry.DropAll(); } catch { }
        Log(pipeName, "stopped");
        return 0;
    }

    /// <summary>单个监听槽：等连接 → 服务 → 断开后立刻重新等。</summary>
    private static void ListenLoop(string pipeName, CancellationToken ct, int maxInstances)
    {
        while (!ct.IsCancellationRequested)
        {
            NamedPipeServerStream? server = null;
            try
            {
                server = new NamedPipeServerStream(
                    pipeName, PipeDirection.InOut, maxInstances,
                    PipeTransmissionMode.Byte, PipeOptions.CurrentUserOnly);

                server.WaitForConnection();
                ServeConnection(server, pipeName);
            }
            catch (Exception ex)
            {
                if (ct.IsCancellationRequested) break;
                Log(pipeName, "listener: " + ex.GetType().Name + ": " + ex.Message);
                Thread.Sleep(50);
            }
            finally
            {
                try { server?.Dispose(); } catch { }
            }
        }
    }

    /// <summary>处理一条连接上的多条请求。</summary>
    private static void ServeConnection(NamedPipeServerStream server, string pipeName)
    {
        using var reader = new StreamReader(server, new UTF8Encoding(false), false, 8192, leaveOpen: true);
        using var writer = new StreamWriter(server, new UTF8Encoding(false), 8192, leaveOpen: true) { AutoFlush = true };

        string? line;
        while ((line = reader.ReadLine()) != null)
        {
            if (string.IsNullOrWhiteSpace(line)) continue;

            Dictionary<string, object?> reply;
            try
            {
                using var doc = JsonDocument.Parse(line);
                var op = doc.RootElement.TryGetProperty("op", out var o) ? o.GetString() ?? "" : "";

                if (op == "shutdown")
                {
                    writer.WriteLine(JsonSerializer.Serialize(new Dictionary<string, object?> { ["ok"] = true }));
                    Log(pipeName, "shutdown requested");
                    try { LiveCaptureRegistry.DropAll(); } catch { }
                    Environment.Exit(0);
                    return;
                }

                // 引擎执行串行：UIA 与 D3D11 immediate context 都不是线程安全的。
                // 连接层并发（不互相堵），执行层串行（保证正确），这是刻意的分层。
                lock (EngineGate)
                {
                    reply = Dispatch(doc.RootElement);
                }
            }
            catch (Exception ex)
            {
                reply = new Dictionary<string, object?>
                {
                    ["ok"] = false,
                    ["errorCode"] = "worker_dispatch_failed",
                    ["failureReason"] = ex.GetType().Name + ": " + ex.Message,
                };
            }

            try
            {
                writer.WriteLine(JsonSerializer.Serialize(reply));
            }
            catch (Exception ex)
            {
                Log(pipeName, "write: " + ex.GetType().Name + ": " + ex.Message);
                return;
            }
        }
    }

    /// <summary>引擎串行闸门：保证同一时刻只有一个请求在跑 WGC / UIA。</summary>
    private static readonly object EngineGate = new();

    private static void Log(string pipeName, string msg)
    {
        try
        {
            var path = PidFile(pipeName).Replace(".pid", ".log");
            File.AppendAllText(path, $"{DateTime.Now:HH:mm:ss.fff} {msg}{Environment.NewLine}");
        }
        catch { }
    }

    private static Dictionary<string, object?> Dispatch(JsonElement req)
    {
        var op = req.TryGetProperty("op", out var o) ? o.GetString() ?? "" : "";

        switch (op)
        {
            case "ping":
                return Ok(new()
                {
                    ["version"] = typeof(WorkerDaemon).Assembly.GetName().Version?.ToString() ?? "0",
                    ["pid"] = Environment.ProcessId,
                    ["uptimeMs"] = (long)Uptime.Elapsed.TotalMilliseconds,
                    ["sessions"] = LiveCaptureRegistry.ActiveCount,
                });

            case "status":
                return Ok(new()
                {
                    ["pid"] = Environment.ProcessId,
                    ["uptimeMs"] = (long)Uptime.Elapsed.TotalMilliseconds,
                    ["captureSessions"] = LiveCaptureRegistry.ActiveCount,
                    ["workingSetMB"] = Math.Round(Environment.WorkingSet / 1048576.0, 1),
                });

            case "capture":
            {
                var hwnd = ParseHwnd(req.TryGetProperty("hwnd", out var h) ? h.GetString() : null);
                if (hwnd == IntPtr.Zero)
                    return Fail("bad_args", "需要 hwnd");

                var sw = Stopwatch.StartNew();
                var result = WindowCapture.Capture(hwnd);
                sw.Stop();

                var data = new Dictionary<string, object?>
                {
                    ["width"] = result.Width,
                    ["height"] = result.Height,
                    ["method"] = result.Method,
                    ["captureMs"] = Math.Round(sw.Elapsed.TotalMilliseconds, 2),

                    // 帧身份与新鲜度：调用方据此判断「是不是目标窗口、是不是刚拍的」
                    ["targetHwnd"] = result.TargetHwnd,
                    ["targetPid"] = result.TargetPid,
                    ["frameId"] = result.FrameId,
                    ["frameTimestamp"] = result.FrameTimestamp,
                    ["frameAgeMs"] = result.FrameAgeMs,
                    ["captureGeneration"] = result.CaptureGeneration,
                    ["contentSize"] = $"{result.Width}x{result.Height}",
                    ["dpi"] = result.Dpi,
                    ["isStale"] = result.IsStale,
                };

                if (req.TryGetProperty("out", out var outp) && outp.GetString() is { Length: > 0 } path)
                {
                    try
                    {
                        var png = result.ToPng();
                        var dir = Path.GetDirectoryName(path);
                        if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);
                        File.WriteAllBytes(path, png);
                        data["out"] = path;
                        data["bytes"] = png.Length;
                    }
                    catch (Exception ex)
                    {
                        data["writeError"] = ex.GetType().Name + ": " + ex.Message;
                    }
                }

                var reply = new Dictionary<string, object?>
                {
                    ["ok"] = result.Ok,
                    ["method"] = result.Method,
                    ["data"] = data,
                };
                if (result.Warnings.Count > 0) reply["warnings"] = result.Warnings.ToArray();
                if (!result.Ok) reply["failureReason"] = result.Failure;
                return reply;
            }

            case "drop":
            {
                var hwnd = ParseHwnd(req.TryGetProperty("hwnd", out var h2) ? h2.GetString() : null);
                if (hwnd != IntPtr.Zero) LiveCaptureRegistry.Drop(hwnd);
                return Ok(new() { ["dropped"] = hwnd != IntPtr.Zero });
            }

            case "shutdown":
                return new Dictionary<string, object?> { ["ok"] = true, ["_shutdown"] = true };

            default:
                return Fail("bad_op", $"未知 op：{op}");
        }
    }

    private static IntPtr ParseHwnd(string? s)
    {
        if (string.IsNullOrWhiteSpace(s)) return IntPtr.Zero;
        s = s.Trim();
        if (s.StartsWith("0x", StringComparison.OrdinalIgnoreCase))
        {
            return long.TryParse(s[2..], System.Globalization.NumberStyles.HexNumber, null, out var v)
                ? new IntPtr(v) : IntPtr.Zero;
        }
        return long.TryParse(s, out var n) ? new IntPtr(n) : IntPtr.Zero;
    }

    private static Dictionary<string, object?> Ok(Dictionary<string, object?> data) =>
        new() { ["ok"] = true, ["data"] = data };

    private static Dictionary<string, object?> Fail(string code, string reason) =>
        new() { ["ok"] = false, ["errorCode"] = code, ["failureReason"] = reason };

    public static string PidFile(string pipeName)
    {
        var dir = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "wbcu", "worker");
        return Path.Combine(dir, pipeName + ".pid");
    }
}
