using System.Diagnostics;
using Wbcu.Contract;
using Wbcu.Windows.Capture;
using Wbcu.Windows.Cli;
using Wbcu.Windows.Diagnostics;
using Wbcu.Windows.Discovery;
using Wbcu.Windows.Experience;
using Wbcu.Windows.Ghost;
using Wbcu.Windows.Input;
using Wbcu.Windows.Launch;
using Wbcu.Windows.Session;
using Wbcu.Windows.Trace;
using Wbcu.Windows.Uia;
using Wbcu.Windows.Verify;
using Wbcu.Windows.Win32;

namespace Wbcu.Windows.Commands;

/// <summary>
/// 命令实现。每个命令都遵循同一套骨架：
///   解析参数 → 定位目标 → 执行 → **验证** → 如实上报（含未测量项）
///
/// 反模式清单（本文件刻意避免）：
///   - 不因为「API 返回成功」就报 ok
///   - 不在失败时编造一个看起来合理的成功
///   - 不把未测量的字段填成 true
///   - 不为了成功率偷偷激活前台窗口
/// </summary>
public static class Commands
{
    // ---------------- 诊断 ----------------

    public static int Version(Ctx ctx)
    {
        ctx.Text(Capabilities.Version);
        return ExitCodes.Ok;
    }

    public static int Contract(Ctx ctx)
    {
        ctx.EmitObject(ContractSchema.Build(Platforms.Windows, Engines.WindowsUia, Capabilities.Version));
        return ExitCodes.Ok;
    }

    public static int CapabilitiesCmd(Ctx ctx)
    {
        ctx.EmitObject(Capabilities.Build());
        return ExitCodes.Ok;
    }

    public static int DoctorCmd(Ctx ctx)
    {
        var rows = Doctor.Run();
        if (ctx.Json)
        {
            var obj = new Dictionary<string, object?>
            {
                ["ok"] = rows.All(r => r.Status != "fail"),
                ["version"] = Capabilities.Version,
                ["platform"] = Platforms.Windows,
                ["checks"] = rows.Select(r => new { name = r.Name, status = r.Status, detail = r.Detail }).ToList(),
            };
            ctx.EmitObject(obj);
        }
        else
        {
            foreach (var (name, status, detail) in rows)
            {
                ctx.Text($"{status,-5} {name,-20} {detail}");
            }
        }
        return rows.All(r => r.Status != "fail") ? ExitCodes.Ok : ExitCodes.Internal;
    }

    public static int SelfTestCmd(Ctx ctx)
    {
        var (ok, checks) = SelfTest.Run();
        if (ctx.Json)
        {
            ctx.EmitObject(new Dictionary<string, object?>
            {
                ["ok"] = ok,
                ["version"] = Capabilities.Version,
                ["passed"] = checks.Count(c => c.Ok),
                ["failed"] = checks.Count(c => !c.Ok),
                ["checks"] = checks.Select(c => new { name = c.Name, ok = c.Ok, detail = c.Detail }).ToList(),
            });
        }
        else
        {
            foreach (var c in checks) ctx.Text($"{(c.Ok ? "PASS" : "FAIL")} {c.Name,-24} {c.Detail}");
            ctx.Text($"{(ok ? "全部通过" : "存在失败项")}：{checks.Count(c => c.Ok)}/{checks.Count}");
        }
        return ok ? ExitCodes.Ok : ExitCodes.Internal;
    }

    // ---------------- 发现 ----------------

    public static int Apps(Ctx ctx)
    {
        var apps = AppDiscovery.List();
        if (ctx.Json)
        {
            ctx.EmitObject(new { ok = true, count = apps.Count, apps = apps.Select(a => a.ToJson()).ToList() });
        }
        else
        {
            foreach (var a in apps)
            {
                var mark = a.Foreground ? "*" : " ";
                ctx.Text($"{mark} pid={a.Pid,-7} {a.Name,-24} win={a.WindowCount} {(a.PackageFamily.Length > 0 ? "[msix] " : "")}{a.Exe}");
            }
        }
        return ExitCodes.Ok;
    }

    public static int WindowsCmd(Ctx ctx)
    {
        var token = ctx.Args.Str("app") ?? ctx.Args.Str("pid");
        List<WindowInfo> wins;

        if (!string.IsNullOrEmpty(token))
        {
            var found = AppDiscovery.Find(token!);
            if (found == null)
            {
                return ctx.Fail(new CliError(ErrorCodes.AppNotFound, $"找不到应用：{token}", ExitCodes.TargetNotFound));
            }
            wins = WindowEnumerator.TopLevel(includeInvisible: true)
                .Where(w => w.Pid == found.Value.Window.Pid).ToList();
        }
        else
        {
            wins = WindowEnumerator.TopLevel(includeInvisible: ctx.Args.Flag("all"));
        }

        if (ctx.Json)
        {
            ctx.EmitObject(new { ok = true, count = wins.Count, windows = wins.Select(w => w.ToJson()).ToList() });
        }
        else
        {
            foreach (var w in wins) ctx.Text(w.ToString());
        }
        return ExitCodes.Ok;
    }

