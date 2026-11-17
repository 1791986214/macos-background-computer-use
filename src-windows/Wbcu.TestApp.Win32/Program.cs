using System.Runtime.InteropServices;
using System.Text;

namespace Wbcu.TestApp.Win32;

/// <summary>
/// 受控测试目标（原生 Win32 / comctl32 控件）。
///
/// 为什么要有这个应用：
///   Third Hand 的每一次「点击成功」都必须能在**真实的 UI 状态变化**上被证实，
///   而不是靠 API 返回值。这个窗口提供一组可读、可验证的状态：
///     - 点击计数器（Button / 自绘画布各一个）
///     - 结果文本（Static，UIA 可读）
///     - 输入框、复选框、下拉框（覆盖 ValuePattern / TogglePattern / SelectionPattern）
///     - 滚动列表（覆盖 ScrollPattern）
///     - 操作日志（只读 Edit，能看到每一次真实收到的消息）
///
/// 它还是「窗口消息投递」这条降级路径的**唯一可信靶子**：
///   原生 BUTTON 既响应 UIA InvokePattern，也响应 WM_LBUTTONDOWN；
///   自绘画布窗口完全没有 UIA 语义，只能靠消息投递 —— 正好用来验证降级是否真的生效。
/// </summary>
internal static class Program
{
    private const string MainClass = "wbcu-testapp-main";
    private const string CanvasClass = "wbcu-testapp-canvas";

    private const int ID_BUTTON = 101;
    private const int ID_EDIT = 102;
    private const int ID_CHECK = 103;
    private const int ID_COMBO = 104;
    private const int ID_LIST = 105;
    private const int ID_RESULT = 106;
    private const int ID_LOG = 107;
    private const int ID_CANVAS = 108;

    private static IntPtr _hwndMain, _hwndCanvas, _hwndResult, _hwndLog;
    private static int _buttonClicks;
    private static int _canvasClicks;
    private static readonly List<string> LogLines = new();
    private static WndProcDelegate? _mainProc;
    private static WndProcDelegate? _canvasProc;

    private delegate IntPtr WndProcDelegate(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);

    [STAThread]
    private static void Main()
    {
        var hInstance = GetModuleHandle(null);
        _mainProc = MainWndProc;
        _canvasProc = CanvasWndProc;

        Register(MainClass, _mainProc, hInstance);
        Register(CanvasClass, _canvasProc, hInstance);

        _hwndMain = CreateWindowExW(0, MainClass, "wbcu 测试目标 (Win32)",
                                    WS_OVERLAPPEDWINDOW, 120, 120, 720, 560,
                                    IntPtr.Zero, IntPtr.Zero, hInstance, IntPtr.Zero);
        if (_hwndMain == IntPtr.Zero) return;

        ShowWindow(_hwndMain, SW_SHOW);
        UpdateWindow(_hwndMain);

        while (GetMessageW(out var msg, IntPtr.Zero, 0, 0) > 0)
        {
            TranslateMessage(ref msg);
            DispatchMessageW(ref msg);
        }
    }

    private static void Register(string cls, WndProcDelegate proc, IntPtr hInstance)
    {
        var wc = new WNDCLASSEX
        {
            cbSize = Marshal.SizeOf<WNDCLASSEX>(),
            lpfnWndProc = Marshal.GetFunctionPointerForDelegate(proc),
            hInstance = hInstance,
            hCursor = LoadCursorW(IntPtr.Zero, (IntPtr)32512),
            hbrBackground = (IntPtr)6, // COLOR_WINDOW+1
            lpszClassName = cls,
        };
        RegisterClassExW(ref wc);
    }

