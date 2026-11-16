namespace Wbcu.Contract;

/// <summary>
/// 会话记录。两个平台同一结构，字段名一致；平台专属字段只在必要时新增且允许为空。
///
/// 会话的意义：一次解析（找到窗口 + 建好捕获 + 稳定 UIA 引用），全程复用。
/// 每点一次都重新枚举窗口/重建捕获，是 v0.4 之前最大的性能与干扰来源。
/// </summary>
public sealed class SessionRecord
{
    public string Id { get; set; } = "";
    public string Platform { get; set; } = Platforms.Windows;
    public string Engine { get; set; } = Engines.WindowsUia;

    // ---- 目标身份 ----
    public int Pid { get; set; }
    /// <summary>Windows: HWND 十进制串。仅运行时定位用，不写进长期经验。</summary>
    public string WindowHandle { get; set; } = "";
    public string Executable { get; set; } = "";
    public string AppName { get; set; } = "";
    /// <summary>UWP/MSIX 应用的 Package Family Name；Win32 应用为空。</summary>
    public string PackageFamily { get; set; } = "";
    public string AppVersion { get; set; } = "";
    public string WindowClass { get; set; } = "";
    public string Title { get; set; } = "";

    // ---- 几何 / DPI ----
    /// <summary>窗口物理像素矩形 x,y,w,h。</summary>
    public double[] Frame { get; set; } = Array.Empty<double>();
    public int Dpi { get; set; }
    public double Scale { get; set; } = 1.0;

    // ---- 生命周期 ----
    public string CreatedAt { get; set; } = "";
    public string LastUsedAt { get; set; } = "";
    public int Uses { get; set; }
    public string WindowState { get; set; } = "normal"; // normal | minimized | maximized

    // ---- 资源 ----
    public bool Ghost { get; set; }
    public bool CaptureActive { get; set; }
    public string GhostPipe { get; set; } = "";
    public string TraceFile { get; set; } = "";
    public string Workflow { get; set; } = "";
    public List<string> Notes { get; set; } = new();

    public bool IsUsable => Pid > 0 && !string.IsNullOrEmpty(WindowHandle);
}
