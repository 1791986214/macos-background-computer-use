using System.Diagnostics;
using System.Runtime.InteropServices;
using Vortice.Direct3D;
using Vortice.Direct3D11;
using Windows.Graphics.Capture;
using Windows.Graphics.DirectX;
using Windows.Graphics.DirectX.Direct3D11;
using WinRT;
using Wbcu.Windows.Discovery;
using Wbcu.Windows.Win32;

namespace Wbcu.Windows.Capture;

/// <summary>
/// **持久窗口捕获会话**（Persistent Capture Session）。
///
/// 和 <see cref="WindowCapture.GraphicsCaptureBackend.Once"/> 的区别：
///
///   旧路径：每调一次 capture → 建 D3D 设备 + 帧池 + 会话 → 同步忙等最多 1500ms 拿一帧 → 全部销毁。
///           连续截图时每秒重建十几次会话，既慢又容易让目标窗口闪烁。
///
///   本类：绑定 HWND 建一次会话，之后由 DWM 持续推帧；<c>Snapshot()</c> 直接返回内存里的最新帧
///         （Latest Frame Wins），不做任何 D3D 往返。只有首帧需要等。
///
/// 关键约束（都是踩过坑的）：
///   - 用 <c>CreateFreeThreaded</c>：帧回调不在 UI 线程，绝不能碰 UI 线程的消息循环。
///   - 读回降采样到 30fps：DWM 可能推 60fps，每帧都 Map 一次 staging 纹理纯属浪费。
///   - 读回串行化：D3D11 immediate context 不是线程安全的，多线程回调必须加锁。
///   - 尺寸变化要 Recreate 帧池，否则拿到的是旧尺寸画面。
///   - 会话与前台窗口完全无关：用户切窗口、遮挡、最小化都不改变捕获对象（最小化时 DWM 无合成表面，会如实报无帧）。
/// </summary>
internal sealed class LiveCapture : IDisposable
{
    /// <summary>读回节流：最多 30fps。DWM 40/60fps 推帧时不必每帧都读。</summary>
    private const int MinReadbackIntervalMs = 33;

    private readonly IntPtr _hwnd;
    private readonly ID3D11Device _device;
    private readonly ID3D11DeviceContext _context;
    private readonly IDirect3DDevice _winrtDevice;
    private readonly Direct3D11CaptureFramePool _pool;
    private readonly GraphicsCaptureSession _session;

    private readonly object _gate = new();
    private byte[] _latest = Array.Empty<byte>();
    private int _width;
    private int _height;
    private long _stampMs;
    private long _lastReadbackMs;
    private long _lastAccessMs = Environment.TickCount64;
    private int _frameCount;
    private int _droppedByThrottle;
    private string? _lastError;
    private Thread? _pump;
    private volatile bool _disposed;

    /// <summary>会话代号：每新建一个捕获流就 +1，用于区分「仍在同一路流」和「重建过」。</summary>
    private static long _generationSeed;
    public long Generation { get; }

    private LiveCapture(IntPtr hwnd, ID3D11Device device, ID3D11DeviceContext context,
                        IDirect3DDevice winrtDevice, Direct3D11CaptureFramePool pool,
                        GraphicsCaptureSession session)
    {
        _hwnd = hwnd;
        _device = device;
        _context = context;
        _winrtDevice = winrtDevice;
        _pool = pool;
        _session = session;
        Generation = Interlocked.Increment(ref _generationSeed);
    }

    public IntPtr Hwnd => _hwnd;
    public int FrameCount => _frameCount;
    public string? LastError => _lastError;
    public long IdleMs => Environment.TickCount64 - _lastAccessMs;

