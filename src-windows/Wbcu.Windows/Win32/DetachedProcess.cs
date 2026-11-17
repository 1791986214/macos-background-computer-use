using System.Diagnostics;

namespace Wbcu.Windows.Win32;

/// <summary>
/// 启动「不继承调用方标准流」的后台进程（ghost / trace 守护进程用）。
///
/// 为什么必须这么做：Windows 上子进程默认继承父进程的 stdout 句柄。
/// 守护进程不退出，句柄就一直开着，调用方用管道读取时永远等不到 EOF ——
/// 表现为「命令明明执行完了，PowerShell / GUI 测试却卡死」。
/// 真机回执（2026-11-17，Windows 10 19045）里「不带 --no-ghost 就永久挂起」就是这一条。
///
/// 做法：三重定向 + 后台把输出读空（防止子进程写满管道缓冲后阻塞）+ 关闭 stdin。
/// </summary>
internal static class DetachedProcess
{
    public static int? Start(ProcessStartInfo psi)
    {
        psi.UseShellExecute = false;
        psi.CreateNoWindow = true;
        psi.RedirectStandardOutput = true;
        psi.RedirectStandardError = true;
        psi.RedirectStandardInput = true;

        var p = Process.Start(psi);
        if (p == null) return null;

        var pid = p.Id;

        try { p.StandardInput.Close(); } catch { }

        // 事件挂上就必须读到底，否则管道缓冲填满后子进程会卡在写操作上
        try
        {
            p.OutputDataReceived += static (_, _) => { };
            p.ErrorDataReceived += static (_, _) => { };
            p.BeginOutputReadLine();
            p.BeginErrorReadLine();
        }
        catch
        {
            // 读不了也不让启动失败：最坏情况是守护进程自己阻塞，但它不再影响调用方
        }

        // 刻意不 Dispose / 不 WaitForExit：守护进程是长跑进程，生命周期由它自己决定
        return pid;
    }
}
