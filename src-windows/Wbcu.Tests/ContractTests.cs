using Wbcu.Contract;
using Xunit;

namespace Wbcu.Tests;

/// <summary>
/// 跨平台契约测试：这些断言同时约束 macOS（Swift 实现）与 Windows（C# 实现）。
/// 任何一边改了语义而另一边没跟上，这里就得红。
/// </summary>
public class ContractTests
{
    [Fact]
    public void Actions_are_unique_and_nonempty()
    {
        Assert.NotEmpty(Actions.All);
        Assert.Equal(Actions.All.Length, Actions.All.Distinct().Count());
        foreach (var a in Actions.All)
        {
            Assert.False(string.IsNullOrWhiteSpace(a));
            Assert.True(Actions.IsKnown(a));
        }
    }

    [Fact]
    public void Actions_cover_the_documented_eleven()
    {
        // SKILL.md 的动作表是 11 条，多一条少一条都要在这里显式体现
        Assert.Equal(11, Actions.All.Length);
        Assert.Contains("launch", Actions.All);
        Assert.Contains("attach", Actions.All);
        Assert.Contains("inspect", Actions.All);
        Assert.Contains("capture", Actions.All);
        Assert.Contains("click", Actions.All);
        Assert.Contains("type", Actions.All);
        Assert.Contains("scroll", Actions.All);
        Assert.Contains("key", Actions.All);
        Assert.Contains("verify", Actions.All);
        Assert.Contains("trace", Actions.All);
        Assert.Contains("endSession", Actions.All);
    }

    [Fact]
    public void ErrorCodes_are_unique()
    {
        Assert.Equal(ErrorCodes.All.Length, ErrorCodes.All.Distinct().Count());
    }

    [Fact]
    public void CapabilityKeys_are_unique()
    {
        Assert.Equal(CapabilityKeys.All.Length, CapabilityKeys.All.Distinct().Count());
    }

    [Fact]
    public void Contract_schema_contains_every_action_and_code()
    {
        var schema = ContractSchema.Build(Platforms.Windows, Engines.WindowsUia, "0.6.0");

        Assert.Equal("1.0", schema["schemaVersion"]);
        var actions = (string[])schema["actions"]!;
        var codes = (string[])schema["errorCodes"]!;
        var keys = (string[])schema["capabilityKeys"]!;

        Assert.Equal(Actions.All, actions);
        Assert.Equal(ErrorCodes.All, codes);
        Assert.Equal(CapabilityKeys.All, keys);
        Assert.Contains("inconclusive", (string[])schema["verifyCategories"]!);
    }

    [Fact]
    public void Result_envelope_serializes_camel_case_and_keeps_nulls()
    {
        var env = ResultEnvelope.Success("click");
        var json = env.ToJson();

        Assert.Contains("\"action\":\"click\"", json);
        Assert.Contains("\"platform\":\"windows\"", json);
        // 未测量字段必须是 null，而不是被裁掉 —— 裁剪会让「没测」看起来像「没这个字段」
        Assert.Contains("\"frontAppPreserved\":null", json);
        Assert.Contains("\"physicalCursorPreserved\":null", json);
    }

    [Fact]
    public void Inconclusive_verification_does_not_turn_into_ok()
    {
        var pre = new ElementReadout { Found = true, Value = "0" };
        var actual = new ElementReadout { Found = true, Value = "0" };
        var exp = new StateExpectation { Value = "7" };

        var report = VerifyLogic.Evaluate(exp, pre, actual, changed: false, delivered: true,
            failureReason: "", targetDesc: "t", actionDesc: "a");

        var env = ResultEnvelope.Success("click").ApplyVerification(report, delivered: false);

        Assert.Equal(VerifyCategory.Failure, report.Result);
        Assert.False(env.Ok);
        Assert.Equal(ErrorCodes.DeliverFailed, env.ErrorCode);
    }

    [Fact]
    public void Delivered_true_verified_null_falls_back_to_delivered()
    {
        var pre = new ElementReadout { Found = true, Value = "0" };
        var actual = new ElementReadout { Found = true, Value = "0" };
        var report = VerifyLogic.Evaluate(new StateExpectation(), pre, actual, changed: false,
            delivered: true, failureReason: "", targetDesc: "t", actionDesc: "a");

        var env = ResultEnvelope.Success("click").ApplyVerification(report, delivered: true);

        Assert.Equal(VerifyCategory.Inconclusive, report.Result);
        Assert.True(env.Ok);           // 退化为 delivered
        Assert.Null(env.Verified);     // 但绝不谎报「已验证」
    }

    [Fact]
    public void Percentile_handles_empty_and_small_samples()
    {
        Assert.Equal(0, Percentile.P50(Array.Empty<double>()));
        Assert.Equal(5, Percentile.P50(new[] { 5.0 }));
        var v = new[] { 10.0, 20.0, 30.0, 40.0, 50.0 };
        Assert.Equal(30, Percentile.P50(v));
        Assert.True(Percentile.P95(v) > 40);
    }
}