    private static IntPtr MainWndProc(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam)
    {
        switch (msg)
        {
            case WM_CREATE:
                BuildChildren(hWnd);
                AppendLog("窗口已创建");
                return IntPtr.Zero;

            case WM_COMMAND:
            {
                var id = wParam.ToInt32() & 0xFFFF;
                var code = (wParam.ToInt32() >> 16) & 0xFFFF;

                if (id == ID_BUTTON && code == 0 /* BN_CLICKED */)
                {
                    _buttonClicks++;
                    Refresh();
                    AppendLog($"按钮被点击 #{_buttonClicks}（真实 UI 事件）");
                }
                else if (id == ID_CHECK && code == 0)
                {
                    var state = SendMessageW((IntPtr)lParam, (uint)BM_GETCHECK, IntPtr.Zero, IntPtr.Zero);
                    AppendLog($"复选框状态 → {(state.ToInt64() == 1 ? "勾选" : "未勾选")}");
                }
                else if (id == ID_COMBO && code == 1 /* CBN_SELCHANGE */)
                {
                    var sel = SendMessageW((IntPtr)lParam, (uint)CB_GETCURSEL, IntPtr.Zero, IntPtr.Zero).ToInt64();
                    AppendLog($"下拉框选择 → 索引 {sel}");
                }
                else if (id == ID_EDIT && code == 0x0300 /* EN_CHANGE */)
                {
                    var len = GetWindowTextLengthW((IntPtr)lParam);
                    AppendLog($"输入框长度 → {len}");
                }
                return IntPtr.Zero;
            }

            case WM_DESTROY:
                PostQuitMessage(0);
                return IntPtr.Zero;
        }
        return DefWindowProcW(hWnd, msg, wParam, lParam);
    }

    private static IntPtr CanvasWndProc(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam)
    {
        switch (msg)
        {
            case WM_LBUTTONDOWN:
            {
                // 自绘画布：没有任何 UIA 语义，只能靠窗口消息命中。
                _canvasClicks++;
                Refresh();
                AppendLog($"画布收到 WM_LBUTTONDOWN #{_canvasClicks}");
                InvalidateRect(hWnd, IntPtr.Zero, true);
                return IntPtr.Zero;
            }
            case WM_PAINT:
            {
                var ps = new PAINTSTRUCT();
                var hdc = BeginPaint(hWnd, ref ps);
                var text = $"画布点击: {_canvasClicks}";
                TextOutW(hdc, 12, 12, text, text.Length);
                EndPaint(hWnd, ref ps);
                return IntPtr.Zero;
            }
            case WM_ERASEBKGND:
            {
                var hdc = (IntPtr)wParam;
                GetClientRect(hWnd, out var rc);
                var brush = CreateSolidBrush(0x00F0E8E0);
                FillRect(hdc, ref rc, brush);
                DeleteObject(brush);
                return (IntPtr)1;
            }
        }
        return DefWindowProcW(hWnd, msg, wParam, lParam);
    }

