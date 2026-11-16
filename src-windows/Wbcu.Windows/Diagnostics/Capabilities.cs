using System.Runtime.InteropServices;
using Wbcu.Contract;
using Wbcu.Windows.Uia;

namespace Wbcu.Windows.Diagnostics;

/// <summary>
/// 能力矩阵（运行时探测版）。
///
/// 一套纪律：
///   1. 能在运行时探测的（UIA 是否可初始化、系统构建号是否支持 Graphics Capture）就探测。
///   2. 探测不了的（例如「后台点击在 Calculator 上到底成不成」）只能标 not_tested，
///      直到 GUI 测试套件在本机跑过并把结果写进 gui-verified.json。
///   3. 任何一项都不许因为「代码写完了」就标 supported。
/// </summary>
public static class Capabilities
{
    public static string Version => typeof(Capabilities).Assembly.GetName().Version?.ToString(3) ?? "0.6.0";
    public static string VerifiedFile => Path.Combine(Paths.Root, "gui-verified.json");

    public static CapabilityReport Build()
    {
        var osBuild = Environment.OSVersion.Version.Build;
        var verified = LoadVerified();

        var report = new CapabilityReport
        {
            Platform = Platforms.Windows,
            Engine = Engines.WindowsUia,
            EngineVersion = Version,
            OsVersion = $"{Environment.OSVersion.Version} (build {osBuild})",
            Arch = RuntimeInformation.ProcessArchitecture.ToString().ToLowerInvariant(),
        };

        var uiaOk = UiaThread.Instance.Available;
        var graphicsCapture = osBuild >= 18362; // Win10 1903+ 提供 Graphics Capture

        report.Add(CapabilityKeys.UiaSemanticOps,
            uiaOk ? StatusOrVerified(verified, "uia_semantic_ops", FeatureStatus.Supported) : FeatureStatus.Unsupported,
            "IUIAutomation (CUIAutomation8)",
            uiaOk ? "UIA 客户端已成功初始化；语义 Pattern 可用性取决于目标控件" : "UIA 初始化失败：" + UiaThread.Instance.InitError);

        report.Add(CapabilityKeys.BackgroundClick,
            StatusOrVerified(verified, "background_click", FeatureStatus.NotTested),
            "uia_invoke → wm_message",
            "语义 Pattern 优先；无 Pattern 时退化为窗口消息（是否能被消费取决于框架）");

        report.Add(CapabilityKeys.BackgroundType,
            StatusOrVerified(verified, "background_type", FeatureStatus.NotTested),
            "uia_setvalue → WM_CHAR",
            "ValuePattern 可后台写值；WM_CHAR 只在部分控件生效");

        report.Add(CapabilityKeys.ForegroundFallback,
            FeatureStatus.Unsupported,
            "SendInput（仅 --allow-global）",
            "默认不启用：全局注入会移动真实鼠标并进入用户前台窗口");

        report.Add(CapabilityKeys.WindowCapture,
            graphicsCapture ? StatusOrVerified(verified, "window_capture", FeatureStatus.Partial) : FeatureStatus.Partial,
            graphicsCapture ? "windows_graphics_capture + printwindow" : "printwindow",
            graphicsCapture
                ? "Graphics Capture 需要 Win10 1903+；受保护内容与最小化窗口无法取帧，失败时自动退回 PrintWindow"
                : "当前系统低于 1903，只能用 PrintWindow（同步 GDI，可能拿到空白）");

        report.Add(CapabilityKeys.MinimizedCapture, FeatureStatus.Unsupported, "none",
            "最小化窗口没有 DWM 合成表面，任何后端都取不到画面");

        report.Add(CapabilityKeys.GhostCursor,
            StatusOrVerified(verified, "ghost_cursor", FeatureStatus.Supported),
            "WS_EX_LAYERED + UpdateLayeredWindow",
            "独立进程；NOACTIVATE/TRANSPARENT/TOOLWINDOW，点击穿透且不抢前台");

        report.Add(CapabilityKeys.SessionReuse,
            FeatureStatus.Supported, "session json + hwnd pid 校验",
            "会话失效（句柄被复用/进程退出）会明确报 session_stale，不会拿着死句柄硬点");

        report.Add(CapabilityKeys.ResultVerification,
            FeatureStatus.Supported, "uia_state + fingerprint",
            "四分类：success / already_satisfied / failure / inconclusive（与 macOS 同一套判据）");

        report.Add(CapabilityKeys.ExperienceMemory,
            FeatureStatus.Supported, "semantic selector only",
            "只存 AutomationId/路径/名称；HWND 与坐标不进长期库");

        report.Add(CapabilityKeys.ActivationTrace,
            FeatureStatus.Supported, "SetWinEventHook(EVENT_SYSTEM_FOREGROUND)",
            "事件驱动；按命令时间窗归因");

        report.Add(CapabilityKeys.MultiMonitorDpi,
            StatusOrVerified(verified, "multi_monitor_dpi", FeatureStatus.NotTested),
            "PerMonitorV2 manifest + GetDpiForWindow",
            "代码按物理像素 + per-monitor DPI 处理；混合 DPI 实机未验收");

        report.Add(CapabilityKeys.ElevatedTarget,
            StatusOrVerified(verified, "elevated_target", FeatureStatus.Partial),
            "asInvoker + UIAccess=false",
            "目标进程权限更高时 UIA/消息投递会被 UIPI 挡住；本工具不做提权绕过，会如实报 permission_denied");

        report.Add(CapabilityKeys.ElectronApps,
            StatusOrVerified(verified, "electron_apps", FeatureStatus.Partial),
            "uia (Chromium accessibility)",
            "Electron 默认关闭无障碍树；未开启时只能退化为窗口消息，成功率不保证");

        report.Add(CapabilityKeys.CustomDrawnUi,
            StatusOrVerified(verified, "custom_drawn_ui", FeatureStatus.Partial),
            "wm_message / global_input",
            "自绘界面没有 UIA 语义，只能按坐标投递消息；是否被消费取决于实现");

        report.Limits.Add("本机若未跑过 GUI 测试套件，标注 not_tested 的项目请在真机验证后再对外宣称支持");
        report.Limits.Add("Windows Server / 无交互桌面会话下，UIA 与窗口消息行为会退化，不在支持范围");
        return report;
    }

    private static string StatusOrVerified(Dictionary<string, string> verified, string key, string fallback)
    {
        if (verified.TryGetValue(key, out var s) && FeatureStatus.IsKnown(s)) return s;
        return fallback;
    }

    /// <summary>GUI 测试套件跑完后写盘的本机验证结果。没有这个文件就说明「还没在真机验过」。</summary>
    public static Dictionary<string, string> LoadVerified()
    {
        var dict = new Dictionary<string, string>();
        try
        {
            if (!File.Exists(VerifiedFile)) return dict;
            var parsed = Json.Deserialize<Dictionary<string, string>>(File.ReadAllText(VerifiedFile));
            if (parsed != null) dict = parsed;
        }
        catch { }
        return dict;
    }

    public static void SaveVerified(Dictionary<string, string> results)
    {
        results["__updatedAt"] = DateTime.UtcNow.ToString("O");
        results["__osBuild"] = Environment.OSVersion.Version.Build.ToString();
        File.WriteAllText(VerifiedFile, Json.Serialize(results, pretty: true));
    }
}
