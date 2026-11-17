using System.Diagnostics;
using System.IO.Pipes;
using System.Text;
using Wbcu.Contract;
using Wbcu.Windows.Win32;

namespace Wbcu.Windows.Ghost;

/// <summary>
/// Ghost Cursor 的跨进程协议。
///
/// 为什么是独立进程而不是引擎内的一个窗口：
///   1) 覆盖层要一直活着、独立重绘；跟着 CLI 进程生灭会让它闪烁。
///   2) 它必须随时能被单独杀掉（`ghost stop`），不能连累正在跑的操作。
///   3) 覆盖层绝不能参与目标应用的消息循环，也不能有任何被激活的可能。
///
/// 协议：命名管道 + 每行一个 JSON。请求 op ∈ move/click/hide/stop/status/bind。
/// 坐标一律是**目标窗口帧内的相对坐标**，由覆盖层进程换算成屏幕坐标，
/// 这样目标窗口被移动/缩放时，光标能自己跟上（不需要每次重发坐标）。
/// </summary>
public static class GhostClient
{
    public static string PipeName(string windowHandle) =>
        "wbcu-ghost-" + Paths.SafeFileName(windowHandle);

    public static string PidFile(string pipeName) =>
        Path.Combine(Paths.Root, pipeName + ".pid");

    public sealed class Reply
    {
        public bool Ok { get; set; }
        public string Raw { get; set; } = "";
        public string Error { get; set; } = "";
    }

    public static Reply Send(string pipeName, object op, int timeoutMs = 900)
    {
        try
        {
            using var pipe = new NamedPipeClientStream(".", pipeName, PipeDirection.InOut, PipeOptions.None);
            pipe.Connect(timeoutMs);

            using var writer = new StreamWriter(pipe, new UTF8Encoding(false), 4096, leaveOpen: true) { AutoFlush = true };
            using var reader = new StreamReader(pipe, new UTF8Encoding(false), false, 4096, leaveOpen: true);

            writer.WriteLine(Json.Serialize(op));
            var line = reader.ReadLine() ?? "";
            if (line.Length == 0) return new Reply { Ok = false, Error = "空响应" };

            var doc = System.Text.Json.JsonDocument.Parse(line);
            var ok = doc.RootElement.TryGetProperty("ok", out var okEl) && okEl.GetBoolean();
            return new Reply { Ok = ok, Raw = line };
        }
        catch (Exception ex)
        {
            return new Reply { Ok = false, Error = ex.GetType().Name + ": " + ex.Message };
        }
    }

    public static bool IsAlive(string pipeName)
    {
        var r = Send(pipeName, new { op = "status" }, 400);
        return r.Ok;
    }

    public static int? PidOf(string pipeName)
    {
        var f = PidFile(pipeName);
        if (!File.Exists(f)) return null;
        return int.TryParse(File.ReadAllText(f).Trim(), out var pid) ? pid : null;
    }

    /// <summary>启动覆盖层进程（与本进程同目录的 wbcu.exe ghost __daemon）。</summary>
    public static int? Start(string pipeName, string windowHandle, string sessionId)
    {
        var exe = Environment.ProcessPath;
        if (string.IsNullOrEmpty(exe)) return null;

        var psi = new ProcessStartInfo
        {
            FileName = exe,
            Arguments = $"ghost __daemon --pipe \"{pipeName}\" --hwnd {windowHandle} --session {sessionId}",
            UseShellExecute = false,
            CreateNoWindow = true,
            WindowStyle = ProcessWindowStyle.Hidden,
            // 必须重定向：否则守护进程继承调用方的 stdout/stderr 句柄，
            // 调用方（PowerShell 管道、GUI 测试、任何 ReadToEnd）会等不到 EOF 而永久挂起。
            // 真机回执里「不带 --no-ghost 就卡死」就是这一条。
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            RedirectStandardInput = true,
        };

        return DetachedProcess.Start(psi);
    }

    /// <summary>优雅关闭 → 等 → 强杀 → 复核。绝不"报告已停止但进程还在"。</summary>
    public static (bool Stopped, string Detail) Stop(string pipeName)
    {
        var pid = PidOf(pipeName);

        Send(pipeName, new { op = "stop" }, 600);

        for (var i = 0; i < 15; i++)
        {
            if (pid == null || !ProcessAlive(pid.Value)) break;
            Thread.Sleep(100);
        }

        if (pid != null && ProcessAlive(pid.Value))
        {
            try { Process.GetProcessById(pid.Value).Kill(); } catch { }
            Thread.Sleep(200);
        }

        var stillAlive = pid != null && ProcessAlive(pid.Value);
        try { if (File.Exists(PidFile(pipeName))) File.Delete(PidFile(pipeName)); } catch { }

        return (!stillAlive,
                stillAlive ? $"覆盖层进程 {pid} 仍在运行（强杀失败）" : "覆盖层已退出");
    }

    private static bool ProcessAlive(int pid)
    {
        try
        {
            using var p = Process.GetProcessById(pid);
            return !p.HasExited;
        }
        catch
        {
            return false;
        }
    }

    /// <summary>查询覆盖层当前几何信息（调试用：确认它到底在屏幕哪儿、是否被遮挡）。</summary>
    public static Dictionary<string, object?> Status(string pipeName)
    {
        var r = Send(pipeName, new { op = "status" });
        var dict = new Dictionary<string, object?>
        {
            ["alive"] = r.Ok,
            ["pipe"] = pipeName,
        };
        if (!r.Ok) dict["error"] = r.Error;
        else
        {
            try
            {
                using var doc = System.Text.Json.JsonDocument.Parse(r.Raw);
                foreach (var prop in doc.RootElement.EnumerateObject())
                {
                    dict[prop.Name] = prop.Value.ValueKind switch
                    {
                        System.Text.Json.JsonValueKind.Number => prop.Value.GetDouble(),
                        System.Text.Json.JsonValueKind.True => true,
                        System.Text.Json.JsonValueKind.False => false,
                        System.Text.Json.JsonValueKind.Null => null,
                        _ => prop.Value.ToString(),
                    };
                }
            }
            catch { }
        }
        return dict;
    }
}