    private static void BuildChildren(IntPtr parent)
    {
        var hInstance = GetModuleHandle(null);
        var font = GetStockObject(DEFAULT_GUI_FONT);

        IntPtr Child(string cls, string text, int id, int x, int y, int w, int h, int style, int exStyle = 0)
        {
            var hwnd = CreateWindowExW(exStyle, cls, text, WS_CHILD | WS_VISIBLE | style,
                                       x, y, w, h, parent, (IntPtr)id, hInstance, IntPtr.Zero);
            SendMessageW(hwnd, (uint)WM_SETFONT, font, (IntPtr)1);
            return hwnd;
        }

        // 原生 BUTTON：既支持 UIA InvokePattern，也响应 WM_LBUTTONDOWN
        Child("BUTTON", "点我 (+1)", ID_BUTTON, 20, 20, 140, 34, BS_PUSHBUTTON);

        // 输入框：UIA ValuePattern 可后台写值
        Child("EDIT", "", ID_EDIT, 20, 70, 260, 30, ES_AUTOHSCROLL | ES_LEFT | WS_BORDER);

        // 复选框：UIA TogglePattern
        Child("BUTTON", "启用选项", ID_CHECK, 20, 115, 180, 28, BS_AUTOCHECKBOX);

        // 下拉框：UIA ExpandCollapse/Selection
        var combo = Child("COMBOBOX", "", ID_COMBO, 20, 155, 260, 220, CBS_DROPDOWNLIST | WS_VSCROLL);
        foreach (var item in new[] { "选项 A", "选项 B", "选项 C" })
        {
            SendMessageW(combo, (uint)CB_ADDSTRING, IntPtr.Zero, Marshal.StringToHGlobalUni(item));
        }
        SendMessageW(combo, (uint)CB_SETCURSEL, IntPtr.Zero, IntPtr.Zero);

        // 滚动列表：UIA ScrollPattern / 消息滚轮
        var list = Child("LISTBOX", "", ID_LIST, 310, 20, 360, 180, WS_BORDER | WS_VSCROLL | LBS_NOTIFY);
        for (var i = 1; i <= 40; i++)
        {
            SendMessageW(list, (uint)LB_ADDSTRING, IntPtr.Zero, Marshal.StringToHGlobalUni($"列表项 {i:00}"));
        }

        // 自绘画布：没有 UIA 语义，只能用消息投递验证
        _hwndCanvas = CreateWindowExW(WS_EX_CLIENTEDGE, CanvasClass, "", WS_CHILD | WS_VISIBLE,
                                      310, 215, 360, 80, parent, (IntPtr)ID_CANVAS, hInstance, IntPtr.Zero);
        SendMessageW(_hwndCanvas, (uint)WM_SETFONT, font, (IntPtr)1);

        // 结果区：验证读取的就是这个元素
        _hwndResult = Child("STATIC", "", ID_RESULT, 20, 215, 270, 28, SS_LEFT);

        // 日志区（只读多行 Edit）
        _hwndLog = CreateWindowExW(WS_EX_CLIENTEDGE, "EDIT", "",
                                   WS_CHILD | WS_VISIBLE | WS_VSCROLL | ES_MULTILINE | ES_READONLY | ES_AUTOVSCROLL,
                                   20, 310, 650, 190, parent, (IntPtr)ID_LOG, hInstance, IntPtr.Zero);
        SendMessageW(_hwndLog, (uint)WM_SETFONT, font, (IntPtr)1);

        Refresh();
    }

    /// <summary>把可验证状态写到 Static 上（UIA Name 会读到这段文字）。</summary>
    private static void Refresh()
    {
        var text = $"结果: 按钮={_buttonClicks} 画布={_canvasClicks}";
        SetWindowTextW(_hwndResult, text);
        SetWindowTextW(_hwndMain, $"wbcu 测试目标 (Win32) — 按钮={_buttonClicks} 画布={_canvasClicks}");
    }

    private static void AppendLog(string line)
    {
        if (LogLines.Count > 200) LogLines.RemoveAt(0);
        LogLines.Add($"{DateTime.Now:HH:mm:ss.fff} {line}");
        if (_hwndLog != IntPtr.Zero)
        {
            SetWindowTextW(_hwndLog, string.Join("\r\n", LogLines));
            var len = GetWindowTextLengthW(_hwndLog);
            SendMessageW(_hwndLog, (uint)EM_SETSEL, (IntPtr)len, (IntPtr)len);
        }
    }

    // ---------------- P/Invoke ----------------