    public static int LaunchCmd(Ctx ctx)
    {
        var aumid = ctx.Args.Str("aumid");
        var token = ctx.Args.Str("app") ?? ctx.Args.Str("exe") ?? ctx.Args.Positional.FirstOrDefault();
        var foreground = ctx.Args.Flag("foreground");

        var env = ResultEnvelope.Success(Actions.Launch);
        var sw = Stopwatch.StartNew();

        LaunchResult result;
        if (!string.IsNullOrEmpty(aumid))
        {
            if (!foreground)
            {
                env.Warn("MSIX 应用只能用 ActivateApplication 启动，系统会把它带到前台（无法后台化）");
            }
            result = Launcher.ActivateAumid(aumid!, ctx.Args.Str("args"));
        }
        else
        {
            if (string.IsNullOrEmpty(token))
            {
                return ctx.Fail(new CliError(ErrorCodes.BadArgs, "需要 --app / --exe / --aumid 之一"));
            }
            result = Launcher.Launch(token!, foreground);
        }

        env.Ok = result.Ok;
        env.Method = string.IsNullOrEmpty(aumid) ? "create_process" : "activate_application";
        env.ElapsedMs = sw.Elapsed.TotalMilliseconds;
        env.With("pid", result.Pid).With("exe", result.Executable)
           .With("activatedToForeground", result.ActivatedToForeground)
           .With("detail", result.Detail);

        if (!result.Ok)
        {
            env.ErrorCode = ErrorCodes.AppNotFound;
            env.FailureReason = result.Detail;
            ctx.Emit(env);
            return ExitCodes.TargetNotFound;
        }

        // 顺手等窗口出现，省掉调用方一次 attach 的等待（拿不到也不算失败）
        var win = Launcher.WaitForWindow(result.Pid, timeoutMs: 5000);
        if (win != null)
        {
            env.With("window", win.ToJson());
        }

        ctx.Emit(env);
        return ExitCodes.Ok;
    }

    // ---------------- 会话 ----------------

    public static int Attach(Ctx ctx)
    {
        var token = ctx.Args.Str("app") ?? ctx.Args.Str("exe") ?? ctx.Args.Str("pid") ?? ctx.Args.Positional.FirstOrDefault();
        if (string.IsNullOrEmpty(token))
        {
            return ctx.Fail(new CliError(ErrorCodes.BadArgs, "需要 --app <名称|exe|pid|aumid>"));
        }

        var sw = Stopwatch.StartNew();
        var found = AppDiscovery.Find(token!);
        if (found == null)
        {
            return ctx.Fail(new CliError(ErrorCodes.AppNotFound,
                $"找不到应用或窗口：{token}（先用 wbcu apps 看看有什么）", ExitCodes.TargetNotFound));
        }

        var (app, win) = found.Value;

        // 默认复用同窗口的活会话，避免每次 attach 都新建（--new 可强制）
        if (!ctx.Args.Flag("new"))
        {
            var existing = SessionStore.List().FirstOrDefault(r =>
                r.Pid == win.Pid && r.WindowHandle == win.HwndHex);
            if (existing != null && WindowEnumerator.TryParseHwnd(existing.WindowHandle, out _))
            {
                var ghostAlive = existing.Ghost && GhostClient.IsAlive(existing.GhostPipe);
                var reuse = ResultEnvelope.Success(Actions.Attach);
                reuse.Method = "reuse";
                reuse.ElapsedMs = sw.Elapsed.TotalMilliseconds;
                reuse.With("session", existing.ToJsonSafe())
                     .With("window", win.ToJson())
                     .With("ghostAlive", ghostAlive);
                ctx.Emit(reuse);
                return ExitCodes.Ok;
            }
        }

        var ghost = !ctx.Args.Flag("no-ghost");
        var rec = SessionStore.Create(win, ghost);

        if (ghost && GhostClient.Start(rec.GhostPipe, win.HwndHex, rec.Id) is int ghostPid)
        {
            Thread.Sleep(220);
            var alive = GhostClient.IsAlive(rec.GhostPipe);
            rec.Notes.Add(alive ? $"ghost 已启动 pid={ghostPid}" : "ghost 启动后无响应（不影响操作，仅无视觉反馈）");
            SessionStore.Save(rec);
        }

        var env = ResultEnvelope.Success(Actions.Attach);
        env.Method = "uia";
        env.ElapsedMs = sw.Elapsed.TotalMilliseconds;
        env.With("session", rec.ToJsonSafe())
           .With("window", win.ToJson())
           .With("app", app.ToJson())
           .With("uiaAvailable", UiaThread.Instance.Available);

        if (!UiaThread.Instance.Available)
        {
            env.Warn("UIA 不可用：" + UiaThread.Instance.InitError);
        }

        ctx.Emit(env);
        return ExitCodes.Ok;
    }

