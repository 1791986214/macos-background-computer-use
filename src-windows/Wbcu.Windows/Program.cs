using Wbcu.Windows.Cli;
using Wbcu.Windows.Trace;

namespace Wbcu.Windows;

internal static class Program
{
    private static int Main(string[] argv)
    {
        if (argv.Length == 0 || argv[0] is "-h" or "--help" or "help")
        {
            Usage();
            return ExitCodes.Ok;
        }

        var cmd = argv[0];
        var ctx = new Ctx(Args.Parse(argv.Skip(1).ToList()));

        // 后台守护进程不记命令标记（否则追踪器会把它自己算成「抢前台的人」）
        var isDaemon = argv.Length > 1 && argv[1] == "__daemon";
        if (!isDaemon && cmd != "trace" && cmd != "version" && cmd != "selftest")
        {
            Trace.ActivationTrace.MarkStart(cmd + (argv.Length > 1 ? " " + argv[1] : ""));
        }

        try
        {
            return cmd switch
            {
                "version" => Commands.Commands.Version(ctx),
                "contract" => Commands.Commands.Contract(ctx),
                "capabilities" => Commands.Commands.CapabilitiesCmd(ctx),
                "doctor" => Commands.Commands.DoctorCmd(ctx),
                "selftest" => Commands.Commands.SelfTestCmd(ctx),
                "apps" => Commands.Commands.Apps(ctx),
                "windows" => Commands.Commands.WindowsCmd(ctx),
                "launch" => Commands.Commands.LaunchCmd(ctx),
                "attach" => Commands.Commands.Attach(ctx),
                "session" => Commands.Commands.SessionCmd(ctx),
                "capture" or "shot" => Commands.Commands.CaptureCmd(ctx),
                "inspect" or "ax-tree" => Commands.Commands.InspectCmd(ctx),
                "click" => Commands.Commands.ClickCmd(ctx),
                "type" => Commands.Commands.TypeCmd(ctx),
                "key" => Commands.Commands.KeyCmd(ctx),
                "scroll" => Commands.Commands.ScrollCmd(ctx),
                "verify" => Commands.Commands.VerifyCmd(ctx),
                "cursor" => Commands.Commands.CursorCmd(ctx),
                "ghost" => Commands.Commands.GhostCmd(ctx),
                "trace" => Commands.Commands.TraceCmd(ctx),
                "experience" => Commands.Commands.ExperienceCmd(ctx),
                "perf" => Commands.Commands.PerfCmd(ctx),
                _ => Unknown(cmd, ctx),
            };
        }
        catch (CliError e)
        {
            return ctx.Fail(e);
        }
        catch (Exception ex)
        {
            return ctx.Fail(new CliError(Contract.ErrorCodes.Internal,
                ex.GetType().Name + ": " + ex.Message, ExitCodes.Internal));
        }
        finally
        {
            if (!isDaemon) Trace.ActivationTrace.MarkEnd();
        }
    }

    private static int Unknown(string cmd, Ctx ctx)
    {
        ctx.Warn($"未知命令：{cmd}（wbcu --help 查看用法）");
        return ExitCodes.BadArgs;
    }

    private static void Usage()
    {
        Console.Out.WriteLine($"""
        wbcu {Diagnostics.Capabilities.Version} — WorkBuddy Third Hand / Windows 引擎

        会话（推荐入口：一次解析，全程复用）
          wbcu attach --app calc [--no-ghost] [--new]
          wbcu session list | state --id SID | end --id SID [--all]
          wbcu capture --id SID [--out f.png] [--printwindow]
          wbcu inspect --id SID [--max 200] [--depth 12]

        输入（默认后台执行：不动真实鼠标、不抢前台）
          wbcu click --id SID --name "7"            # UIA 语义优先，没有 Pattern 才投递消息
          wbcu click --id SID --automationid num7Button
          wbcu click --id SID --x 120 --y 340
          wbcu click --id SID --name "=" --expect "15" --state automationid:CalculatorResults
          wbcu type  --id SID --text "hello" [--automationid ...]
          wbcu key   --id SID --combo ctrl+a
          wbcu scroll --id SID --dy -3
          wbcu verify --id SID [--expect 15] [--state automationid:...]

        虚拟光标（纯显示，不代表点击成功）
          wbcu cursor --id SID --x 40 --y 40
          wbcu ghost start|move|click|hide|stop|status [--id SID]

        发现与诊断
          wbcu apps [--json]
          wbcu windows [--app X] [--json]
          wbcu launch --app calc [--foreground] | --aumid "pkg!App"
          wbcu capabilities [--json]    能力矩阵（未实机验证的会如实标 not_tested）
          wbcu contract [--json]        跨平台契约（与 macOS 同一份）
          wbcu doctor [--json]          环境体检
          wbcu selftest [--json]        纯逻辑自检（不需要交互桌面）
          wbcu perf stats|reset         实测延迟 P50/P95
          wbcu experience list|show|clear
          wbcu trace start|stop|report  前台激活归因

        退出码
          0 成功   2 参数错误   3 目标不存在   4 UIA 不可用
          5 未投递 6 验证失败   7 平台不支持   1 内部错误

        注意：ok=true 表示「操作目标达成」，不是「API 调用返回成功」。
              --allow-global 会调用 SendInput 移动真实鼠标，仅在明确授权时使用。
        """);
    }
}
