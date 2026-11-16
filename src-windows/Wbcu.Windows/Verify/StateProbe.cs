using Wbcu.Contract;
using Wbcu.Windows.Uia;

namespace Wbcu.Windows.Verify;

/// <summary>一次状态探测的完整证据：树快照 + 状态元素读数 + 指纹。</summary>
public sealed class Probe
{
    public UiaSnapshot Snapshot { get; init; } = new();
    public ElementReadout Read { get; init; } = new();
    public string Fingerprint => Snapshot.Fingerprint;
    public double Ms => Snapshot.BuildMs;
}

/// <summary>
/// 状态探测与验证流程。
///
/// 与 macOS 的 ExpectedStateVerifier 同构：
///   操作前读数（precondition）→ 操作 → 等到期望出现或超时 → 四分类裁决
///
/// 加了一条 macOS 侧也验证过的兜底：主显示元素没达到期望时，
/// 在整棵树里按值搜索一次（对应「结果出现在另一个元素里」的真实情况，
/// 典型如计算器的表达式行与结果行分离）。
/// </summary>
public static class StateProbe
{
    public static Probe Take(IntPtr hwnd, Selector? selector, int maxDepth = 16)
    {
        var snap = UiaResolver.Walk(hwnd, maxDepth: maxDepth, maxNodes: 2000, includePatterns: true);
        var node = selector == null
            ? UiaResolver.Locate(snap, Selector.None)
            : UiaResolver.Locate(snap, selector);

        var read = node == null
            ? new ElementReadout { Found = false, ElapsedMs = (long)snap.BuildMs }
            : new ElementReadout
            {
                Found = true,
                Role = node.ControlType,
                Identifier = node.AutomationId,
                Title = node.Name,
                Value = node.Value,
                Path = node.Path,
                ElapsedMs = (long)snap.BuildMs,
            };

        return new Probe { Snapshot = snap, Read = read };
    }

    /// <summary>
    /// 等待期望值出现（应用更新 UI 往往是异步的），同时计算「整棵树指纹有没有变」。
    /// 轮询间隔 25ms —— 与 macOS 一致，不做固定 sleep 堆积。
    /// </summary>
    public static (Probe After, bool? Changed) WaitFor(IntPtr hwnd, Selector? selector,
                                                       StateExpectation exp, Probe before)
    {
        var deadline = Environment.TickCount64 + Math.Clamp(exp.MaxWaitMs, 0, 5000);
        var after = Take(hwnd, selector);
        var changed = after.Fingerprint != before.Fingerprint;

        if (string.IsNullOrEmpty(exp.Value)) return (after, changed);

        while (Environment.TickCount64 < deadline)
        {
            var current = after.Read;
            if (current.Found && TextNormalize.Matches(current.StateValue, exp.Value, exp.Match))
            {
                return (after, after.Fingerprint != before.Fingerprint);
            }
            Thread.Sleep(25);
            after = Take(hwnd, selector);
        }

        changed = after.Fingerprint != before.Fingerprint;
        return (after, changed);
    }

    /// <summary>给出四分类裁决。主元素不达标时，按值再搜一次整棵树（含「别处出现」兜底）。</summary>
    public static VerifyReport Evaluate(IntPtr hwnd, StateExpectation exp, Probe before, Probe after,
                                        bool? changed, bool delivered, string failureReason,
                                        string targetDesc, string actionDesc)
    {
        ElementReadout? elsewhere = null;
        if (!string.IsNullOrEmpty(exp.Value)
            && after.Read.Found
            && !TextNormalize.Matches(after.Read.StateValue, exp.Value, exp.Match))
        {
            var hit = UiaResolver.SearchValue(hwnd, exp.Value!, after.Read.Path);
            if (hit.Found) elsewhere = hit;
        }

        return VerifyLogic.Evaluate(exp, before.Read, after.Read, changed, delivered,
                                    failureReason, targetDesc, actionDesc, elsewhere,
                                    provider: VerifyLogic.ProviderUia);
    }
}