    public static int SessionCmd(Ctx ctx)
    {
        var sub = ctx.Args.Positional.FirstOrDefault() ?? "state";

        switch (sub)
        {
            case "start":
            case "attach":
                return Attach(ctx);

            case "list":
            {
                var list = SessionStore.List();
                if (ctx.Json)
                {
                    ctx.EmitObject(new
                    {
                        ok = true,
                        count = list.Count,
                        sessions = list.Select(r => new
                        {
                            id = r.Id,
                            pid = r.Pid,
                            hwnd = r.WindowHandle,
                            app = r.AppName,
                            title = r.Title,
                            lastUsedAt = r.LastUsedAt,
                            uses = r.Uses,
                            ghost = r.Ghost,
                            alive = WindowEnumerator.TryParseHwnd(r.WindowHandle, out _),
                        }).ToList(),
                    });
                }
                else
                {
                    foreach (var r in list)
                    {
                        var alive = WindowEnumerator.TryParseHwnd(r.WindowHandle, out _) ? "alive" : "stale";
                        ctx.Text($"{r.Id}  {alive,-5} pid={r.Pid,-7} {r.AppName,-20} \"{r.Title}\"");
                    }
                    if (list.Count == 0) ctx.Text("(没有会话，先跑 wbcu attach --app <应用>)");
                }
                return ExitCodes.Ok;
            }

            case "state":
            {
                var id = ctx.Args.Str("id");
                var rec = SessionStore.Load(id);
                if (rec == null)
                {
                    return ctx.Fail(new CliError(ErrorCodes.NoSession, $"会话不存在：{id}", ExitCodes.TargetNotFound));
                }
                var win = WindowEnumerator.TryParseHwnd(rec.WindowHandle, out var h) ? WindowEnumerator.Get(h) : null;
                if (ctx.Json)
                {
                    ctx.EmitObject(new
                    {
                        ok = win != null,
                        session = rec.ToJsonSafe(),
                        window = win?.ToJson(),
                        ghostAlive = rec.Ghost && GhostClient.IsAlive(rec.GhostPipe),
                    });
                }
                else
                {
                    ctx.Text($"session {rec.Id} pid={rec.Pid} {rec.AppName}");
                    ctx.Text($"  窗口: {rec.WindowHandle} \"{rec.Title}\" {rec.WindowState}");
                    ctx.Text($"  几何: {string.Join(",", rec.Frame)} dpi={rec.Dpi} scale={rec.Scale}");
                    ctx.Text($"  使用: {rec.Uses} 次，最近 {rec.LastUsedAt}");
                    ctx.Text($"  存活: {(win != null ? "是" : "否（会话已失效）")}  幽灵光标: {(rec.Ghost ? (GhostClient.IsAlive(rec.GhostPipe) ? "运行中" : "未运行") : "未启用")}");
                }
                return win != null ? ExitCodes.Ok : ExitCodes.TargetNotFound;
            }

            case "end":
            {
                if (ctx.Args.Flag("all"))
                {
                    var n = 0;
                    foreach (var r in SessionStore.List())
                    {
                        if (r.Ghost) GhostClient.Stop(r.GhostPipe);
                        n++;
                    }
                    SessionStore.EndAll();
                    ctx.EmitObject(new { ok = true, ended = n });
                    return ExitCodes.Ok;
                }

                var id = ctx.Args.Str("id");
                if (string.IsNullOrEmpty(id))
                {
                    return ctx.Fail(new CliError(ErrorCodes.BadArgs, "需要 --id 或 --all"));
                }
                var rec = SessionStore.Load(id);
                if (rec == null)
                {
                    return ctx.Fail(new CliError(ErrorCodes.NoSession, $"会话不存在：{id}", ExitCodes.TargetNotFound));
                }
                var ghost = rec.Ghost ? GhostClient.Stop(rec.GhostPipe) : (true, "未启用");
                var ended = SessionStore.End(rec.Id);
                ctx.EmitObject(new { ok = ended, endedSession = rec.Id, ghostStopped = ghost.Item1, ghostDetail = ghost.Item2 });
                return ended ? ExitCodes.Ok : ExitCodes.Internal;
            }

            case "gc":
            {
                var (removed, kept) = SessionStore.Prune(TimeSpan.FromHours(24), ctx.Args.Flag("raw"));
                ctx.EmitObject(new { ok = true, removed, kept });
                return ExitCodes.Ok;
            }

            default:
                return ctx.Fail(new CliError(ErrorCodes.BadArgs,
                    $"未知的 session 子命令：{sub}（可用 start/list/state/end/gc）"));
        }
    }

    // ---------------- 捕获 / 检查 ----------------

