using System.Collections.Concurrent;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Text;
using Wbcu.Contract;
using Wbcu.Windows.Discovery;
using Wbcu.Windows.Win32;

namespace Wbcu.Windows.Ghost;

/// <summary>
/// Ghost Cursor 覆盖层进程。
///
/// 窗口样式组合（每一条都是必需的，少一条就出问题）：
///   WS_EX_LAYERED     —— 逐像素 alpha（UpdateLayeredWindow 的前提）
///   WS_EX_TRANSPARENT —— 鼠标命中穿透，用户点不到它
///   WS_EX_NOACTIVATE  —— 点击不激活，绝不抢前台
///   WS_EX_TOOLWINDOW  —— 不出现在 Alt+Tab / 任务栏
///   WS_EX_TOPMOST     —— 浮在常规窗口之上（但不会激活任何东西）
///
/// 它只是"显示"。真实点击由引擎的 TargetedInput 负责，
/// 这里的动画永远不会影响一次操作的成功判定。
/// </summary>
public sealed class GhostDaemon
{
    private const uint WM_APP_OP = 0x8001;
    private const uint WM_APP_QUIT = 0x8002;
    private const uint TimerId = 1;
    private const int TickMs = 33;

    private readonly string _pipeName;
    private readonly string _sessionId;
    private IntPtr _targetHwnd;

    private readonly ConcurrentQueue<string> _ops = new();
    private readonly GhostState _state = new();

    private LayeredOverlay? _overlay;

    private GhostDaemon(string pipeName, string hwndHex, string sessionId)
    {
        _pipeName = pipeName;
        _sessionId = sessionId;
        WindowEnumerator.TryParseHwnd(hwndHex, out var h);
        _targetHwnd = h;
    }

    public static int Run(string pipeName, string hwndHex, string sessionId)
    {
        var daemon = new GhostDaemon(pipeName, hwndHex, sessionId);
        return daemon.Loop();
    }

    private int Loop()
    {
        // 按目标窗口的 DPI 决定位图边长：126pt 在 200% 缩放下应渲染成 252px，
        // 否则高 DPI 屏幕上这枚光标只有半个指甲盖大。
        _state.Scale = ScaleOf(_targetHwnd);

        _overlay = new LayeredOverlay();
        if (!_overlay.Create(_state.SizePx))
        {
            Console.Error.WriteLine("ghost daemon: 创建覆盖层窗口失败");
            return 3;
        }
        _overlay.GhostTick = OnTick;

        WritePidFile();

        // 管道服务线程：只负责收行 → 入队 → 唤醒 UI 线程
        var pipeThread = new Thread(PipeLoop) { IsBackground = true, Name = "wbcu-ghost-pipe" };
        pipeThread.Start();

        Native.SetTimer(_overlay.Hwnd, (UIntPtr)TimerId, TickMs, IntPtr.Zero);
        Render(); // 先把光标画出来（默认在窗口左上角附近）

        while (Native.GetMessageW(out var msg, IntPtr.Zero, 0, 0) > 0)
        {
            Native.TranslateMessage(ref msg);
            Native.DispatchMessageW(ref msg);
            if (msg.message == WM_APP_QUIT) break;
        }

        try { File.Delete(GhostClient.PidFile(_pipeName)); } catch { }
        _overlay.Dispose();
        return 0;
    }

    private static double ScaleOf(IntPtr hwnd)
    {
        try
        {
            if (hwnd != IntPtr.Zero && Native.IsWindow(hwnd))
            {
                var dpi = (int)Native.GetDpiForWindow(hwnd);
                if (dpi > 0) return dpi / 96.0;
            }
        }
        catch { }
        return 1.0;
    }

    private void WritePidFile()
    {
        try
        {
            File.WriteAllText(GhostClient.PidFile(_pipeName), Environment.ProcessId.ToString());
        }
        catch { }
    }

    private void PipeLoop()
    {
        while (true)
        {
            try
            {
                using var server = new NamedPipeServerStream(_pipeName, PipeDirection.InOut, 1,
                    PipeTransmissionMode.Byte, PipeOptions.None);
                server.WaitForConnection();

                using var reader = new StreamReader(server, new UTF8Encoding(false), false, 4096, leaveOpen: true);
                using var writer = new StreamWriter(server, new UTF8Encoding(false), 4096, leaveOpen: true) { AutoFlush = true };

                while (server.IsConnected)
                {
                    var line = reader.ReadLine();
                    if (line == null) break;
                    _ops.Enqueue(line);
                    if (_overlay != null) Native.PostMessageW(_overlay.Hwnd, WM_APP_OP, IntPtr.Zero, IntPtr.Zero);

                    // 立即回执：说明"已收到"，不代表"已画完"
                    writer.WriteLine("{\"ok\":true,\"queued\":true}");
                }
            }
            catch
            {
                Thread.Sleep(120);
            }
        }
    }

    private void DrainOps()
    {
        while (_ops.TryDequeue(out var line))
        {
            HandleOp(line);
        }
    }

