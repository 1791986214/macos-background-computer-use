using System.Text.Json.Serialization;

namespace Wbcu.Contract;

/// <summary>验证结论四分类。与 macOS ExpectedStateVerifier 完全一致。</summary>
[JsonConverter(typeof(VerifyCategoryConverter))]
public enum VerifyCategory
{
    Success,
    AlreadySatisfied,
    Failure,
    Inconclusive,
}

public static class VerifyCategoryExtensions
{
    public static string ToWire(this VerifyCategory c) => c switch
    {
        VerifyCategory.Success => "success",
        VerifyCategory.AlreadySatisfied => "already_satisfied",
        VerifyCategory.Failure => "failure",
        _ => "inconclusive",
    };

    /// <summary>「操作目标达成」= success 或 already_satisfied。</summary>
    public static bool IsOk(this VerifyCategory c) =>
        c is VerifyCategory.Success or VerifyCategory.AlreadySatisfied;
}

/// <summary>点击是否被证明「被应用消费」：proven / unproven / no。</summary>
public static class Consumed
{
    public const string Proven = "proven";
    public const string Unproven = "unproven";
    public const string No = "no";
}

/// <summary>
/// 一次操作前的期望声明。value 为 null 表示「没给显式期望」，只能做弱验证。
/// </summary>
public sealed class StateExpectation
{
    public string? Value { get; set; }
    public string Match { get; set; } = TextNormalize.Modes.Equals_;
    /// <summary>状态元素定位提示，语法与 Selector 相同。为空表示用窗口默认状态元素。</summary>
    public string? ElementHint { get; set; }
    /// <summary>显式声明幂等：无变化不算失败。</summary>
    public bool? Idempotent { get; set; }
    public int MaxWaitMs { get; set; } = 600;

    public static StateExpectation Parse(string? match, string? value, string? hint) => new()
    {
        Value = value,
        Match = string.IsNullOrEmpty(match) ? TextNormalize.Modes.Equals_ : match!.ToLowerInvariant(),
        ElementHint = hint,
    };
}

/// <summary>
/// 对某个「状态元素」的一次读数。字段名与 macOS 的 ElementReadout 对应：
/// role/identifier/title/value/path/elapsedMs，另外加了 Windows 侧的 controlType/automationId 别名。
/// </summary>
public sealed class ElementReadout
{
    public bool Found { get; set; }
    public int[] Path { get; set; } = Array.Empty<int>();
    /// <summary>跨平台中性名：macOS 填 AXRole，Windows 填 ControlType 名。</summary>
    public string Role { get; set; } = "";
    /// <summary>跨平台中性名：macOS 填 AXIdentifier，Windows 填 AutomationId。</summary>
    public string Identifier { get; set; } = "";
    public string Title { get; set; } = "";
    public string Value { get; set; } = "";
    public long ElapsedMs { get; set; }

    /// <summary>用于比较的「状态值」：优先 value，其次 title（与 macOS 一致）。</summary>
    [JsonIgnore]
    public string StateValue => string.IsNullOrEmpty(Value) ? Title : Value;
}

/// <summary>
/// 验证报告。字段名保持 macOS 既有输出不变（result/ok/verificationMethod/confidence/
/// clickConsumed/target/action/expectedState/note + precondition/actualState），
/// 这样 WorkBuddy 侧不需要为平台分叉解析逻辑。
/// </summary>
public sealed class VerifyReport
{
    public VerifyCategory Result { get; set; } = VerifyCategory.Inconclusive;
    public bool Ok => Result.IsOk();
    public string VerificationMethod { get; set; } = "none";
    public double Confidence { get; set; }
    public string ClickConsumed { get; set; } = Consumed.Unproven;
    public string Target { get; set; } = "";
    public string Action { get; set; } = "";
    public string ExpectedState { get; set; } = "";
    public string Note { get; set; } = "";
    public ElementReadout? Precondition { get; set; }
    public ElementReadout? ActualState { get; set; }
    public List<string> Notes { get; } = new();
}

/// <summary>
/// 验证逻辑本体：纯函数，零系统依赖，因此两个平台的语义可以用同一组单元测试锁住。
///
/// macOS 引擎目前在 Swift 里独立实现同一套判据（v0.5.0 已验证）；这里把判据
/// 抽成可测的形式给 Windows 用，并作为「语义基准」。字段 provider 用来生成
/// 平台化的方法名（ax_state_matches_expected / uia_state_matches_expected），
/// 语义相同、证据来源可区分。
/// </summary>
public static class VerifyLogic
{
    public const string ProviderAx = "ax";
    public const string ProviderUia = "uia";