    public static int CaptureCmd(Ctx ctx)
    {
        var (rec, win) = Common.Target(ctx);
        var sw = Stopwatch.StartNew();

        var result = WindowCapture.Capture(win.Hwnd, preferGraphicsCapture: !ctx.Args.Flag("printwindow"));
        var env = ResultEnvelope.Success(Actions.Capture);
        env.Method = result.Method;
        env.ElapsedMs = sw.Elapsed.TotalMilliseconds;

        if (!result.Ok)
        {
            env.Ok = false;
            env.ErrorCode = win.Minimized ? ErrorCodes.WindowMinimized : ErrorCodes.CaptureFailed;
            env.FailureReason = result.Failure ?? "捕获失败";
            foreach (var w in result.Warnings) env.Warn(w);
            ctx.Emit(env);
            return ExitCodes.NotDelivered;
        }

        var outPath = ctx.Args.Str("out");
        if (string.IsNullOrEmpty(outPath))
        {
            outPath = Path.Combine(Paths.TempDir, $"shot-{DateTime.Now:HHmmss}-{win.Hwnd.ToInt64():X}.png");
        }
        else if (!Path.IsPathRooted(outPath))
        {
            outPath = Path.GetFullPath(outPath!);
        }

        Directory.CreateDirectory(Path.GetDirectoryName(outPath)!);
        File.WriteAllBytes(outPath, result.ToPng());

        env.With("path", outPath)
           .With("width", result.Width)
           .With("height", result.Height)
           .With("captureMs", Math.Round(result.Ms, 2))
           .With("session", rec?.Id)
           .With("window", win.ToJson());

        foreach (var w in result.Warnings) env.Warn(w);
        ctx.Emit(env);
        return ExitCodes.Ok;
    }

    public static int InspectCmd(Ctx ctx)
    {
        var (rec, win) = Common.Target(ctx);
        var max = Math.Clamp(ctx.Args.Int("max") ?? 200, 1, 5000);
        var depth = Math.Clamp(ctx.Args.Int("depth") ?? 12, 1, 32);

        var snap = UiaResolver.Walk(win.Hwnd, maxDepth: depth, maxNodes: max, includePatterns: true);

        var env = ResultEnvelope.Success(Actions.Inspect);
        env.Method = "uia_tree";
        env.ElapsedMs = snap.BuildMs;
        env.With("session", rec?.Id)
           .With("window", win.ToJson())
           .With("count", snap.Nodes.Count)
           .With("truncated", snap.Truncated)
           .With("fingerprint", snap.Fingerprint)
           .With("elements", snap.Nodes.Select(n => n.ToJson()).ToList());

        if (snap.Truncated) env.Warn($"树被截断在 {snap.Nodes.Count} 个节点（加大 --max 可看更多）");
        ctx.Emit(env);
        return ExitCodes.Ok;
    }

    // ---------------- 输入 ----------------

    public static int ClickCmd(Ctx ctx)
    {
        var (rec, win) = Common.Target(ctx);
        var selector = Common.Selector(ctx.Args);
        var allowGlobal = ctx.Args.Flag("allow-global");
        var doVerify = !ctx.Args.Flag("no-verify");
        var exp = Common.Expectation(ctx.Args);
        var stateSel = Common.StateSelector(ctx.Args);

        var safety = SafetySnapshot.Take();
        var sw = Stopwatch.StartNew();

        Probe? before = null;
        if (doVerify && !string.IsNullOrEmpty(exp.Value))
        {
            before = StateProbe.Take(win.Hwnd, stateSel);
        }

        ActionOutcome outcome;
        int gx, gy;

        if (selector != null && selector.Kind != SelectorKind.Auto)
        {
            outcome = TargetedInput.ClickElement(win.Hwnd, selector, allowGlobal);
            var snap = UiaResolver.Walk(win.Hwnd, maxDepth: 16, maxNodes: 2000, includePatterns: false);
            var node = UiaResolver.Locate(snap, selector);
            gx = node is { Rect.Length: 4 } ? (int)Math.Round(node.Rect[0] + node.Rect[2] / 2) : win.Frame.Left + 20;
            gy = node is { Rect.Length: 4 } ? (int)Math.Round(node.Rect[1] + node.Rect[3] / 2) : win.Frame.Top + 20;
        }
        else
        {
            var x = ctx.Args.Int("x");
            var y = ctx.Args.Int("y");
            if (x == null || y == null)
            {
                return ctx.Fail(new CliError(ErrorCodes.BadArgs,
                    "需要定位方式：--name/--automationid/--path/--index，或 --x --y（配合 --coord-space 指定坐标系）"));
            }

            // 坐标空间。默认 screen 保持向后兼容。
            // 以前只有屏幕坐标，AI 从目标窗口截图里读出的坐标必须自己加窗口原点，
            // 一旦算错就点到屏幕左上角，而命令照样返回 delivered=true —— 极难排查。
            var space = (ctx.Args.Str("coord-space") ?? "screen").Trim().ToLowerInvariant();
            switch (space)
            {
                case "screen":
                    gx = x!.Value;
                    gy = y!.Value;
                    break;
                case "window":
                    gx = win.Frame.Left + x!.Value;
                    gy = win.Frame.Top + y!.Value;
                    break;
                case "client":
                {
                    var pt = new Native.POINT { X = x!.Value, Y = y!.Value };
                    if (!Native.ClientToScreen(win.Hwnd, ref pt))
                    {
                        return ctx.Fail(new CliError(ErrorCodes.Internal, "ClientToScreen 失败"));
                    }
                    gx = pt.X;
                    gy = pt.Y;
                    break;
                }
                default:
                    return ctx.Fail(new CliError(ErrorCodes.BadArgs,
                        $"--coord-space 只接受 window / client / screen，收到：{space}"));
            }

            outcome = TargetedInput.ClickAt(win.Hwnd, gx, gy, allowGlobal);
        }

        var dispatchMs = outcome.DispatchMs;
        GhostFeedback(rec, win, gx, gy);

        // ---- 验证 ----
        VerifyReport report;
        if (doVerify && before != null)
        {
            var (after, changed) = StateProbe.WaitFor(win.Hwnd, stateSel, exp, before);
            report = StateProbe.Evaluate(win.Hwnd, exp, before, after, changed,
                                         outcome.Delivered, outcome.FailureReason,
                                         selector?.Describe() ?? $"({gx},{gy})",
                                         "click via " + outcome.Method);
        }
        else
        {
            report = VerifyLogic.Evaluate(exp,
                new ElementReadout(), new ElementReadout(), null,
                outcome.Delivered, outcome.FailureReason,
                selector?.Describe() ?? $"({gx},{gy})",
                "click via " + outcome.Method);
        }

        var env = ResultEnvelope.Success(Actions.Click);
        env.ElapsedMs = sw.Elapsed.TotalMilliseconds;
        env.Method = outcome.Method;
        env.ApplyVerification(report, outcome.Delivered);

        env.FrontAppPreserved = safety.FrontAppPreserved();
        env.PhysicalCursorPreserved = safety.CursorPreserved();

        env.With("session", rec?.Id)
           .With("window", new { hwnd = win.HwndHex, pid = win.Pid, title = win.Title })
           .With("point", new { x = gx, y = gy })
           .With("target", selector?.Describe() ?? $"{gx},{gy}")
           .With("dispatchMs", Math.Round(dispatchMs, 2))
           .With("safety", safety.ToJson(env.FrontAppPreserved, env.PhysicalCursorPreserved));

        foreach (var n in outcome.Notes) env.Warn(n);
        if (!string.IsNullOrEmpty(outcome.UiaError)) env.With("uiaError", outcome.UiaError);
        if (outcome.Escalated) env.With("escalated", true);

        Common.AppendPerf("click", outcome.Method, outcome.Delivered, env.Ok,
                          dispatchMs, report, env.ElapsedMs);

        ctx.Emit(env);
        return env.Ok ? ExitCodes.Ok
                      : (outcome.Delivered ? ExitCodes.VerifyFailed : ExitCodes.NotDelivered);
    }