    /// <summary>为目标 HWND 建立会话并等首帧。失败时抛异常，由调用方决定是否降级。</summary>
    public static LiveCapture Start(IntPtr hwnd, int firstFrameTimeoutMs = 800)
    {
        var item = WindowCapture.GraphicsCaptureBackend.CreateItem(hwnd);

        D3D11.D3D11CreateDevice(
            null, DriverType.Hardware, DeviceCreationFlags.BgraSupport,
            new[] { FeatureLevel.Level_11_0, FeatureLevel.Level_10_1, FeatureLevel.Level_10_0 },
            out ID3D11Device device, out ID3D11DeviceContext context);

        if (device == null) throw new InvalidOperationException("D3D11 设备创建失败");

        IDirect3DDevice? winrtDevice = null;
        Direct3D11CaptureFramePool? pool = null;
        GraphicsCaptureSession? session = null;

        try
        {
            winrtDevice = WindowCapture.GraphicsCaptureBackend.CreateWinRtDevice(device);
            var size = item.Size;
            pool = Direct3D11CaptureFramePool.CreateFreeThreaded(
                winrtDevice, DirectXPixelFormat.B8G8R8A8UIntNormalized, 2, size);
            session = pool.CreateCaptureSession(item);

            // 关掉捕获边框（Win11 22H2+ 才有，属性不存在就算了）
            try
            {
                var prop = session.GetType().GetProperty("IsBorderRequired");
                prop?.SetValue(session, false);
            }
            catch { }
            try { session.IsCursorCaptureEnabled = false; } catch { }

            var live = new LiveCapture(hwnd, device, context, winrtDevice, pool, session);
            session.StartCapture();
            live.StartPump();

            // 等首帧（只有第一次需要）
            var sw = Stopwatch.StartNew();
            while (sw.ElapsedMilliseconds < firstFrameTimeoutMs)
            {
                if (live.FrameCount > 0) return live;
                Thread.Sleep(8);
            }

            live.Dispose();
            throw new TimeoutException($"首帧超时（{firstFrameTimeoutMs}ms）：窗口可能最小化、被 DWM 挂起或为受保护内容");
        }
        catch
        {
            try { session?.Dispose(); } catch { }
            try { pool?.Dispose(); } catch { }
            try { context?.Dispose(); } catch { }
            try { device?.Dispose(); } catch { }
            throw;
        }
    }

    /// <summary>
    /// 独立泵线程：持续 TryGetNextFrame → 降采样读回 → 覆盖最新帧。
    /// 用泵线程而不是 FrameArrived 事件，理由：
    ///   - 事件参数类型在 CsWinRT 投影下名字不稳定，跨 SDK 版本容易编不过；
    ///   - 泵线程可以精确控制节奏（不需要的帧直接丢），也不会把回调线程卡住。
    /// FreeThreaded 帧池本来就允许跨线程 TryGetNextFrame。
    /// </summary>
    private void StartPump()
    {
        _pump = new Thread(PumpLoop)
        {
            IsBackground = true,
            Name = "wbcu-live-capture",
            Priority = ThreadPriority.BelowNormal,
        };
        _pump.Start();
    }

    private void PumpLoop()
    {
        while (!_disposed)
        {
            Direct3D11CaptureFrame? frame = null;
            try
            {
                frame = _pool.TryGetNextFrame();
            }
            catch (Exception ex)
            {
                _lastError = ex.GetType().Name + ": " + ex.Message;
            }

            if (frame == null)
            {
                Thread.Sleep(12);
                continue;
            }

            try
            {
                var now = Environment.TickCount64;
                if (now - _lastReadbackMs < MinReadbackIntervalMs)
                {
                    Interlocked.Increment(ref _droppedByThrottle);
                    continue;
                }

                var content = frame.ContentSize;
                if (content.Width > 0 && content.Height > 0 &&
                    (content.Width != _width || content.Height != _height))
                {
                    try
                    {
                        _pool.Recreate(_winrtDevice, DirectXPixelFormat.B8G8R8A8UIntNormalized, 2, content);
                    }
                    catch { }
                }

                CaptureResult read;
                lock (_gate)
                {
                    _lastReadbackMs = now;
                    try
                    {
                        read = WindowCapture.GraphicsCaptureBackend.ReadbackFrame(frame, _device, _context);
                    }
                    catch (Exception ex)
                    {
                        _lastError = ex.GetType().Name + ": " + ex.Message;
                        continue;
                    }

                    if (read.Ok && read.Bgra.Length > 0)
                    {
                        _latest = read.Bgra;
                        _width = read.Width;
                        _height = read.Height;
                        _stampMs = now;
                        _frameCount++;
                    }
                }
            }
            finally
            {
                frame.Dispose();
            }
        }
    }

    /// <summary>
    /// 取最新帧。新鲜（age ≤ maxAgeMs）直接返回，0 等待；否则最多等 waitMs 等新帧。
    /// 拿不到就返回 null——**绝不回退去截前台窗口**。
    /// </summary>
    public CaptureResult? Snapshot(int maxAgeMs = 800, int waitMs = 250)
    {
        _lastAccessMs = Environment.TickCount64;

        if (TryTakeFresh(maxAgeMs, out var hit)) return hit;

        var sw = Stopwatch.StartNew();
        while (sw.ElapsedMilliseconds < waitMs)
        {
            Thread.Sleep(10);
            if (TryTakeFresh(maxAgeMs, out hit)) return hit;
        }

        return null;
    }

