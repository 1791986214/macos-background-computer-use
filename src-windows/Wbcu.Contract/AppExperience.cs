namespace Wbcu.Contract;

/// <summary>
/// 应用操作经验（App Experience Memory）。与 macOS 侧同格式、同语义。
///
/// 关键纪律（v0.4.3 起就没变过）：
///   - 只存**语义稳定**的定位信息：AutomationId / 名称 / 控件类型 / 相对路径。
///   - HWND、RuntimeId、屏幕绝对坐标都是短命的，只允许出现在 session 或调试输出里，
///     绝不作为「下次直接用」的定位依据。
///   - 每次复用前必须**重新验证**目标仍然匹配（名称/类型/位置都没漂），
///     验证不过就退回实时查找，而不是闭着眼点历史坐标。
/// </summary>
public sealed class AppExperience
{
    public string Platform { get; set; } = Platforms.Windows;

    // ---- 应用身份 ----
    public string Executable { get; set; } = "";
    public string AppName { get; set; } = "";
    public string PackageFamily { get; set; } = "";
    public string AppVersion { get; set; } = "";
    public string WindowClass { get; set; } = "";

    public string UpdatedAt { get; set; } = "";
    public int Uses { get; set; }
    public int Successes { get; set; }
    public int Failures { get; set; }

    public List<WorkflowMemory> Workflows { get; set; } = new();

    public WorkflowMemory? FindWorkflow(string name) =>
        Workflows.FirstOrDefault(w => string.Equals(w.Name, name, StringComparison.OrdinalIgnoreCase));

    /// <summary>经验库的 key：优先 PackageFamily（MSIX 更稳定），退化到 exe 路径 + 窗口类。</summary>
    public static string KeyOf(string executable, string packageFamily, string windowClass)
    {
        var exe = (executable ?? "").ToLowerInvariant();
        if (!string.IsNullOrEmpty(packageFamily))
        {
            return $"pkg:{packageFamily.ToLowerInvariant()}";
        }
        return $"exe:{exe}|class:{windowClass}".ToLowerInvariant();
    }
}

/// <summary>一条可复用的操作路径（例如「计算器：按 7 → 按 + → 按 8 → 按 = → 读结果」）。</summary>
public sealed class WorkflowMemory
{
    public string Name { get; set; } = "";
    public string UpdatedAt { get; set; } = "";
    public int Uses { get; set; }
    public int Successes { get; set; }

    /// <summary>最近一次的期望值样例，便于下次做「经验是否过期」的粗判。</summary>
    public string? LastExpected { get; set; }
    public string? LastObserved { get; set; }

    public List<ElementMemory> Elements { get; set; } = new();
    public TimingMemory? Timings { get; set; }
}

/// <summary>
/// 一个元素的记忆。刻意**不含坐标**（坐标只允许作为 lastSeenRect 的调试参考，
/// 复用前必须用选择器重新命中）。
/// </summary>
public sealed class ElementMemory
{
    public string Role { get; set; } = "";
    public string Name { get; set; } = "";
    public string AutomationId { get; set; } = "";
    public string ControlType { get; set; } = "";
    public int[] Path { get; set; } = Array.Empty<int>();

    /// <summary>验证成功的执行路径：uia_invoke / uia_toggle / uia_value / wm_message / global_input。</summary>
    public string PreferredMethod { get; set; } = "";
    /// <summary>同一控件在不同版本里可能用不同 Pattern，按命中次数降序记录。</summary>
    public List<string> MethodHistory { get; set; } = new();

    public int OkCount { get; set; }
    public int FailCount { get; set; }
    public string LastSeenAt { get; set; } = "";

    /// <summary>仅供调试的观测矩形（物理像素），不参与定位。</summary>
    public double[]? LastSeenRect { get; set; }

    public Selector ToSelector()
    {
        if (!string.IsNullOrEmpty(AutomationId))
        {
            return new Selector { Kind = SelectorKind.AutomationId, Value = AutomationId };
        }
        if (Path.Length > 0)
        {
            return new Selector { Kind = SelectorKind.Path, PathParts = Path, Value = string.Join(",", Path) };
        }
        if (!string.IsNullOrEmpty(Name))
        {
            return new Selector { Kind = SelectorKind.Name, Value = Name };
        }
        return Selector.None;
    }
}

/// <summary>耗时画像。只记真实测量值；没有测量就不写这个对象。</summary>
public sealed class TimingMemory
{
    public double CaptureP50 { get; set; }
    public double CaptureP95 { get; set; }
    public double UiaLookupP50 { get; set; }
    public double UiaLookupP95 { get; set; }
    public double DispatchP50 { get; set; }
    public double DispatchP95 { get; set; }
    public double VerifyP50 { get; set; }
    public double VerifyP95 { get; set; }
    public double EndToEndP50 { get; set; }
    public double EndToEndP95 { get; set; }
    public int Samples { get; set; }
}

/// <summary>百分位工具（性能指标统一口径：P50/P95，样本不足时如实返回 0）。</summary>
public static class Percentile
{
    public static double P50(IEnumerable<double> values) => At(values, 0.50);
    public static double P95(IEnumerable<double> values) => At(values, 0.95);

    public static double At(IEnumerable<double> values, double q)
    {
        var arr = values.Where(v => !double.IsNaN(v)).OrderBy(v => v).ToArray();
        if (arr.Length == 0) return 0;
        if (arr.Length == 1) return arr[0];
        var pos = q * (arr.Length - 1);
        var lo = (int)Math.Floor(pos);
        var hi = (int)Math.Ceiling(pos);
        if (lo == hi) return arr[lo];
        var frac = pos - lo;
        return arr[lo] * (1 - frac) + arr[hi] * frac;
    }
}