    public static int TypeCmd(Ctx ctx)
    {
        var (rec, win) = Common.Target(ctx);
        var text = ctx.Args.Str("text") ?? ctx.Args.Str("value");
        if (text == null)
        {
            return ctx.Fail(new CliError(ErrorCodes.BadArgs, "需要 --text"));
        }

        var selector = Common.Selector(ctx.Args);
        var exp = Common.Expectation(ctx.Args);
        var stateSel = Common.StateSelector(ctx.Args) ?? selector;
        var safety = SafetySnapshot.Take();
        var sw = Stopwatch.StartNew();

        Probe? before = !string.IsNullOrEmpty(exp.Value) ? StateProbe.Take(win.Hwnd, stateSel) : null;
        var outcome = TargetedInput.SetText(win.Hwnd, selector, text!, ctx.Args.Flag("allow-global"));

        VerifyReport report;
        if (before != null)
        {
            var (after, changed) = StateProbe.WaitFor(win.Hwnd, stateSel, exp, before);
            report = StateProbe.Evaluate(win.Hwnd, exp, before, after, changed, outcome.Delivered,
                                         outcome.FailureReason, selector?.Describe() ?? "window",
                                         "type via " + outcome.Method);
        }
        else
        {
            report = VerifyLogic.Evaluate(exp, new ElementReadout(), new ElementReadout(), null,
                                          outcome.Delivered, outcome.FailureReason,
                                          selector?.Describe() ?? "window", "type via " + outcome.Method);
        }

        var env = ResultEnvelope.Success(Actions.Type);
        env.ElapsedMs = sw.Elapsed.TotalMilliseconds;
        env.Method = outcome.Method;
        env.ApplyVerification(report, outcome.Delivered);
        env.FrontAppPreserved = safety.FrontAppPreserved();
        env.PhysicalCursorPreserved = safety.CursorPreserved();
        env.With("chars", text!.Length).With("session", rec?.Id).With("method", outcome.Method);
        foreach (var n in outcome.Notes) env.Warn(n);
        if (!string.IsNullOrEmpty(outcome.UiaError)) env.With("uiaError", outcome.UiaError);

        ctx.Emit(env);
        return env.Ok ? ExitCodes.Ok : (outcome.Delivered ? ExitCodes.VerifyFailed : ExitCodes.NotDelivered);
    }

