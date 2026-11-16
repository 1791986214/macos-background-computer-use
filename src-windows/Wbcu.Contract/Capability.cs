namespace Wbcu.Contract;

/// <summary>
/// 能力状态。这是本仓库最重要的一条纪律：
/// 没有实测数据支撑的能力，只能写 not_tested，不能写 supported。
/// </summary>
public static class FeatureStatus
{
    public const string Supported = "supported";
    public const string Partial = "partial";
    public const string Unsupported = "unsupported";
    /// <summary>代码已实现但尚未在真机上验证。发布说明里必须出现这个词。</summary>
    public const string NotTested = "not_tested";

    public static readonly string[] All = { Supported, Partial, Unsupported, NotTested };

    public static bool IsKnown(string? s) => s is not null && Array.IndexOf(All, s) >= 0;
}

/// <summary>跨平台共用的能力键名。两个平台报同一批 key，值可以不同。</summary>
public static class CapabilityKeys
{
    public const string UiaSemanticOps = "uia_semantic_ops";
    public const string BackgroundClick = "background_click";
    public const string BackgroundType = "background_type";
    public const string ForegroundFallback = "foreground_fallback";
    public const string WindowCapture = "window_capture";
    public const string MinimizedCapture = "minimized_window_capture";
    public const string GhostCursor = "ghost_cursor";
    public const string SessionReuse = "session_reuse";
    public const string ResultVerification = "result_verification";
    public const string ExperienceMemory = "experience_memory";
    public const string ActivationTrace = "activation_trace";
    public const string MultiMonitorDpi = "multi_monitor_dpi";
    public const string ElevatedTarget = "elevated_target";
    public const string ElectronApps = "electron_apps";
    public const string CustomDrawnUi = "custom_drawn_ui";

    public static readonly string[] All =
    {
        UiaSemanticOps, BackgroundClick, BackgroundType, ForegroundFallback, WindowCapture,
        MinimizedCapture, GhostCursor, SessionReuse, ResultVerification, ExperienceMemory,
        ActivationTrace, MultiMonitorDpi, ElevatedTarget, ElectronApps, CustomDrawnUi,
    };
}

public sealed class CapabilityItem
{
    public string Key { get; set; } = "";
    /// <summary>supported | partial | unsupported | not_tested</summary>
    public string Status { get; set; } = FeatureStatus.NotTested;
    /// <summary>实际用的系统能力名，例如 uia_invoke / wm_message / SendInput。</summary>
    public string Mechanism { get; set; } = "";
    public string Note { get; set; } = "";
}

public sealed class CapabilityReport
{
    public string Platform { get; set; } = Platforms.Windows;
    public string Engine { get; set; } = Engines.WindowsUia;
    public string EngineVersion { get; set; } = "";
    public string OsVersion { get; set; } = "";
    public string Arch { get; set; } = "";
    public List<CapabilityItem> Items { get; set; } = new();
    public List<string> Limits { get; set; } = new();

    public CapabilityItem? Get(string key) => Items.FirstOrDefault(i => i.Key == key);

    public CapabilityReport Add(string key, string status, string mechanism, string note)
    {
        Items.Add(new CapabilityItem { Key = key, Status = status, Mechanism = mechanism, Note = note });
        return this;
    }
}
