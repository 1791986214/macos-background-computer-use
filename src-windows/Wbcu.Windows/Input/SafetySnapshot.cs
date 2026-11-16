using System.Runtime.InteropServices;
using Wbcu.Windows.Win32;

namespace Wbcu.Windows.Input;

/// <summary>
/// 「这次操作有没有打扰用户」的客观取证。
///
/// 这是本项目的核心承诺之一，所以它必须是**测量**出来的，不是声明出来的：
///   前台窗口变了吗？（GetForegroundWindow 前后对比）
///   真实鼠标动了吗？（GetCursorPos 前后对比）
///   期间有没有真实硬件输入？（GetLastInputInfo 的年龄）
/// 三个字段都允许是 null —— 表示「没测到」，绝不用 true 填充未知。
/// </summary>
public sealed class SafetySnapshot
{
    public IntPtr Foreground { get; private set; }
    public Native.POINT Cursor { get; private set; }
    public long LastInputAgeMs { get; private set; }

    public static SafetySnapshot Take()
    {
        Native.GetCursorPos(out var pt);
        return new SafetySnapshot
        {
            Foreground = Native.GetForegroundWindow(),
            Cursor = pt,
            LastInputAgeMs = Native.LastInputAgeMs(),
        };
    }

    /// <summary>前台窗口有没有被顶掉。</summary>
    public bool FrontAppPreserved()
    {
        var now = Native.GetForegroundWindow();
        return now == Foreground;
    }

    /// <summary>真实鼠标位置有没有被挪动（容差 0：我们连 1px 都不该动）。</summary>
    public bool CursorPreserved()
    {
        Native.GetCursorPos(out var now);
        return now.X == Cursor.X && now.Y == Cursor.Y;
    }

    public Dictionary<string, object?> ToJson(bool? frontPreserved, bool? cursorPreserved) => new()
    {
        ["foregroundBefore"] = "0x" + Foreground.ToInt64().ToString("X"),
        ["cursorBefore"] = new[] { Cursor.X, Cursor.Y },
        ["lastInputAgeMs"] = LastInputAgeMs,
        ["frontAppPreserved"] = frontPreserved,
        ["physicalCursorPreserved"] = cursorPreserved,
    };
}

/// <summary>
/// 一次投递的结果。字段口径与 macOS 的 ActionOutcome 一一对应：
///   delivered  事件有没有真的进到目标
///   changed    UI 有没有真的变（null = 没验证）
///   ok         最终裁决：验证优先，未验证时退化为 delivered
///   method     uia_invoke / uia_setvalue / wm_message / global_input
/// </summary>
public sealed class ActionOutcome
{
    public bool Ok { get; set; }
    public bool Delivered { get; set; }
    public bool? Changed { get; set; }
    public string Method { get; set; } = "none";
    public string FailureReason { get; set; } = "";
    public bool Escalated { get; set; }
    public string UiaError { get; set; } = "";
    public double DispatchMs { get; set; }
    public List<string> Notes { get; } = new();

    public static ActionOutcome Fail(string reason, string method = "none") => new()
    {
        Ok = false,
        Delivered = false,
        Method = method,
        FailureReason = reason,
    };
}

/// <summary>
/// Win32 全局输入注入（SendInput）。
///
/// 只在 `--allow-global` 显式授权时使用。理由：
/// SendInput 把事件写进**系统全局输入队列**，它会真的移动/点击用户的鼠标，
/// 也会进入用户当前正在用的任何窗口。它不是「虚拟鼠标」，
/// 把它当作后台操作的默认手段，就是在拿用户的输入当赌注。
/// </summary>
public static class GlobalInput
{
    private const uint INPUT_MOUSE = 0;
    private const uint INPUT_KEYBOARD = 1;

    private const uint MOUSEEVENTF_MOVE = 0x0001;
    private const uint MOUSEEVENTF_LEFTDOWN = 0x0002;
    private const uint MOUSEEVENTF_LEFTUP = 0x0004;
    private const uint MOUSEEVENTF_ABSOLUTE = 0x8000;
    private const uint MOUSEEVENTF_VIRTUALDESK = 0x4000;

    private const uint KEYEVENTF_KEYUP = 0x0002;

    [StructLayout(LayoutKind.Sequential)]
    private struct MOUSEINPUT
    {
        public int dx, dy;
        public uint mouseData, dwFlags, time;
        public IntPtr dwExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct KEYBDINPUT
    {
        public ushort wVk, wScan;
        public uint dwFlags, time;
        public IntPtr dwExtraInfo;
    }

    [StructLayout(LayoutKind.Explicit)]
    private struct InputUnion
    {
        [FieldOffset(0)] public MOUSEINPUT mi;
        [FieldOffset(0)] public KEYBDINPUT ki;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct INPUT
    {
        public uint type;
        public InputUnion U;
    }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint SendInput(uint count, INPUT[] inputs, int size);

    /// <summary>把真实光标移到屏幕坐标并点击。会挪动用户的鼠标——调用方必须已经拿到显式授权。</summary>
    public static bool Click(int screenX, int screenY)
    {
        var vx = GetSystemMetrics(76); // SM_XVIRTUALSCREEN
        var vy = GetSystemMetrics(77);
        var vw = GetSystemMetrics(78);
        var vh = GetSystemMetrics(79);
        if (vw <= 0 || vh <= 0) return false;

        var nx = (int)Math.Round((screenX - vx) * 65535.0 / Math.Max(1, vw - 1));
        var ny = (int)Math.Round((screenY - vy) * 65535.0 / Math.Max(1, vh - 1));

        var inputs = new[]
        {
            Mouse(MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK, nx, ny, 0),
            Mouse(MOUSEEVENTF_LEFTDOWN, 0, 0, 0),
            Mouse(MOUSEEVENTF_LEFTUP, 0, 0, 0),
        };
        return SendInput((uint)inputs.Length, inputs, Marshal.SizeOf<INPUT>()) == inputs.Length;
    }

    public static bool Key(ushort vk, bool up)
    {
        var inputs = new[] { KeyInput(vk, up) };
        return SendInput(1, inputs, Marshal.SizeOf<INPUT>()) == 1;
    }

    [DllImport("user32.dll")]
    private static extern int GetSystemMetrics(int index);

    private static INPUT Mouse(uint flags, int dx, int dy, uint data) => new()
    {
        type = INPUT_MOUSE,
        U = new InputUnion { mi = new MOUSEINPUT { dx = dx, dy = dy, mouseData = data, dwFlags = flags } },
    };

    private static INPUT KeyInput(ushort vk, bool up) => new()
    {
        type = INPUT_KEYBOARD,
        U = new InputUnion { ki = new KEYBDINPUT { wVk = vk, dwFlags = up ? KEYEVENTF_KEYUP : 0 } },
    };
}