    public static int KeyCmd(Ctx ctx)
    {
        var (rec, win) = Common.Target(ctx);
        var combo = ctx.Args.Str("combo") ?? ctx.Args.Positional.FirstOrDefault();
        if (string.IsNullOrEmpty(combo))
        {
            return ctx.Fail(new CliError(ErrorCodes.BadArgs, "需要 --combo，例如 ctrl+a"));
        }

        var safety = SafetySnapshot.Take();
        var sw = Stopwatch.StartNew();
        var outcome = TargetedInput.KeyCombo(win.Hwnd, combo!, ctx.Args.Flag("allow-global"));

        var env = ResultEnvelope.Success(Actions.Key);
        env.ElapsedMs = sw.Elapsed.TotalMilliseconds;
        env.Method = outcome.Method;
        env.Delivered = outcome.Delivered;
        env.Ok = outcome.Delivered;
        env.FrontAppPreserved = safety.FrontAppPreserved();
        env.PhysicalCursorPreserved = safety.CursorPreserved();
        env.With("combo", combo).With("session", rec?.Id);
        if (!outcome.Delivered) env.FailureReason = outcome.FailureReason;

        ctx.Emit(env);
        return outcome.Delivered ? ExitCodes.Ok : ExitCodes.NotDelivered;
    }

    public static int ScrollCmd(Ctx ctx)
    {
        var (rec, win) = Common.Target(ctx);
        var dy = ctx.Args.Int("dy") ?? -3;
        var selector = Common.Selector(ctx.Args);
        var x = ctx.Args.Int("x") ?? win.Frame.Left + win.Frame.Width / 2;
        var y = ctx.Args.Int("y") ?? win.Frame.Top + win.Frame.Height / 2;

        var safety = SafetySnapshot.Take();
        var sw = Stopwatch.StartNew();
        var outcome = TargetedInput.Scroll(win.Hwnd, selector, dy, x, y);

        var env = ResultEnvelope.Success(Actions.Scroll);
        env.ElapsedMs = sw.Elapsed.TotalMilliseconds;
        env.Method = outcome.Method;
        env.Delivered = outcome.Delivered;
        env.Ok = outcome.Delivered;
        env.FrontAppPreserved = safety.FrontAppPreserved();
        env.PhysicalCursorPreserved = safety.CursorPreserved();
        env.With("dy", dy).With("session", rec?.Id);
        if (!outcome.Delivered) env.FailureReason = outcome.FailureReason;
        foreach (var n in outcome.Notes) env.Warn(n);

        ctx.Emit(env);
        return outcome.Delivered ? ExitCodes.Ok : ExitCodes.NotDelivered;
    }

    public static int VerifyCmd(Ctx ctx)
    {
        var (rec, win) = Common.Target(ctx);
        var stateSel = Common.StateSelector(ctx.Args);
        var exp = Common.Expectation(ctx.Args);
        var sw = Stopwatch.StartNew();

        var probe = StateProbe.Take(win.Hwnd, stateSel);
        var report = VerifyLogic.Evaluate(exp, probe.Read, probe.Read, changed: null,
                                          delivered: false, failureReason: "",
                                          targetDesc: stateSel?.Describe() ?? "(auto)",
                                          actionDesc: "read-only verify",
                                          provider: VerifyLogic.ProviderUia);

        var env = ResultEnvelope.Success(Actions.Verify);
        env.Method = "uia_state";
        env.ElapsedMs = sw.Elapsed.TotalMilliseconds;
        env.Delivered = null;
        env.Verified = report.Result switch
        {
            VerifyCategory.Success => true,
            VerifyCategory.Failure => false,
            _ => null,
        };
        // verify 命令的 ok 表示「读到了并且符合期望」，因此直接取报告结论
        env.Ok = report.Result.IsOk();
        env.Verification = report;
        if (!env.Ok) env.FailureReason = report.Note;
        env.With("session", rec?.Id)
           .With("observed", probe.Read.StateValue)
           .With("found", probe.Read.Found)
           .With("element", new { role = probe.Read.Role, automationId = probe.Read.Identifier, title = probe.Read.Title });
        ctx.Emit(env);
        return env.Ok ? ExitCodes.Ok : ExitCodes.VerifyFailed;
    }

    public static int CursorCmd(Ctx ctx)
    {
        var (rec, win) = Common.Target(ctx);
        if (rec == null)
        {
            return ctx.Fail(new CliError(ErrorCodes.NoSession, "该命令需要 --id <会话>", ExitCodes.TargetNotFound));
        }

        EnsureGhost(rec, win);
        var x = ctx.Args.Int("x") ?? 40;
        var y = ctx.Args.Int("y") ?? 40;
        var reply = GhostClient.Send(rec.GhostPipe, new { op = "move", x, y });
        var env = ResultEnvelope.Success("cursor");
        env.Ok = reply.Ok;
        env.Method = "ghost";
        env.With("x", x).With("y", y).With("pipe", rec.GhostPipe);
        if (!reply.Ok) env.FailureReason = reply.Error;
        ctx.Emit(env);
        return reply.Ok ? ExitCodes.Ok : ExitCodes.Internal;
    }

    // ---------------- Ghost ----------------