    private const int WS_OVERLAPPEDWINDOW = 0x00CF0000;
    private const int WS_CHILD = 0x40000000;
    private const int WS_VISIBLE = 0x10000000;
    private const int WS_BORDER = 0x00800000;
    private const int WS_VSCROLL = 0x00200000;
    private const int WS_EX_CLIENTEDGE = 0x00000200;
    private const int ES_MULTILINE = 0x0004;
    private const int ES_READONLY = 0x0800;
    private const int ES_AUTOVSCROLL = 0x0040;
    private const int ES_AUTOHSCROLL = 0x0080;
    private const int ES_LEFT = 0x0000;
    private const int BS_PUSHBUTTON = 0x00000000;
    private const int BS_AUTOCHECKBOX = 0x00000003;
    private const int CBS_DROPDOWNLIST = 0x0003;
    private const int LBS_NOTIFY = 0x0001;
    private const int SS_LEFT = 0x00000000;
    private const int SW_SHOW = 5;
    private const uint WM_CREATE = 0x0001;
    private const uint WM_DESTROY = 0x0002;
    private const uint WM_COMMAND = 0x0111;
    private const uint WM_PAINT = 0x000F;
    private const uint WM_ERASEBKGND = 0x0014;
    private const uint WM_LBUTTONDOWN = 0x0201;
    private const uint WM_SETFONT = 0x0030;
    private const int DEFAULT_GUI_FONT = 17;
    private const int CB_ADDSTRING = 0x0143;
    private const int CB_SETCURSEL = 0x014E;
    private const int CB_GETCURSEL = 0x0147;
    private const int LB_ADDSTRING = 0x0180;
    private const int BM_GETCHECK = 0x00F0;
    private const int EM_SETSEL = 0x00B1;

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct WNDCLASSEX
    {
        public int cbSize;
        public uint style;
        public IntPtr lpfnWndProc;
        public int cbClsExtra, cbWndExtra;
        public IntPtr hInstance, hIcon, hCursor, hbrBackground;
        public string? lpszMenuName;
        public string lpszClassName;
        public IntPtr hIconSm;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct MSG
    {
        public IntPtr hwnd;
        public uint message;
        public IntPtr wParam, lParam;
        public uint time;
        public int x, y;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct RECT { public int Left, Top, Right, Bottom; }

    [StructLayout(LayoutKind.Sequential)]
    private struct PAINTSTRUCT
    {
        public IntPtr hdc;
        public int fErase;
        public RECT rcPaint;
        public int fRestore, fIncUpdate;
        public IntPtr rgbReserved0, rgbReserved1, rgbReserved2, rgbReserved3;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    private static extern IntPtr GetModuleHandle(string? name);

    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern ushort RegisterClassExW(ref WNDCLASSEX wc);

    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern IntPtr CreateWindowExW(int exStyle, string cls, string name, int style,
                                                 int x, int y, int w, int h,
                                                 IntPtr parent, IntPtr menu, IntPtr inst, IntPtr param);

    [DllImport("user32.dll")]
    private static extern bool ShowWindow(IntPtr hWnd, int cmd);

    [DllImport("user32.dll")]
    private static extern bool UpdateWindow(IntPtr hWnd);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetMessageW(out MSG msg, IntPtr hWnd, uint min, uint max);

    [DllImport("user32.dll")]
    private static extern bool TranslateMessage(ref MSG msg);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern IntPtr DispatchMessageW(ref MSG msg);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern IntPtr DefWindowProcW(IntPtr hWnd, uint msg, IntPtr w, IntPtr l);

    [DllImport("user32.dll")]
    private static extern void PostQuitMessage(int code);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern IntPtr SendMessageW(IntPtr hWnd, uint msg, IntPtr w, IntPtr l);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern bool SetWindowTextW(IntPtr hWnd, string text);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetWindowTextLengthW(IntPtr hWnd);

    [DllImport("user32.dll")]
    private static extern IntPtr LoadCursorW(IntPtr inst, IntPtr name);

    // GetStockObject 在 gdi32.dll，不是 user32.dll。
    // 声明错 DLL 不会编译报错，只会在启动时抛 EntryPointNotFoundException（真机回执里就是这么崩的）。
    [DllImport("gdi32.dll")]
    private static extern IntPtr GetStockObject(int id);

    [DllImport("user32.dll")]
    private static extern IntPtr BeginPaint(IntPtr hWnd, ref PAINTSTRUCT ps);

    [DllImport("user32.dll")]
    private static extern bool EndPaint(IntPtr hWnd, ref PAINTSTRUCT ps);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern bool TextOutW(IntPtr hdc, int x, int y, string s, int len);

    [DllImport("user32.dll")]
    private static extern bool GetClientRect(IntPtr hWnd, out RECT rc);

    [DllImport("user32.dll")]
    private static extern bool InvalidateRect(IntPtr hWnd, IntPtr rc, bool erase);

    [DllImport("gdi32.dll")]
    private static extern IntPtr CreateSolidBrush(int color);

    [DllImport("user32.dll")]
    private static extern int FillRect(IntPtr hdc, ref RECT rc, IntPtr brush);

    [DllImport("gdi32.dll")]
    private static extern bool DeleteObject(IntPtr obj);
}