    private void HandleOp(string line)
    {
        try
        {
            using var doc = System.Text.Json.JsonDocument.Parse(line);
            var root = doc.RootElement;
            var op = root.TryGetProperty("op", out var opEl) ? opEl.GetString() ?? "" : "";

            switch (op)
            {
                case "move":
                    _state.RelX = GetDouble(root, "x", _state.RelX);
                    _state.RelY = GetDouble(root, "y", _state.RelY);
                    _state.Visible = true;
                    Render();
                    break;

                case "click":
                    _state.ClickStart = Environment.TickCount64;
                    _state.Visible = true;
                    Render();
                    break;

                case "hide":
                    _state.Visible = false;
                    _overlay?.Hide();
                    break;

                case "bind":
                    if (root.TryGetProperty("hwnd", out var h) && h.GetString() is { } hex)
                    {
                        WindowEnumerator.TryParseHwnd(hex, out var nh);
                        _targetHwnd = nh;
                    }
                    break;

                case "stop":
                    if (_overlay != null) Native.PostMessageW(_overlay.Hwnd, WM_APP_QUIT, IntPtr.Zero, IntPtr.Zero);
                    Native.PostQuitMessage(0);
                    break;

                case "status":
                    break;
            }
        }
        catch
        {
            // 坏消息不致命：覆盖层是纯显示，不该因为一行坏 JSON 就崩
        }
    }

    private static double GetDouble(System.Text.Json.JsonElement root, string name, double fallback) =>
        root.TryGetProperty(name, out var el) && el.TryGetDouble(out var v) ? v : fallback;

    private void OnTick()
    {
        DrainOps();

        if (!_state.Visible) return;

        // 点击动画：260ms 内显示扩散环
        var clicking = _state.ClickStart > 0 && Environment.TickCount64 - _state.ClickStart < 260;
        Render(clicking ? (_state.ClickStart) : 0);
    }

    private void Render(long clickStart = 0)
    {
        if (_overlay == null) return;

        var size = _state.SizePx;

        // 目标窗口还在就跟随（窗口移动/缩放时光标一起动）
        int sx = (int)Math.Round(_state.RelX), sy = (int)Math.Round(_state.RelY);
        if (_targetHwnd != IntPtr.Zero && Native.IsWindow(_targetHwnd))
        {
            var frame = WindowEnumerator.FrameOf(_targetHwnd);
            sx = frame.Left + (int)Math.Round(_state.RelX);
            sy = frame.Top + (int)Math.Round(_state.RelY);

            // 被别的窗口压住时变淡（不是隐藏，用户仍能看到"AI 在哪儿"，但不会误以为是自己的鼠标）
            var onTop = WindowEnumerator.IsPointOnWindow(_targetHwnd, sx, sy);
            _state.Alpha = onTop ? 235 : 70;
        }

        var cursor = CursorRaster.RenderCursor(size);
        if (clickStart > 0)
        {
            var progress = Math.Clamp((Environment.TickCount64 - clickStart) / 260.0, 0, 1);
            var ring = CursorRaster.RenderClickRing(size, progress);
            cursor = Composite(cursor, ring, size);
        }

        _overlay.SetPixels(cursor, size, size);
        _overlay.Present(sx, sy, size, size, (byte)Math.Clamp(_state.Alpha, 0, 255));
    }

    private static byte[] Composite(byte[] bottom, byte[] top, int size)
    {
        var outBuf = new byte[bottom.Length];
        for (var i = 0; i < bottom.Length; i += 4)
        {
            var ta = top[i + 3] / 255.0;
            var ba = bottom[i + 3] / 255.0;
            var oa = ta + ba * (1 - ta);
            if (oa <= 0) continue;
            for (var c = 0; c < 3; c++)
            {
                var tv = top[i + c] / 255.0;
                var bv = bottom[i + c] / 255.0;
                outBuf[i + c] = (byte)Math.Clamp((tv + bv * (1 - ta)) / oa * 255.0, 0, 255);
            }
            outBuf[i + 3] = (byte)Math.Clamp(oa * 255.0, 0, 255);
        }
        return outBuf;
    }

    private sealed class GhostState
    {
        public double RelX { get; set; } = 40;
        public double RelY { get; set; } = 40;
        public bool Visible { get; set; } = true;
        public long ClickStart { get; set; }
        public int Alpha { get; set; } = 235;
        /// <summary>DPI 缩放系数（96 DPI = 1.0）。</summary>
        public double Scale { get; set; } = 1.0;
        /// <summary>126 pt × 缩放；高 DPI 下自动放大，保持视觉尺寸一致。</summary>
        public int SizePx => Math.Clamp((int)Math.Round(126 * Scale), 64, 512);
    }
}

/// <summary>
/// 分层窗口（UpdateLayeredWindow）的最小实现。
/// 不用 WPF / WinForms：一个覆盖层不需要整套 UI 框架，直接用 GDI DIB 更快、更可控。
/// </summary>
public sealed class LayeredOverlay : IDisposable
{
    private const string ClassName = "wbcu-ghost-overlay";

    private IntPtr _hwnd;
    private IntPtr _memDc;
    private IntPtr _dib;
    private IntPtr _bits;
    private int _w, _h;
    private GhostDaemonWndProc? _proc;