    public static int GhostCmd(Ctx ctx)
    {
        var sub = ctx.Args.Positional.FirstOrDefault() ?? "status";

        if (sub == "__daemon")
        {
            // 由 ghost start 拉起的覆盖层进程
            var pipeName = ctx.Args.Str("pipe") ?? "";
            var hwnd = ctx.Args.Str("hwnd") ?? "";
            var session = ctx.Args.Str("session") ?? "";
            return GhostDaemon.Run(pipeName, hwnd, session);
        }

        var id = ctx.Args.Str("id");
        var rec = SessionStore.Load(id);
        var pipe = rec?.GhostPipe ?? ctx.Args.Str("pipe") ?? "";

        switch (sub)
        {
            case "start":
            {
                if (rec == null)
                {
                    // 允许不依赖会话：直接挂在某个窗口上
                    var token = ctx.Args.Str("app");
                    if (string.IsNullOrEmpty(token))
                    {
                        return ctx.Fail(new CliError(ErrorCodes.BadArgs, "需要 --id <会话> 或 --app <应用>"));
                    }
                    var found = AppDiscovery.Find(token!);
                    if (found == null)
                    {
                        return ctx.Fail(new CliError(ErrorCodes.AppNotFound, $"找不到应用：{token}", ExitCodes.TargetNotFound));
                    }
                    rec = SessionStore.Create(found.Value.Window, ghost: true);
                    pipe = rec.GhostPipe;
                }

                if (GhostClient.IsAlive(pipe))
                {
                    ctx.EmitObject(new { ok = true, alreadyRunning = true, pipe });
                    return ExitCodes.Ok;
                }

                var pid = GhostClient.Start(pipe, rec.WindowHandle, rec.Id);
                Thread.Sleep(220);
                var alive = GhostClient.IsAlive(pipe);
                ctx.EmitObject(new { ok = alive, pid, pipe, alive });
                return alive ? ExitCodes.Ok : ExitCodes.Internal;
            }

            case "move":
            {
                var x = ctx.Args.Int("x") ?? 40;
                var y = ctx.Args.Int("y") ?? 40;
                var reply = GhostClient.Send(pipe, new { op = "move", x, y });
                ctx.EmitObject(new { ok = reply.Ok, x, y, error = reply.Error });
                return reply.Ok ? ExitCodes.Ok : ExitCodes.Internal;
            }

            case "click":
            {
                var reply = GhostClient.Send(pipe, new { op = "click" });
                ctx.EmitObject(new { ok = reply.Ok, error = reply.Error });
                return reply.Ok ? ExitCodes.Ok : ExitCodes.Internal;
            }

            case "hide":
            {
                var reply = GhostClient.Send(pipe, new { op = "hide" });
                ctx.EmitObject(new { ok = reply.Ok, error = reply.Error });
                return reply.Ok ? ExitCodes.Ok : ExitCodes.Internal;
            }

            case "stop":
            {
                var (stopped, detail) = GhostClient.Stop(pipe);
                ctx.EmitObject(new { ok = stopped, stopped, detail, pipe });
                return stopped ? ExitCodes.Ok : ExitCodes.Internal;
            }

            case "status":
            {
                var status = GhostClient.Status(pipe);
                ctx.EmitObject(status);
                return status.TryGetValue("alive", out var aliveObj) && aliveObj is true
                    ? ExitCodes.Ok : ExitCodes.Internal;
            }

            default:
                return ctx.Fail(new CliError(ErrorCodes.BadArgs,
                    $"未知的 ghost 子命令：{sub}（start/move/click/hide/stop/status）"));
        }
    }

    // ---------------- 追踪 ----------------

    public static int TraceCmd(Ctx ctx)
    {
        var sub = ctx.Args.Positional.FirstOrDefault() ?? "report";

        switch (sub)
        {
            case "__daemon":
                return ActivationTrace.Daemon();

            case "start":
            {
                if (ActivationTrace.DaemonPid() is int existing)
                {
                    ctx.EmitObject(new { ok = true, alreadyRunning = true, pid = existing });
                    return ExitCodes.Ok;
                }
                var exe = Environment.ProcessPath;
                if (string.IsNullOrEmpty(exe))
                {
                    return ctx.Fail(new CliError(ErrorCodes.Internal, "拿不到自身可执行路径"));
                }
                var p = DetachedProcess.Start(new ProcessStartInfo
                {
                    FileName = exe,
                    Arguments = "trace __daemon",
                    UseShellExecute = false,
                    CreateNoWindow = true,
                    WindowStyle = ProcessWindowStyle.Hidden,
                    RedirectStandardOutput = true,
                    RedirectStandardError = true,
                    RedirectStandardInput = true,
                });
                Thread.Sleep(200);
                var pid = ActivationTrace.DaemonPid();
                ctx.EmitObject(new { ok = pid != null, pid, started = p });
                return pid != null ? ExitCodes.Ok : ExitCodes.Internal;
            }

            case "stop":
            {
                var stopped = ActivationTrace.StopDaemon();
                ctx.EmitObject(new { ok = true, stopped });
                return ExitCodes.Ok;
            }

            default:
            {
                ctx.EmitObject(ActivationTrace.Report());
                return ExitCodes.Ok;
            }
        }
    }

    // ---------------- 经验 / 性能 ----------------

