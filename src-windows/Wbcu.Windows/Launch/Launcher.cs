using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32;
using Wbcu.Windows.Win32;

namespace Wbcu.Windows.Launch;

/// <summary>
/// 后台启动应用。
///
/// 关键点：用 CreateProcessW + STARTF_USESHOWWINDOW(SW_SHOWNOACTIVATE)，
/// 而不是 Process.Start / ShellExecute —— 后者会走 Shell 的激活逻辑，
/// 新窗口大概率直接把用户前台顶掉。
///
/// UWP/MSIX 应用没有可执行路径，只能走 IApplicationActivationManager.ActivateApplication，
/// 而**这个 API 一定会把窗口激活到前台**（系统行为，无法绕过）。
/// 所以对 MSIX 应用，我们如实报告 "activatedToForeground=true"，不假装后台。
/// </summary>
/// <summary>一次启动的结果。ActivatedToForeground 为 true 时如实说明「这次把用户前台顶掉了」。</summary>
public sealed class LaunchResult
{
    public bool Ok { get; set; }
    public int Pid { get; set; }
    public bool ActivatedToForeground { get; set; }
    public string Detail { get; set; } = "";
    public string Executable { get; set; } = "";
}

public static class Launcher
{
    public static LaunchResult Launch(string token, bool foreground)
    {
        var exe = ResolveExecutable(token);
        if (exe == null)
        {
            return new LaunchResult { Ok = false, Detail = $"找不到可执行文件：{token}" };
        }
        return LaunchExe(exe, foreground);
    }

    public static LaunchResult LaunchExe(string exePath, bool foreground)
    {
        var si = new Native.STARTUPINFO
        {
            cb = Marshal.SizeOf<Native.STARTUPINFO>(),
            dwFlags = (int)Native.STARTF_USESHOWWINDOW,
            wShowWindow = (short)(foreground ? Native.SW_SHOWNORMAL : Native.SW_SHOWNOACTIVATE),
        };

        var cmd = "\"" + exePath + "\"";
        var ok = Native.CreateProcessW(exePath, cmd, IntPtr.Zero, IntPtr.Zero, false,
                                       Native.CREATE_NO_WINDOW, IntPtr.Zero,
                                       Path.GetDirectoryName(exePath), ref si, out var pi);

        if (!ok)
        {
            var err = Marshal.GetLastWin32Error();
            return new LaunchResult
            {
                Ok = false,
                Executable = exePath,
                Detail = $"CreateProcess 失败 (Win32 {err})",
            };
        }

        Native.CloseHandle(pi.hThread);
        Native.CloseHandle(pi.hProcess);

        return new LaunchResult
        {
            Ok = true,
            Pid = pi.dwProcessId,
            Executable = exePath,
            ActivatedToForeground = foreground,
            Detail = foreground ? "前台启动" : "后台启动（SW_SHOWNOACTIVATE）",
        };
    }

    /// <summary>
    /// 解析可执行文件。顺序：绝对路径 → 系统目录 → App Paths 注册表 → PATH 扫描。
    /// 不猜、不模糊匹配：找不到就返回 null，让上层报 app_not_found。
    /// </summary>
    public static string? ResolveExecutable(string token)
    {
        if (string.IsNullOrWhiteSpace(token)) return null;
        var t = token.Trim().Trim('"');

        if (File.Exists(t)) return Path.GetFullPath(t);

        var candidates = new List<string>();
        if (!t.EndsWith(".exe", StringComparison.OrdinalIgnoreCase)) candidates.Add(t + ".exe");
        candidates.Insert(0, t);

        foreach (var name in candidates)
        {
            var sys = Path.Combine(Environment.SystemDirectory, name);
            if (File.Exists(sys)) return sys;

            var sysWow = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.SystemX86), name);
            if (File.Exists(sysWow)) return sysWow;

            foreach (var dir in (Environment.GetEnvironmentVariable("PATH") ?? "").Split(';'))
            {
                if (string.IsNullOrWhiteSpace(dir)) continue;
                try
                {
                    var p = Path.Combine(dir.Trim(), name);
                    if (File.Exists(p)) return p;
                }
                catch { }
            }

            var fromRegistry = FromAppPaths(name);
            if (fromRegistry != null) return fromRegistry;
        }

        return null;
    }

    private static string? FromAppPaths(string exeName)
    {
        try
        {
            foreach (var root in new[] { Registry.LocalMachine, Registry.CurrentUser })
            {
                using var key = root.OpenSubKey(
                    @"SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\" + exeName);
                if (key?.GetValue(null) is string path && File.Exists(path)) return path;
            }
        }
        catch { }
        return null;
    }

    // ---------------- MSIX / UWP ----------------

    [ComImport, Guid("2e941141-7f97-4756-ba1d-9decde894a3d"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IApplicationActivationManager
    {
        int ActivateApplication(string appUserModelId, string arguments, uint options, out uint processId);
        int ActivateForFile(string appUserModelId, IntPtr itemArray, string verb, out uint processId);
        int ActivateForProtocol(string appUserModelId, IntPtr itemArray, out uint processId);
    }

    private static readonly Guid ClsidApplicationActivationManager = new("45BA127D-10A8-46EA-8AB7-56EA9078943C");

    public static LaunchResult ActivateAumid(string aumid, string? arguments = null)
    {
        try
        {
            var type = Type.GetTypeFromCLSID(ClsidApplicationActivationManager);
            if (type == null)
            {
                return new LaunchResult { Ok = false, Detail = "系统未注册 ApplicationActivationManager" };
            }

            var mgr = (IApplicationActivationManager)Activator.CreateInstance(type)!;
            var hr = mgr.ActivateApplication(aumid, arguments ?? "", 0, out var pid);
            if (hr < 0)
            {
                return new LaunchResult { Ok = false, Detail = $"ActivateApplication 失败 (HRESULT 0x{hr:X8})" };
            }

            return new LaunchResult
            {
                Ok = true,
                Pid = (int)pid,
                ActivatedToForeground = true,
                Detail = "MSIX 激活：系统会把该应用带到前台（这是 ActivateApplication 的固有行为，无法后台化）",
            };
        }
        catch (Exception ex)
        {
            return new LaunchResult { Ok = false, Detail = "MSIX 激活异常：" + ex.Message };
        }
    }

    /// <summary>等待目标进程出现一个可用窗口（用于 launch 之后立刻 attach）。</summary>
    public static Discovery.WindowInfo? WaitForWindow(int pid, int timeoutMs = 6000)
    {
        var sw = Stopwatch.StartNew();
        while (sw.ElapsedMilliseconds < timeoutMs)
        {
            var wins = Discovery.WindowEnumerator.TopLevel(includeInvisible: true)
                .Where(w => w.Pid == pid)
                .ToList();
            var main = Discovery.AppDiscovery.PickMain(wins);
            if (main != null) return main;
            Thread.Sleep(80);
        }
        return null;
    }
}
