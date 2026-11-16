using System.Text.Json;
using System.Text.Json.Serialization;

namespace Wbcu.Contract;

/// <summary>
/// 统一结果信封。macOS 与 Windows 的每一条 JSON 输出都套在这个结构里
/// （macOS 侧字段是既有的散装 dict，语义一一对应，见 contract/result.schema.json）。
///
/// 几条硬规矩：
///   - ok 只表示「操作目标达成」。API 返回成功 ≠ ok=true。
///   - delivered 与 verified 分开报：事件投递成功但 UI 没变，就是 delivered=true / verified=false。
///   - frontAppPreserved / physicalCursorPreserved 必须如实报，不能因为「没测」就写 true。
///   - 任何降级（例如 UIA 不可用改走消息投递）都进 warnings，不许静默。
/// </summary>
public sealed class ResultEnvelope
{
    public bool Ok { get; set; }

    /// <summary>统一动作名，见 <see cref="Actions"/>。</summary>
    public string Action { get; set; } = "";

    public string Platform { get; set; } = Platforms.Windows;
    public string Engine { get; set; } = Engines.WindowsUia;

    /// <summary>实际用的执行路径：uia_invoke / uia_value / wm_message / global_input / none。</summary>
    public string? Method { get; set; }

    /// <summary>事件是否已进入目标（目标进程收到了语义调用或窗口消息）。null = 未涉及投递。</summary>
    public bool? Delivered { get; set; }

    /// <summary>UI 是否真的产生了预期变化。null = 没有验证或验证不可用。</summary>
    public bool? Verified { get; set; }

    public VerifyReport? Verification { get; set; }

    public string? FailureReason { get; set; }
    public string? ErrorCode { get; set; }

    /// <summary>执行前后前台窗口有没有变。null = 未测量（不要伪造成 true）。</summary>
    public bool? FrontAppPreserved { get; set; }

    /// <summary>真实鼠标位置有没有被挪动。null = 未测量。</summary>
    public bool? PhysicalCursorPreserved { get; set; }

    public double ElapsedMs { get; set; }

    /// <summary>动作专属数据（坐标、元素描述、截图路径、session 等）。</summary>
    public Dictionary<string, object?> Data { get; set; } = new();

    public List<string> Warnings { get; set; } = new();

    // ---- 构造捷径 ----

    public static ResultEnvelope Success(string action) => new() { Ok = true, Action = action };

    public static ResultEnvelope Error(string action, string errorCode, string reason) => new()
    {
        Ok = false,
        Action = action,
        ErrorCode = errorCode,
        FailureReason = reason,
    };

    public ResultEnvelope With(string key, object? value)
    {
        Data[key] = value;
        return this;
    }

    public ResultEnvelope Warn(string message)
    {
        Warnings.Add(message);
        return this;
    }

    /// <summary>
    /// 把「投递层结果 + 验证报告」合并成最终裁决：
    /// ok 取验证结论；没有验证时退化为 delivered（与 macOS actionReport 的口径一致）。
    /// </summary>
    public ResultEnvelope ApplyVerification(VerifyReport report, bool delivered)
    {
        Verification = report;
        Delivered = delivered;
        Verified = report.Result switch
        {
            VerifyCategory.Success => true,
            VerifyCategory.AlreadySatisfied => true,
            VerifyCategory.Failure => false,
            _ => null, // inconclusive：没有证据，就不给 true/false
        };
        Ok = Verified ?? delivered;
        if (!Ok && string.IsNullOrEmpty(FailureReason)) FailureReason = report.Note;
        if (!Ok && string.IsNullOrEmpty(ErrorCode)) ErrorCode = ErrorCodes.DeliverFailed;
        return this;
    }

    public string ToJson(bool pretty = false) => Json.Serialize(this, pretty);
}

/// <summary>全仓库统一的 JSON 序列化口径（camelCase、不裁剪 null、枚举写字面量）。</summary>
public static class Json
{
    public static readonly JsonSerializerOptions Options = Build(false);
    public static readonly JsonSerializerOptions PrettyOptions = Build(true);

    private static JsonSerializerOptions Build(bool pretty) => new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        DefaultIgnoreCondition = JsonIgnoreCondition.Never,
        WriteIndented = pretty,
        Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
        Converters = { new VerifyCategoryConverter(), new JsonStringEnumConverter() },
    };

    public static string Serialize<T>(T value, bool pretty = false) =>
        JsonSerializer.Serialize(value, pretty ? PrettyOptions : Options);

    public static T? Deserialize<T>(string json) =>
        JsonSerializer.Deserialize<T>(json, Options);
}
