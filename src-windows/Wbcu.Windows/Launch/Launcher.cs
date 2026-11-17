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
        try
        {
            if (!File.Exists(exePath))
            {
                return new LaunchResult { Ok = false, Executable = exePath, Detail = $"文件不存在：{exePath}" };
            }
            if (!IsWindowsExecutable(exePath))
            {
                return new LaunchResult
                {
                    Ok = false,
                    Executable = exePath,
                    Detail = $"不是 Windows 可执行文件（没有 MZ 头）：{exePath}。"
                             + "常见原因是 PATH 里先命中了 MSYS/Git 的 shell 脚本同名文件。",
                };
            }

            var si = new Native.STARTUPINFO
            {
                cb = System.Runtime.InteropServices.Marshal.SizeOf<Native.STARTUPINFO>(),
                dwFlags = (int)Native.STARTF_USESHOWWINDOW,
                wShowWindow = (short)(foreground ? Native.SW_SHOWNORMAL : Native.SW_SHOWNOACTIVATE),
            };

            var cmd = "\"" + exePath + "\"";
            var cwd = Path.GetDirectoryName(exePath);
            if (string.IsNullOrEmpty(cwd) || !Directory.Exists(cwd)) cwd = null;

            var ok = Native.CreateProcessW(exePath, cmd, IntPtr.Zero, IntPtr.Zero, false,
                                           Native.CREATE_NO_WINDOW, IntPtr.Zero,
                                           cwd, ref si, out var pi);

            if (!ok)
            {
                var err = System.Runtime.InteropServices.Marshal.GetLastWin32Error();
                return new LaunchResult
                {
                    Ok = false,
                    Executable = exePath,
                    Detail = "CreateProcess 失败 (Win32 " + err + ")"
                             + (err == 193 ? "：目标不是有效的 Win32 应用" : ""),
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
                Detail = foreground
                    ? "前台启动（SW_SHOWNORMAL）"
                    : "后台启动（SW_SHOWNOACTIVATE）：请求了不激活，实际是否被系统带到前台以 frontAppPreserved 为准",
            };
        }
        catch (Exception ex)
        {
            // 绝不把异常变成「进程异常退出 + 退出码 -1」，那对调用方是无法诊断的
            return new LaunchResult
            {
                Ok = false,
                Executable = exePath,
                Detail = "启动异常：" + ex.GetType().Name + ": " + ex.Message,
            };
        }
    }

    /// <summary>PE 校验：Windows 可执行文件必须以 "MZ" 开头。用来挡掉 PATH 里的同名脚本。</summary>
    public static bool IsWindowsExecutable(string path)
    {
        try
        {
            using var fs = File.OpenRead(path);
            var head = new byte[2];
            if (fs.Read(head, 0, 2) != 2) return false;
            return head[0] == (byte)'M' && head[1] == (byte)'Z';
        }
        catch
        {
            return false;
        }
    }

    /// <summary>
    /// 解析可执行文件。顺序刻意如此：
    ///   1) 用户给的路径（存在即用）
    ///   2) System32 / SysWOW64 —— **优先于 PATH**：Windows 上 PATH 经常含 Git/MSYS 的
    ///      usr\bin，里面有同名 shell 脚本（真机回执：notepad 被解析到 Git 的 usr\bin\notepad）
    ///   3) App Paths 注册表（应用自注册的正式入口）
    ///   4) PATH（每个候选都要过 PE 校验）
    /// 不猜、不模糊匹配：都不中返回 null，让上层报 app_not_found。
    /// </summary>
    public static string? ResolveExecutable(string token)
    {
        if (string.IsNullOrWhiteSpace(token)) return null;
        var t = token.Trim().Trim('"');

        if (File.Exists(t) && IsWindowsExecutable(t)) return Path.GetFullPath(t);

        var candidates = new List<string>();
        if (!t.EndsWith(".exe", StringComparison.OrdinalIgnoreCase)) candidates.Add(t + ".exe");
        candidates.Insert(0, t);

        foreach (var name in candidates)
        {
            var sys = Path.Combine(Environment.SystemDirectory, name);
            if (File.Exists(sys) && IsWindowsExecutable(sys)) return sys;

            var sysWow = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.SystemX86), name);
            if (File.Exists(sysWow) && IsWindowsExecutable(sysWow)) return sysWow;

            var appPath = FromAppPaths(name);
            if (appPath != null && IsWindowsExecutable(appPath)) return appPath;

            foreach (var dir in (Environment.GetEnvironmentVariable("PATH") ?? "").Split(';'))
            {
                if (string.IsNullOrWhiteSpace(dir)) continue;
                try
                {
                    var p = Path.Combine(dir.Trim(), name);
                    if (File.Exists(p) && IsWindowsExecutable(p)) return p;
                }
                catch { }
            }
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