    private bool TryTakeFresh(int maxAgeMs, out CaptureResult result)
    {
        lock (_gate)
        {
            var age = Environment.TickCount64 - _stampMs;
            if (_frameCount > 0 && _latest.Length > 0 && age <= maxAgeMs)
            {
                result = BuildResult(age, stale: false);
                return true;
            }
        }
        result = null!;
        return false;
    }

    /// <summary>组装带帧身份的捕获结果（目标句柄、帧号、帧龄、会话代号）。</summary>
    private CaptureResult BuildResult(long ageMs, bool stale)
    {
        var pid = 0;
        try
        {
            Native.GetWindowThreadProcessId(_hwnd, out var p);
            pid = (int)p;
        }
        catch { }

        var r = new CaptureResult
        {
            Ok = true,
            Method = "graphics_capture_live",
            Bgra = _latest,
            Width = _width,
            Height = _height,
            Ms = 0,
            TargetHwnd = "0x" + _hwnd.ToInt64().ToString("X"),
            TargetPid = pid,
            FrameId = _frameCount,
            FrameTimestamp = DateTime.Now.AddMilliseconds(-ageMs).ToString("o"),
            FrameAgeMs = ageMs,
            CaptureGeneration = Generation,
            IsStale = stale,
            Dpi = 96,
        };
        r.Warnings.Add($"持久会话 #{_frameCount} 帧，帧龄 {ageMs}ms，generation={Generation}");
        return r;
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;

        try { _pump?.Join(400); } catch { }
        try { _session.Dispose(); } catch { }
        try { _pool.Dispose(); } catch { }
        try { _context.Dispose(); } catch { }
        try { _device.Dispose(); } catch { }
    }
}

/// <summary>
/// 会话注册表：一个 HWND 一个会话，跨命令复用。空闲过久自动回收，避免占着 GPU 资源。
/// </summary>
internal static class LiveCaptureRegistry
{
    private static readonly Dictionary<IntPtr, LiveCapture> Map = new();
    private static readonly object Gate = new();

    /// <summary>空闲超过该时长的会话会被回收（不影响任务：下次会自动重建）。</summary>
    public const int IdleTimeoutMs = 60_000;

    public static CaptureResult? TrySnapshot(IntPtr hwnd, int maxAgeMs, int waitMs, out string? error)
    {
        error = null;
        LiveCapture? live = null;

        lock (Gate)
        {
            SweepLocked();
            Map.TryGetValue(hwnd, out live);
        }

        if (live != null)
        {
            var hit = live.Snapshot(maxAgeMs, waitMs);
            if (hit != null) return hit;

            // 会话在但没帧（最小化/DRM/挂起）：拆掉，下次重建
            Drop(hwnd);
            error = live.LastError ?? "会话存在但在等待窗口内没有新帧";
            return null;
        }

        try
        {
            live = LiveCapture.Start(hwnd);
            lock (Gate) { Map[hwnd] = live; }
            var first = live.Snapshot(maxAgeMs, 150);
            if (first != null) return first;
            Drop(hwnd);
            error = "新建会话后仍未取到帧";
            return null;
        }
        catch (Exception ex)
        {
            // 诊断用：把首个非框架栈帧带出来，定位到底哪一步转换失败
            var frames = (ex.StackTrace ?? "").Split('\u000A');
            var hint = frames.FirstOrDefault(f => f.Contains("Wbcu."))?.Trim() ?? "";
            error = ex.GetType().Name + ": " + ex.Message + " @ " + hint;
            return null;
        }
    }

    public static void Drop(IntPtr hwnd)
    {
        LiveCapture? live;
        lock (Gate)
        {
            if (!Map.TryGetValue(hwnd, out live)) return;
            Map.Remove(hwnd);
        }
        live?.Dispose();
    }

    public static int DropAll()
    {
        LiveCapture[] all;
        lock (Gate)
        {
            all = Map.Values.ToArray();
            Map.Clear();
        }
        foreach (var l in all) l.Dispose();
        return all.Length;
    }

    public static int ActiveCount
    {
        get { lock (Gate) return Map.Count; }
    }

    private static void SweepLocked()
    {
        if (Map.Count == 0) return;
        foreach (var (hwnd, live) in Map.ToArray())
        {
            if (live.IdleMs > IdleTimeoutMs || !Native.IsWindow(hwnd))
            {
                Map.Remove(hwnd);
                live.Dispose();
            }
        }
    }
}
