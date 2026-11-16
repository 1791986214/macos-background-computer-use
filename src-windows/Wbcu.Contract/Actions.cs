namespace Wbcu.Contract;

/// <summary>
/// 统一动作语义（与 macOS 引擎共用同一套概念名）。
///
/// 这些名字是「意图」，不是「实现」。两个引擎可以用完全不同的系统 API 完成
/// 同一个动作，但对外报出的 action 名、结果结构和验证口径必须一致，
/// 否则 WorkBuddy Skill 就得为每个平台写一套分支判断。
///
/// 命名刻意用 camelCase 的 endSession，与 SKILL.md 中的动作表逐字对应。
/// </summary>
public static class Actions
{
    public const string Launch = "launch";
    public const string Attach = "attach";
    public const string Inspect = "inspect";
    public const string Capture = "capture";
    public const string Click = "click";
    public const string Type = "type";
    public const string Scroll = "scroll";
    public const string Key = "key";
    public const string Verify = "verify";
    public const string Trace = "trace";
    public const string EndSession = "endSession";

    /// <summary>动作名全集，顺序即文档顺序。</summary>
    public static readonly string[] All =
    {
        Launch, Attach, Inspect, Capture, Click, Type, Scroll, Key, Verify, Trace, EndSession
    };

    /// <summary>该动作在给定平台是否可用。不可用时引擎必须报 not_supported，而不是假装成功。</summary>
    public static bool IsKnown(string? action) =>
        action is not null && Array.IndexOf(All, action) >= 0;
}

/// <summary>平台标识。契约里只允许这三个字面量。</summary>
public static class Platforms
{
    public const string Windows = "windows";
    public const string MacOS = "macos";
}

/// <summary>
/// 引擎标识。Skill 用它判断「这条结果是谁给的」，
/// 以及「同一个动作在两个平台的方法名可能不同」。
/// </summary>
public static class Engines
{
    public const string WindowsUia = "windows-uia";
    public const string MacOSAx = "macos-ax";
}

/// <summary>
/// 稳定错误码。区别于 failureReason（人话解释），错误码是给程序判断用的。
/// 新增码只能追加，不能改已有码的含义。
/// </summary>
public static class ErrorCodes
{
    public const string BadArgs = "bad_args";
    public const string AppNotFound = "app_not_found";
    public const string WindowNotFound = "window_not_found";
    public const string WindowMinimized = "window_minimized";
    public const string ProtectedWindow = "protected_window";
    public const string NoSession = "no_session";
    public const string SessionStale = "session_stale";
    public const string UiaUnavailable = "uia_unavailable";
    public const string ElementNotFound = "element_not_found";
    public const string PatternUnsupported = "uia_pattern_unsupported";
    public const string DeliverFailed = "deliver_failed";
    public const string CaptureUnavailable = "capture_unavailable";
    public const string CaptureFailed = "capture_failed";
    public const string PermissionDenied = "permission_denied";
    public const string NotSupported = "not_supported_on_platform";
    public const string Timeout = "timeout";
    public const string Internal = "internal_error";

    public static readonly string[] All =
    {
        BadArgs, AppNotFound, WindowNotFound, WindowMinimized, ProtectedWindow,
        NoSession, SessionStale, UiaUnavailable, ElementNotFound, PatternUnsupported,
        DeliverFailed, CaptureUnavailable, CaptureFailed, PermissionDenied,
        NotSupported, Timeout, Internal
    };
}