    private delegate IntPtr GhostDaemonWndProc(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);

    public IntPtr Hwnd => _hwnd;

    public bool Create(int sizePx)
    {
        _proc = WndProcImpl;
        var fnPtr = Marshal.GetFunctionPointerForDelegate(_proc);
        var hInstance = Native.GetModuleHandleW(null);

        var wc = new Native.WNDCLASSEX
        {
            cbSize = Marshal.SizeOf<Native.WNDCLASSEX>(),
            style = 0,
            lpfnWndProc = fnPtr,
            hInstance = hInstance,
            lpszClassName = ClassName,
        };

        var atom = Native.RegisterClassExW(ref wc);
        if (atom == 0)
        {
            // 已注册（第二次启动）不是错误
            var err = Marshal.GetLastWin32Error();
            if (err != 1410) return false;
        }

        var exStyle = Native.WS_EX_LAYERED | Native.WS_EX_TRANSPARENT | Native.WS_EX_NOACTIVATE
                      | Native.WS_EX_TOOLWINDOW | Native.WS_EX_TOPMOST;

        _hwnd = Native.CreateWindowExW(exStyle, ClassName, "wbcu-ghost", Native.WS_POPUP,
                                       0, 0, sizePx, sizePx,
                                       IntPtr.Zero, IntPtr.Zero, hInstance, IntPtr.Zero);
        if (_hwnd == IntPtr.Zero) return false;

        if (!CreateDib(sizePx)) return false;

        Native.ShowWindow(_hwnd, Native.SW_SHOWNOACTIVATE);
        return true;
    }

    private bool CreateDib(int sizePx)
    {
        _memDc = Native.CreateCompatibleDC(IntPtr.Zero);
        if (_memDc == IntPtr.Zero) return false;

        var bmi = new Native.BITMAPINFOHEADER
        {
            biSize = Marshal.SizeOf<Native.BITMAPINFOHEADER>(),
            biWidth = sizePx,
            biHeight = -sizePx,
            biPlanes = 1,
            biBitCount = 32,
            biCompression = (int)Native.BI_RGB,
        };

        _dib = Native.CreateDIBSection(_memDc, ref bmi, Native.DIB_RGB_COLORS, out _bits, IntPtr.Zero, 0);
        if (_dib == IntPtr.Zero) return false;

        Native.SelectObject(_memDc, _dib);
        _w = _h = sizePx;
        return true;
    }

    public void SetPixels(byte[] bgra, int w, int h)
    {
        if (_bits == IntPtr.Zero) return;
        if (w != _w || h != _h)
        {
            try { Native.DeleteObject(_dib); } catch { }
            Native.DeleteDC(_memDc);
            _memDc = IntPtr.Zero;
            CreateDib(Math.Max(w, h));
        }
        var copy = Math.Min(bgra.Length, w * h * 4);
        Marshal.Copy(bgra, 0, _bits, copy);
    }

    public void Present(int screenX, int screenY, int w, int h, byte alpha)
    {
        if (_hwnd == IntPtr.Zero) return;

        var dst = new Native.POINT(screenX, screenY);
        var size = new Native.SIZE(w, h);
        var src = new Native.POINT(0, 0);
        var blend = new Native.BLENDFUNCTION
        {
            BlendOp = 0,               // AC_SRC_OVER
            BlendFlags = 0,
            SourceConstantAlpha = alpha,
            AlphaFormat = Native.AC_SRC_ALPHA,
        };

        Native.UpdateLayeredWindow(_hwnd, IntPtr.Zero, ref dst, ref size, _memDc, ref src, 0, ref blend, Native.ULW_ALPHA);
    }

    public void Hide()
    {
        if (_hwnd != IntPtr.Zero) Native.ShowWindow(_hwnd, Native.SW_HIDE);
    }

    private IntPtr WndProcImpl(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam)
    {
        const uint WM_TIMER = 0x0113;

        if (msg == WM_TIMER)
        {
            GhostTick?.Invoke();
            return IntPtr.Zero;
        }
        if (msg == 0x8001) // WM_APP_OP
        {
            GhostTick?.Invoke();
            return IntPtr.Zero;
        }
        if (msg == 0x0010) // WM_CLOSE
        {
            Native.PostQuitMessage(0);
            return IntPtr.Zero;
        }
        return Native.DefWindowProcW(hWnd, msg, wParam, lParam);
    }

    /// <summary>由 GhostDaemon 挂上的每帧回调（33ms）。</summary>
    public Action? GhostTick { get; set; }

    public void Dispose()
    {
        if (_hwnd != IntPtr.Zero)
        {
            Native.KillTimer(_hwnd, (UIntPtr)1);
            Native.DestroyWindow(_hwnd);
            _hwnd = IntPtr.Zero;
        }
        if (_dib != IntPtr.Zero) { Native.DeleteObject(_dib); _dib = IntPtr.Zero; }
        if (_memDc != IntPtr.Zero) { Native.DeleteDC(_memDc); _memDc = IntPtr.Zero; }
    }
}
