using Wbcu.Contract;
using Xunit;

namespace Wbcu.Tests;

/// <summary>
/// 验证逻辑的四分类语义测试。
/// 用例尽量复刻 macOS v0.4.3/v0.5.0 的真实踩坑记录（计算器 LRM、结果在新元素里出现等）。
/// </summary>
public class VerifyLogicTests
{
    private static VerifyReport Eval(
        StateExpectation exp, string pre, string actual,
        bool? changed = null, bool delivered = true,
        ElementReadout? elsewhere = null, bool preFound = true, bool actualFound = true,
        string provider = VerifyLogic.ProviderUia)
    {
        return VerifyLogic.Evaluate(
            exp,
            new ElementReadout { Found = preFound, Value = pre },
            new ElementReadout { Found = actualFound, Value = actual },
            changed, delivered, "", "target", "action", elsewhere, provider);
    }

    [Fact]
    public void Explicit_expectation_met_is_success()
    {
        var r = Eval(new StateExpectation { Value = "15" }, "0", "15", changed: true);
        Assert.Equal(VerifyCategory.Success, r.Result);
        Assert.Equal("uia_state_matches_expected", r.VerificationMethod);
        Assert.Equal(0.95, r.Confidence);
        Assert.Equal(Consumed.Proven, r.ClickConsumed);
        Assert.True(r.Ok);
    }

    [Fact]
    public void Expectation_already_met_before_click_is_already_satisfied_not_success()
    {
        // 幂等或「点击没被消费」都长这样，所以只能给 already_satisfied + 0.60
        var r = Eval(new StateExpectation { Value = "0" }, "0", "0");
        Assert.Equal(VerifyCategory.AlreadySatisfied, r.Result);
        Assert.Equal(0.60, r.Confidence);
        Assert.Equal(Consumed.Unproven, r.ClickConsumed);
        Assert.True(r.Ok);
    }

    [Fact]
    public void Mismatch_is_failure_with_expected_and_actual_in_note()
    {
        var r = Eval(new StateExpectation { Value = "15" }, "0", "12", changed: true);
        Assert.Equal(VerifyCategory.Failure, r.Result);
        Assert.Equal(0.95, r.Confidence);
        Assert.Contains("15", r.Note);
        Assert.Contains("12", r.Note);
        Assert.False(r.Ok);
    }

    [Fact]
    public void Thousands_separator_and_invisible_marks_are_normalized()
    {
        // 实测踩坑：macOS 计算器显示 7,778，读出来的字节含 U+200E
        var actual = "\u200E7,778\0";
        var r = Eval(new StateExpectation { Value = "7778" }, "0", actual, changed: true);
        Assert.Equal(VerifyCategory.Success, r.Result);
    }

    [Fact]
    public void Expected_value_found_on_another_element_is_success_with_lower_confidence()
    {
        var r = VerifyLogic.Evaluate(
            new StateExpectation { Value = "1000" },
            new ElementReadout { Found = true, Value = "" },
            new ElementReadout { Found = true, Value = "8*125" },
            changed: true, delivered: true, failureReason: "", targetDesc: "t", actionDesc: "a",
            elsewhere: new ElementReadout { Found = true, Value = "1000", Role = "Text", Path = new[] { 0, 2 } },
            provider: VerifyLogic.ProviderUia);

        Assert.Equal(VerifyCategory.Success, r.Result);
        Assert.Equal("uia_value_found_elsewhere", r.VerificationMethod);
        Assert.Equal(0.85, r.Confidence);
        Assert.Contains("1000", r.ActualState?.Value ?? "");
    }

    [Fact]
    public void Unreadable_state_is_inconclusive_not_failure()
    {
        var r = Eval(new StateExpectation { Value = "15" }, "0", "", actualFound: false);
        Assert.Equal(VerifyCategory.Inconclusive, r.Result);
        Assert.Equal("uia_state_unreadable", r.VerificationMethod);
        Assert.Equal(0.30, r.Confidence);
        Assert.False(r.Ok); // 证据不足不是成功
    }

    [Fact]
    public void No_expectation_with_change_is_weak_success()
    {
        var r = Eval(new StateExpectation(), "0", "1", changed: true);
        Assert.Equal(VerifyCategory.Success, r.Result);
        Assert.Equal("ui_changed", r.VerificationMethod);
        Assert.Equal(0.75, r.Confidence);
    }

    [Fact]
    public void No_change_without_declaration_is_inconclusive()
    {
        var r = Eval(new StateExpectation(), "0", "0", changed: false);
        Assert.Equal(VerifyCategory.Inconclusive, r.Result);
        Assert.Equal("no_observable_change", r.VerificationMethod);
        Assert.Contains("幂等", r.Note);
    }

    [Fact]
    public void Declared_idempotent_without_change_is_already_satisfied()
    {
        var r = Eval(new StateExpectation { Idempotent = true }, "0", "0", changed: false);
        Assert.Equal(VerifyCategory.AlreadySatisfied, r.Result);
        Assert.Equal("declared_idempotent", r.VerificationMethod);
    }

    [Fact]
    public void Expected_no_change_is_success()
    {
        var r = Eval(new StateExpectation { Match = TextNormalize.Modes.NotChanged }, "0", "0", changed: false);
        Assert.Equal(VerifyCategory.Success, r.Result);
        Assert.Equal("expected_no_change", r.VerificationMethod);
    }

    [Fact]
    public void Not_verified_is_inconclusive_not_success()
    {
        var r = Eval(new StateExpectation(), "0", "0", changed: null);
        Assert.Equal(VerifyCategory.Inconclusive, r.Result);
        Assert.Equal("not_verified", r.VerificationMethod);
        Assert.False(r.Ok);
    }

    [Fact]
    public void Provider_prefix_distinguishes_ax_from_uia_without_changing_semantics()
    {
        var ax = Eval(new StateExpectation { Value = "15" }, "0", "15", changed: true, provider: VerifyLogic.ProviderAx);
        var uia = Eval(new StateExpectation { Value = "15" }, "0", "15", changed: true, provider: VerifyLogic.ProviderUia);

        Assert.Equal("ax_state_matches_expected", ax.VerificationMethod);
        Assert.Equal("uia_state_matches_expected", uia.VerificationMethod);
        Assert.Equal(ax.Result, uia.Result);
        Assert.Equal(ax.Confidence, uia.Confidence);
    }

    [Fact]
    public void Unreadable_precondition_still_reports_actual()
    {
        var r = Eval(new StateExpectation { Value = "15" }, "", "15", changed: true, preFound: false);
        Assert.Equal(VerifyCategory.Success, r.Result);
        Assert.False(r.Precondition!.Found);
        Assert.True(r.ActualState!.Found);
    }
}