    public static int ExperienceCmd(Ctx ctx)
    {
        var sub = ctx.Args.Positional.FirstOrDefault() ?? "list";
        var app = ctx.Args.Str("app");

        switch (sub)
        {
            case "list":
            {
                var list = ExperienceStore.List();
                if (ctx.Json)
                {
                    ctx.EmitObject(new { ok = true, count = list.Count, apps = list });
                }
                else
                {
                    foreach (var e in list)
                    {
                        ctx.Text($"{e.AppName,-22} uses={e.Uses} ok={e.Successes} fail={e.Failures} "
                                 + $"workflows={e.Workflows.Count}  {e.Executable}");
                    }
                    if (list.Count == 0) ctx.Text("(经验库为空：跑几次成功的操作就会自动积累)");
                }
                return ExitCodes.Ok;
            }

            case "show":
            {
                var list = ExperienceStore.List();
                var hit = app == null ? list.FirstOrDefault()
                                      : list.FirstOrDefault(e => e.Executable.ToLowerInvariant().Contains(app!.ToLowerInvariant())
                                                                 || e.AppName.ToLowerInvariant().Contains(app!.ToLowerInvariant()));
                if (hit == null)
                {
                    return ctx.Fail(new CliError(ErrorCodes.AppNotFound, "没有匹配的应用经验", ExitCodes.TargetNotFound));
                }
                ctx.EmitObject(hit);
                return ExitCodes.Ok;
            }

            case "clear":
            {
                var n = ExperienceStore.Clear(app);
                ctx.EmitObject(new { ok = true, cleared = n });
                return ExitCodes.Ok;
            }

            default:
                return ctx.Fail(new CliError(ErrorCodes.BadArgs, $"未知的 experience 子命令：{sub}"));
        }
    }

    public static int PerfCmd(Ctx ctx)
    {
        var sub = ctx.Args.Positional.FirstOrDefault() ?? "stats";

        if (sub == "reset")
        {
            try { if (File.Exists(Paths.Perf)) File.Delete(Paths.Perf); } catch { }
            ctx.EmitObject(new { ok = true, reset = true });
            return ExitCodes.Ok;
        }

        if (!File.Exists(Paths.Perf))
        {
            ctx.EmitObject(new { ok = true, count = 0, note = "还没有性能记录，先跑几次 click" });
            return ExitCodes.Ok;
        }

        var rows = new List<Dictionary<string, object?>>();
        foreach (var line in File.ReadLines(Paths.Perf))
        {
            if (string.IsNullOrWhiteSpace(line)) continue;
            try
            {
                var d = Json.Deserialize<Dictionary<string, object?>>(line);
                if (d != null) rows.Add(d);
            }
            catch { }
        }

        double Num(Dictionary<string, object?> d, string key)
        {
            if (!d.TryGetValue(key, out var v) || v == null) return double.NaN;
            return v switch
            {
                double db => db,
                long l => l,
                int i => i,
                System.Text.Json.JsonElement je when je.ValueKind == System.Text.Json.JsonValueKind.Number => je.GetDouble(),
                _ => double.TryParse(v.ToString(), out var p) ? p : double.NaN,
            };
        }

        var byAction = rows.GroupBy(r => r.TryGetValue("action", out var a) ? a?.ToString() ?? "?" : "?")
            .Select(g => new Dictionary<string, object?>
            {
                ["action"] = g.Key,
                ["samples"] = g.Count(),
                ["dispatchP50"] = Math.Round(Percentile.P50(g.Select(r => Num(r, "dispatchMs"))), 2),
                ["dispatchP95"] = Math.Round(Percentile.P95(g.Select(r => Num(r, "dispatchMs"))), 2),
                ["endToEndP50"] = Math.Round(Percentile.P50(g.Select(r => Num(r, "endToEndMs"))), 2),
                ["endToEndP95"] = Math.Round(Percentile.P95(g.Select(r => Num(r, "endToEndMs"))), 2),
                ["verifyP50"] = Math.Round(Percentile.P50(g.Select(r => Num(r, "verifyMs"))), 2),
                ["successRate"] = Math.Round(g.Count(r => r.TryGetValue("ok", out var o) && o is true) / (double)g.Count(), 3),
            }).ToList();

        ctx.EmitObject(new { ok = true, count = rows.Count, stats = byAction });
        return ExitCodes.Ok;
    }

    // ---------------- 公共辅助 ----------------

    private static void EnsureGhost(SessionRecord rec, WindowInfo win)
    {
        if (GhostClient.IsAlive(rec.GhostPipe)) return;
        GhostClient.Start(rec.GhostPipe, win.HwndHex, rec.Id);
        Thread.Sleep(200);
    }

    private static void GhostFeedback(SessionRecord? rec, WindowInfo win, int screenX, int screenY)
    {
        if (rec == null || !rec.Ghost) return;
        try
        {
            EnsureGhost(rec, win);
            var relX = screenX - win.Frame.Left;
            var relY = screenY - win.Frame.Top;
            GhostClient.Send(rec.GhostPipe, new { op = "move", x = relX, y = relY }, 400);
            GhostClient.Send(rec.GhostPipe, new { op = "click" }, 400);
        }
        catch
        {
            // 覆盖层只是视觉反馈，任何失败都不影响操作结论
        }
    }
}
