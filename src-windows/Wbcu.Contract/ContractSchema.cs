namespace Wbcu.Contract;

/// <summary>
/// 契约文档的可执行版本。`wbcu contract --json`（两平台）输出这份结构，
/// 测试用它做「跨平台语义一致」的机器校验，人读的版本在 contract/README.md。
///
/// 为什么要把契约变成可执行输出而不是只写文档：
/// 文档会漂，代码不会。两个引擎各自实现时，只要有一边动作名或错误码改了一个字母，
/// contract 输出立刻不一致，测试就会红。
/// </summary>
public static class ContractSchema
{
    public const string SchemaVersion = "1.0";

    public static Dictionary<string, object?> Build(string platform, string engine, string engineVersion)
    {
        return new Dictionary<string, object?>
        {
            ["schemaVersion"] = SchemaVersion,
            ["platform"] = platform,
            ["engine"] = engine,
            ["engineVersion"] = engineVersion,
            ["actions"] = Actions.All,
            ["errorCodes"] = ErrorCodes.All,
            ["verifyCategories"] = new[]
            {
                "success", "already_satisfied", "failure", "inconclusive"
            },
            ["verifyMethods"] = new[]
            {
                "state_matches_expected", "state_pre_equals_expected", "state_unreadable",
                "state_mismatch", "value_found_elsewhere", "ui_changed",
                "declared_idempotent", "expected_no_change", "no_observable_change", "not_verified"
            },
            ["verifyProviders"] = new[] { VerifyLogic.ProviderAx, VerifyLogic.ProviderUia },
            ["matchModes"] = new[]
            {
                TextNormalize.Modes.Equals_, TextNormalize.Modes.Contains, TextNormalize.Modes.NotEquals,
                TextNormalize.Modes.Changed, TextNormalize.Modes.NotChanged, TextNormalize.Modes.Strict
            },
            ["capabilityKeys"] = CapabilityKeys.All,
            ["capabilityStatus"] = FeatureStatus.All,
            ["selectorKinds"] = Enum.GetNames<SelectorKind>()
                                       .Select(n => n.ToLowerInvariant()).ToArray(),
            ["resultFields"] = new[]
            {
                "ok", "action", "platform", "engine", "method", "delivered", "verified",
                "verification", "failureReason", "errorCode", "frontAppPreserved",
                "physicalCursorPreserved", "elapsedMs", "data", "warnings"
            },
            ["invariants"] = new[]
            {
                "ok 只表示操作目标达成，不表示 API 调用返回成功",
                "delivered 与 verified 必须分开上报",
                "未测量的布尔字段必须是 null，不能填 true",
                "inconclusive 不能映射成 ok=true",
                "任何降级路径必须写进 warnings",
                "物理鼠标位置与前台窗口的变化必须如实上报",
            },
        };
    }
}
