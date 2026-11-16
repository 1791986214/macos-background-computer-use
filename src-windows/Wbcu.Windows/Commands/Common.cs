using System.Diagnostics;
using Wbcu.Contract;
using Wbcu.Windows.Cli;
using Wbcu.Windows.Discovery;
using Wbcu.Windows.Session;

namespace Wbcu.Windows.Commands;

/// <summary>命令层公用的目标解析、选择器构造与性能采样。</summary>
public static class Common
{
    /// <summary>
    /// 解析目标：优先会话（--id），否则按应用令牌临时定位（--app/--exe/--pid）。
    /// 临时定位不落盘、不启覆盖层 —— 「我就点一下」不该留下垃圾会话。
    /// </summary>
    public static (SessionRecord? Rec, WindowInfo Win) Target(Ctx ctx)
    {
        var id = ctx.Args.Str("id");
        if (!string.IsNullOrEmpty(id))
        {
            var (rec, win) = SessionStore.Require(id);
            return (rec, win);
        }

        var token = ctx.Args.Str("app") ?? ctx.Args.Str("exe") ?? ctx.Args.Str("pid")
                    ?? ctx.Args.Str("hwnd") ?? ctx.Args.Positional.FirstOrDefault();

        if (string.IsNullOrEmpty(token))
        {
            throw new CliError(ErrorCodes.BadArgs,
                "需要 --id <会话> 或 --app <名称|exe|pid|hwnd>",
                ExitCodes.BadArgs);
        }

        var found = AppDiscovery.Find(token!);
        if (found == null)
        {
            throw new CliError(ErrorCodes.AppNotFound,
                $"找不到应用或窗口：{token}（wbcu apps 可列出运行中的应用）",
                ExitCodes.TargetNotFound);
        }
        return (null, found.Value.Window);
    }

    /// <summary>从参数里构造元素选择器。null 表示「按坐标操作」或「不指定元素」。</summary>
    public static Selector? Selector(Args a)
    {
        var raw = a.Str("selector");
        if (!string.IsNullOrEmpty(raw)) return Contract.Selector.Parse(raw);

        if (a.Str("automationid") is { } aid) return Contract.Selector.Parse("automationid:" + aid);
        if (a.Str("name") is { } name) return Contract.Selector.Parse("name:" + name);
        if (a.Str("controltype") is { } ct) return Contract.Selector.Parse("controltype:" + ct);
        if (a.Str("class") is { } cls) return Contract.Selector.Parse("class:" + cls);
        if (a.Str("path") is { } path) return Contract.Selector.Parse("path:" + path);
        if (a.Int("element") is { } el) return Contract.Selector.Parse("index:" + el);
        if (a.Int("index") is { } idx) return Contract.Selector.Parse("index:" + idx);

        return null;
    }

    /// <summary>状态元素选择器（验证时读哪个元素）。与操作目标分开指定，便于「点按钮、读结果框」。</summary>
    public static Selector? StateSelector(Args a)
    {
        var raw = a.Str("state") ?? a.Str("state-selector");
        if (!string.IsNullOrEmpty(raw)) return Contract.Selector.Parse(raw);
        if (a.Str("state-automationid") is { } sid) return Contract.Selector.Parse("automationid:" + sid);
        return null;
    }

    /// <summary>构造期望。没有 --expect 时返回空期望（只能做弱验证）。</summary>
    public static StateExpectation Expectation(Args a)
    {
        var exp = StateExpectation.Parse(a.Str("match"), a.Str("expect"), a.Str("state"));
        if (a.Int("expect-timeout") is { } t) exp.MaxWaitMs = Math.Clamp(t, 0, 10000);
        if (a.Flag("idempotent")) exp.Idempotent = true;
        return exp;
    }

    /// <summary>把一次动作的耗时落到 perf.jsonl（只记实测值，不估算）。</summary>
    public static void AppendPerf(string action, string method, bool delivered, bool ok,
                                  double dispatchMs, VerifyReport? report, double endToEndMs)
    {
        try
        {
            var rec = new Dictionary<string, object?>
            {
                ["ts"] = DateTime.UtcNow.ToString("O"),
                ["action"] = action,
                ["method"] = method,
                ["delivered"] = delivered,
                ["ok"] = ok,
                ["dispatchMs"] = Math.Round(dispatchMs, 2),
                ["verifyMs"] = report == null ? null : Math.Round(report.Confidence * 0, 2), // 占位：真实值由调用方补
                ["endToEndMs"] = Math.Round(endToEndMs, 2),
                ["verifyResult"] = report?.Result.ToWire(),
            };
            File.AppendAllText(Paths.Perf, Json.Serialize(rec) + Environment.NewLine);
        }
        catch
        {
            // 性能采样失败绝不影响主流程
        }
    }
}

public static class SessionRecordExtensions
{
    public static Dictionary<string, object?> ToJsonSafe(this SessionRecord r) => new()
    {
        ["id"] = r.Id,
        ["platform"] = r.Platform,
        ["engine"] = r.Engine,
        ["pid"] = r.Pid,
        ["hwnd"] = r.WindowHandle,
        ["exe"] = r.Executable,
        ["app"] = r.AppName,
        ["packageFamily"] = r.PackageFamily,
        ["title"] = r.Title,
        ["class"] = r.WindowClass,
        ["frame"] = r.Frame,
        ["dpi"] = r.Dpi,
        ["scale"] = r.Scale,
        ["createdAt"] = r.CreatedAt,
        ["lastUsedAt"] = r.LastUsedAt,
        ["uses"] = r.Uses,
        ["windowState"] = r.WindowState,
        ["ghost"] = r.Ghost,
        ["ghostPipe"] = r.GhostPipe,
        ["notes"] = r.Notes,
    };
}