    public static VerifyReport Evaluate(
        StateExpectation expectation,
        ElementReadout pre,
        ElementReadout actual,
        bool? changed,
        bool delivered,
        string failureReason,
        string targetDesc,
        string actionDesc,
        ElementReadout? elsewhere = null,
        string provider = ProviderUia)
    {
        var r = new VerifyReport
        {
            Precondition = pre,
            ActualState = actual,
            Target = targetDesc,
            Action = actionDesc,
        };

        // ① 显式期望：最强判据
        if (!string.IsNullOrEmpty(expectation.Value))
        {
            var want = expectation.Value!;
            r.ExpectedState = $"{expectation.Match} \"{want}\"";

            if (!actual.Found)
            {
                r.Result = VerifyCategory.Inconclusive;
                r.VerificationMethod = $"{provider}_state_unreadable";
                r.Confidence = 0.30;
                r.Notes.Add("读不到状态元素，无法判断结果");
                r.Note = string.Join("; ", r.Notes);
                return r;
            }

            var okNow = TextNormalize.Matches(actual.StateValue, want, expectation.Match);
            var okBefore = pre.Found && TextNormalize.Matches(pre.StateValue, want, expectation.Match);

            if (okNow && okBefore)
            {
                r.Result = VerifyCategory.AlreadySatisfied;
                r.VerificationMethod = $"{provider}_state_pre_equals_expected";
                r.Confidence = 0.60;
                r.ClickConsumed = delivered ? Consumed.Unproven : Consumed.No;
                r.Notes.Add($"操作前已满足期望（{pre.StateValue}），不能据此证明点击被消费");
                r.Note = string.Join("; ", r.Notes);
                return r;
            }

            if (okNow)
            {
                r.Result = VerifyCategory.Success;
                r.VerificationMethod = $"{provider}_state_matches_expected";
                r.Confidence = 0.95;
                r.ClickConsumed = Consumed.Proven;
                r.Notes.Add($"状态 {(pre.StateValue.Length == 0 ? "?" : pre.StateValue)} → {actual.StateValue}");
                r.Note = string.Join("; ", r.Notes);
                return r;
            }

            // 主元素没达到期望，但窗口别处出现了期望值
            // （典型：表达式行 / 历史行 / Toast 提示 与 结果行分离）
            if (elsewhere is { Found: true })
            {
                r.Result = VerifyCategory.Success;
                r.VerificationMethod = $"{provider}_value_found_elsewhere";
                r.Confidence = 0.85;
                r.ClickConsumed = Consumed.Proven;
                r.ActualState = elsewhere;
                r.Notes.Add($"主显示元素是 {actual.StateValue}，期望值出现在 {elsewhere.Role}"
                             + $"（path [{string.Join(",", elsewhere.Path)}]）");
                r.Note = string.Join("; ", r.Notes);
                return r;
            }

            r.Result = VerifyCategory.Failure;
            r.VerificationMethod = $"{provider}_state_mismatch";
            r.Confidence = 0.95;
            r.ClickConsumed = changed == true ? Consumed.Proven : Consumed.Unproven;
            r.Notes.Add($"期望 \"{want}\"，实际 \"{actual.StateValue}\"");
            if (changed == true && actual.StateValue != pre.StateValue)
            {
                r.Notes.Add("目标被错误点击或产生了意外结果");
            }
            else if (changed != true)
            {
                r.Notes.Add("状态未变化；投递=" + (delivered ? "已投递" : "未投递")
                             + (string.IsNullOrEmpty(failureReason) ? "" : $"，原因={failureReason}"));
            }
            r.Note = string.Join("; ", r.Notes);
            return r;
        }

        // ② 没给显式期望：只能弱验证
        r.ExpectedState = "changed";
        if (changed == true)
        {
            r.Result = VerifyCategory.Success;
            r.VerificationMethod = "ui_changed";
            r.Confidence = 0.75;
            r.ClickConsumed = Consumed.Proven;
        }
        else if (changed == false)
        {
            // 无变化 ≠ 失败：可能是幂等，也可能是事件没被消费
            if (expectation.Idempotent == true)
            {
                r.Result = VerifyCategory.AlreadySatisfied;
                r.VerificationMethod = "declared_idempotent";
                r.Confidence = 0.55;
                r.ClickConsumed = delivered ? Consumed.Unproven : Consumed.No;
                r.Notes.Add("显式声明幂等，且无可见变化");
            }
            else if (expectation.Match == TextNormalize.Modes.NotChanged)
            {
                r.Result = VerifyCategory.Success;
                r.VerificationMethod = "expected_no_change";
                r.Confidence = 0.70;
                r.ClickConsumed = Consumed.Unproven;
            }
            else
            {
                r.Result = VerifyCategory.Inconclusive;
                r.VerificationMethod = "no_observable_change";
                r.Confidence = 0.30;
                r.ClickConsumed = delivered ? Consumed.Unproven : Consumed.No;
                r.Notes.Add("UI 无可观测变化；无法区分「幂等」与「事件未被消费」");
                if (!string.IsNullOrEmpty(failureReason)) r.Notes.Add($"投递层原因={failureReason}");
            }
        }
        else
        {
            r.Result = VerifyCategory.Inconclusive;
            r.VerificationMethod = "not_verified";
            r.Confidence = 0.20;
            r.Notes.Add("未启用验证或验证路径不可用");
        }

        r.Note = string.Join("; ", r.Notes);
        return r;
    }
}
