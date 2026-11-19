using System.Diagnostics;
using System.Runtime.InteropServices;
using Vortice.Direct3D;
using Vortice.Direct3D11;
using Vortice.DXGI;
using Wbcu.Contract;
using Wbcu.Windows.Discovery;
using Wbcu.Windows.Win32;
using Windows.Graphics.Capture;
using Windows.Graphics.DirectX;
using Windows.Graphics.DirectX.Direct3D11;
using WinRT;

namespace Wbcu.Windows.Capture;

public sealed class CaptureResult
{
    public bool Ok { get; set; }
    public string Method { get; set; } = "none";
    public byte[] Bgra { get; set; } = Array.Empty<byte>();
    public int Width { get; set; }
    public int Height { get; set; }
    public double Ms { get; set; }
    public string? Failure { get; set; }
    /// <summary>降级时说明原因（例如 Graphics Capture 不可用，退回 PrintWindow）。</summary>
    public List<string> Warnings { get; } = new();

    // ---- 帧身份与新鲜度（v0.6.5）----
    // 目的：调用方必须能判断「这张图是不是目标窗口、是不是刚拍的、有多旧」。
    // 只靠比对 PNG 是否相同，无法证明目标身份，也无法证明时序。

    /// <summary>目标窗口句柄，证明这张图属于哪个窗口。</summary>
    public string? TargetHwnd { get; set; }
    /// <summary>目标进程 id。</summary>
    public int TargetPid { get; set; }
    /// <summary>持久会话内的递增帧号（每次成功读回 +1）。</summary>
    public long FrameId { get; set; }
    /// <summary>帧产生时刻（本地时间，ISO 8601）。</summary>
    public string? FrameTimestamp { get; set; }
    /// <summary>取用时该帧已存在多久（毫秒）。越小越新鲜。</summary>
    public long FrameAgeMs { get; set; }
    /// <summary>捕获会话代号：每次重建会话 +1，用于区分「同一个流」还是「换了新流」。</summary>
    public long CaptureGeneration { get; set; }
    /// <summary>帧是否已过期（超过 maxAge）。过期帧不能用于判定操作结果。</summary>
    public bool IsStale { get; set; }
    /// <summary>窗口 DPI（100 = 96dpi）。</summary>
    public int Dpi { get; set; }

    public byte[] ToPng() => PngWriter.FromBgra(Bgra, Width, Height, opaque: true);
}

/// <summary>
/// Windows 窗口捕获。
///
/// 两条实现路径，刻意保留双后端：
///
///   1) **Windows.Graphics.Capture**（首选）
///      DWM 合成的真实画面，包含 GPU 渲染内容；不需要把窗口拉到前台；
///      适合持续捕获（Latest Frame Wins）。依赖 Win10 1903+ / Win11。
///      限制：最小化窗口没有合成表面 → 取不到帧；受保护内容（DRM）为黑。
///
///   2) **PrintWindow(PW_RENDERFULLCONTENT)**（兜底）
///      同步 GDI 路径，几乎所有 Win32/DWM 窗口都能拿到画面，
///      但会阻塞目标线程一小会儿，且某些 GPU 重绘界面可能拿到空白。
///
/// 为什么不在这个文件里保留"每点一次都重建 capture session"的写法：
/// 那是 v0.4 之前最大的性能浪费（也最容易触发窗口闪烁）。会话级复用见 CaptureCache。
/// </summary>
public static class WindowCapture
{
    /// <summary>
    /// 统一出口：无论走哪条路径（持久会话 / 一次性 WGC / PrintWindow），
    /// 返回前都必须带齐目标身份。调用方只有拿到 targetHwnd 才能证明"这张图是谁的"。
    /// </summary>
    public static CaptureResult Capture(IntPtr hwnd, bool preferGraphicsCapture = true, bool useLiveSession = true)
    {
        var r = CaptureCore(hwnd, preferGraphicsCapture, useLiveSession);

        if (string.IsNullOrEmpty(r.TargetHwnd))
            r.TargetHwnd = "0x" + hwnd.ToInt64().ToString("X");

        if (r.TargetPid == 0)
        {
            try
            {
                Native.GetWindowThreadProcessId(hwnd, out var pid);
                r.TargetPid = (int)pid;
            }
            catch { }
        }

        if (r.Dpi == 0) r.Dpi = 96;

        // PrintWindow 走的是 GDI，可能拿到目标窗口上一次绘制的缓存帧，
        // 新鲜度无法保证 —— 明确标记，绝不让它伪装成实时帧。
        if (r.Method == "printwindow" && r.Ok)
        {
            r.IsStale = true;
            r.Warnings.Add("PrintWindow 降级路径：可能返回缓存画面，frameAge / frameId 不可信，不可用于判定操作结果");
        }

        return r;
    }

    private static CaptureResult CaptureCore(IntPtr hwnd, bool preferGraphicsCapture, bool useLiveSession)
    {
        if (hwnd == IntPtr.Zero || !Native.IsWindow(hwnd))
        {
            return new CaptureResult { Ok = false, Failure = "窗口句柄无效" };
        }

        if (Native.IsIconic(hwnd))
        {
            // 最小化时 Graphics Capture 与 PrintWindow 都拿不到有效画面，
            // 这里直接如实报告，不做「假装截到了黑图」。
            return new CaptureResult
            {
                Ok = false,
                Method = "none",
                Failure = "窗口已最小化：Windows 不为其保留合成表面，无法后台截图（需先还原窗口）",
            };
        }

        // ① 持久会话：命中即 0 等待（用户切窗口、遮挡都不影响，会话绑的是这个 HWND）
        if (useLiveSession && preferGraphicsCapture)
        {
            var live = LiveCaptureRegistry.TrySnapshot(hwnd, maxAgeMs: 800, waitMs: 250, out var liveError);
            if (live != null) return live;

            // 会话拿不到帧时，记录原因继续往下降级，绝不改成截前台窗口
            CaptureResult? once = null;
            string? onceError = null;
            try
            {
                once = GraphicsCaptureBackend.Once(hwnd);
            }
            catch (Exception ex)
            {
                onceError = ex.GetType().Name + ": " + ex.Message;
            }

            if (once is { Ok: true })
            {
                if (!string.IsNullOrEmpty(liveError)) once.Warnings.Add("持久会话未取到帧：" + liveError + "，已改用一次性捕获");
                return once;
            }

            var pw = PrintWindowBackend.Capture(hwnd);
            if (!string.IsNullOrEmpty(liveError)) pw.Warnings.Add("持久会话未取到帧：" + liveError);
            if (onceError != null) pw.Warnings.Add("一次性 Graphics Capture 异常：" + onceError);
            else if (once?.Failure != null) pw.Warnings.Add("Graphics Capture 未取到帧：" + once.Failure);
            return pw;
        }

        CaptureResult? result = null;
        if (preferGraphicsCapture)
        {
            try
            {
                result = GraphicsCaptureBackend.Once(hwnd);
            }
            catch (Exception ex)
            {
                result = null;
                var fallback = PrintWindowBackend.Capture(hwnd);
                fallback.Warnings.Add("Graphics Capture 失败（" + ex.GetType().Name + ": " + ex.Message + "），已退回 PrintWindow");
                return fallback;
            }
        }

        if (result is { Ok: true }) return result;

        var pwFallback = PrintWindowBackend.Capture(hwnd);
        if (result != null && result.Failure != null) pwFallback.Warnings.Add("Graphics Capture 未取到帧：" + result.Failure);
        return pwFallback;
    }

    /// <summary>GDI PrintWindow 路径。同步、无依赖，作为兜底。</summary>
    public static class PrintWindowBackend
    {
        public static CaptureResult Capture(IntPtr hwnd)
        {
            var sw = Stopwatch.StartNew();
            Native.GetWindowRect(hwnd, out var rect);
            var w = rect.Width;
            var h = rect.Height;
            if (w <= 0 || h <= 0)
            {
                return new CaptureResult { Ok = false, Failure = $"窗口尺寸无效 {w}x{h}" };
            }

            var screenDc = Native.GetDC(IntPtr.Zero);
            var memDc = Native.CreateCompatibleDC(screenDc);

            var bmi = new Native.BITMAPINFOHEADER
            {
                biSize = Marshal.SizeOf<Native.BITMAPINFOHEADER>(),
                biWidth = w,
                biHeight = -h,          // 负高度 = 自顶向下的 DIB
                biPlanes = 1,
                biBitCount = 32,
                biCompression = (int)Native.BI_RGB,
            };

            var dib = Native.CreateDIBSection(memDc, ref bmi, Native.DIB_RGB_COLORS, out var bits, IntPtr.Zero, 0);
            if (dib == IntPtr.Zero || bits == IntPtr.Zero)
            {
                Native.DeleteDC(memDc);
                Native.ReleaseDC(IntPtr.Zero, screenDc);
                return new CaptureResult { Ok = false, Failure = "CreateDIBSection 失败" };
            }

            var old = Native.SelectObject(memDc, dib);
            var ok = Native.PrintWindow(hwnd, memDc, Native.PW_RENDERFULLCONTENT);
            Native.SelectObject(memDc, old);

            var size = w * h * 4;
            var buf = new byte[size];
            Marshal.Copy(bits, buf, 0, size);

            Native.DeleteObject(dib);
            Native.DeleteDC(memDc);
            Native.ReleaseDC(IntPtr.Zero, screenDc);

            sw.Stop();
            if (!ok)
            {
                return new CaptureResult
                {
                    Ok = false, Method = "printwindow", Ms = sw.Elapsed.TotalMilliseconds,
                    Failure = "PrintWindow 返回失败（目标可能拒绝渲染或为受保护窗口）",
                };
            }

            return new CaptureResult
            {
                Ok = true, Method = "printwindow", Bgra = buf, Width = w, Height = h,
                Ms = sw.Elapsed.TotalMilliseconds,
            };
        }
    }

    /// <summary>
    /// Graphics Capture 单帧抓取。
    /// 说明：这里为了「一条命令拿到一帧」而临时建 session；
    /// 连续捕获（stream/verify 循环）应当复用同一个 session —— 见 CaptureSessionCache（Windows 侧按窗口缓存）。
    /// </summary>
    public static class GraphicsCaptureBackend
    {
        /// <summary>GraphicsCaptureItem 的 WinRT 接口 IID。</summary>
        private static readonly Guid GraphicsCaptureItemIid =
            new("79C3F95B-31F7-4EC2-A464-632EF5D30760");

        [DllImport("combase.dll", ExactSpelling = true)]
        private static extern int RoGetActivationFactory(IntPtr activatableClassId, ref Guid iid, out IntPtr factory);

        [DllImport("combase.dll", ExactSpelling = true)]
        private static extern int WindowsCreateString([MarshalAs(UnmanagedType.LPWStr)] string src, int len, out IntPtr hstring);

        [DllImport("combase.dll", ExactSpelling = true)]
        private static extern int WindowsDeleteString(IntPtr hstring);

        [DllImport("d3d11.dll", ExactSpelling = true)]
        private static extern int CreateDirect3D11DeviceFromDXGIDevice(IntPtr dxgiDevice, out IntPtr graphicsDevice);

        [ComImport, Guid("3628E81B-3CAC-4C60-B7F4-23CE0E0C3356"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        private interface IGraphicsCaptureItemInterop
        {
            IntPtr CreateForWindow(IntPtr hwnd, ref Guid iid);
            IntPtr CreateForMonitor(IntPtr hmonitor, ref Guid iid);
        }

        public static CaptureResult Once(IntPtr hwnd, int timeoutMs = 1500)
        {
            var sw = Stopwatch.StartNew();
            var item = CreateItem(hwnd);

            D3D11.D3D11CreateDevice(
                null, DriverType.Hardware, DeviceCreationFlags.BgraSupport,
                new[] { FeatureLevel.Level_11_0, FeatureLevel.Level_10_1, FeatureLevel.Level_10_0 },
                out ID3D11Device d3dDevice, out ID3D11DeviceContext context);

            if (d3dDevice == null)
            {
                return new CaptureResult { Ok = false, Failure = "D3D11 设备创建失败" };
            }

            IDirect3DDevice? winrtDevice = null;
            Direct3D11CaptureFramePool? pool = null;
            GraphicsCaptureSession? session = null;
            Direct3D11CaptureFrame? frame = null;

            try
            {
                winrtDevice = CreateWinRtDevice(d3dDevice);

                var size = item.Size;
                pool = Direct3D11CaptureFramePool.CreateFreeThreaded(
                    winrtDevice, DirectXPixelFormat.B8G8R8A8UIntNormalized, 2, size);
                session = pool.CreateCaptureSession(item);

                // Win11 22H2+ 才有 IsBorderRequired（关掉那条黄色捕获边框）。
                // 当前投影来自 19041 契约，属性可能压根不存在，所以用反射探测：
                // 有就设，没有就算了——绝不能因为一个可选优化让捕获整体失败。
                try
                {
                    var prop = session.GetType().GetProperty("IsBorderRequired");
                    prop?.SetValue(session, false);
                }
                catch { }
                try { session.IsCursorCaptureEnabled = false; } catch { }

                session.StartCapture();

                var wait = Stopwatch.StartNew();
                while (wait.ElapsedMilliseconds < timeoutMs)
                {
                    frame = pool.TryGetNextFrame();
                    if (frame != null) break;
                    Thread.Sleep(10);
                }

                if (frame == null)
                {
                    return new CaptureResult
                    {
                        Ok = false, Method = "graphics_capture", Ms = sw.Elapsed.TotalMilliseconds,
                        Failure = $"在 {timeoutMs}ms 内没有收到帧（窗口可能在最小化/被遮挡为空白/受保护）",
                    };
                }

                var result = ReadbackFrame(frame, d3dDevice, context);
                result.Ms = sw.Elapsed.TotalMilliseconds;
                return result;
            }
            finally
            {
                try { frame?.Dispose(); } catch { }
                try { session?.Dispose(); } catch { }
                try { pool?.Dispose(); } catch { }
                try { context?.Dispose(); } catch { }
                try { d3dDevice?.Dispose(); } catch { }
            }
        }

        internal static GraphicsCaptureItem CreateItem(IntPtr hwnd)
        {
            var className = "Windows.Graphics.Capture.GraphicsCaptureItem";
            var hr = WindowsCreateString(className, className.Length, out var hstring);
            if (hr != 0) throw new InvalidOperationException($"WindowsCreateString 失败 0x{hr:X8}");

            // IActivationFactory 的 IID（{00000035-0000-0000-C000-000000000046}）
            var iidFactory = Guid.Parse("00000035-0000-0000-C000-000000000046");

            try
            {
                hr = RoGetActivationFactory(hstring, ref iidFactory, out var factory);
                if (hr != 0 || factory == IntPtr.Zero)
                {
                    throw new InvalidOperationException($"RoGetActivationFactory 失败 0x{hr:X8}");
                }

                var iidInterop = typeof(IGraphicsCaptureItemInterop).GUID;
                hr = Marshal.QueryInterface(factory, ref iidInterop, out var interopPtr);
                Marshal.Release(factory);
                if (hr != 0 || interopPtr == IntPtr.Zero)
                {
                    throw new InvalidOperationException($"QI IGraphicsCaptureItemInterop 失败 0x{hr:X8}");
                }

                // 关键修复：不要用 Marshal.GetTypedObjectForIUnknown 把 WinRT 工厂包成 RCW。
                //
                // 那是 v0.6.2 及以前 WGC 一直拿不到帧的真因：
                // RoGetActivationFactory 返回的是 **IInspectable 派生** 接口，
                // vtable 布局是 [QI, AddRef, Release, GetIids, GetRuntimeClassName, GetTrustLevel, CreateForWindow, ...]；
                // 而 ComImport + InterfaceIsIUnknown 让 RCW 按「IUnknown 派生」解释，
                // 从第 4 个槽开始取方法 —— 正好错位三格，调用到 GetIids，
                // 于是每次都是 InvalidCastException / 参数错乱，永远进不了 CreateForWindow。
                //
                // 这里直接按 vtable 索引 6 调用，绕开 RCW 的类型系统。签名：
                //   HRESULT CreateForWindow(HWND window, REFIID iid, void** result)
                try
                {
                    // 必须用 WinRT 接口的真实 IID，不能用 typeof(GraphicsCaptureItem).GUID。
                    // CsWinRT 给投影类型生成的是 TypeGuid（实测 cc7b16ab-e4bc-3d0e-a4eb-4fdb9ce0a1ff），
                    // 把它当 REFIID 传给 CreateForWindow 会稳定得到 E_NOINTERFACE(0x80004002)——
                    // 这是 WGC 在本仓库长期取不到帧的第二个坑，和 vtable 槽位错位叠加在一起。
                    var iidItem = GraphicsCaptureItemIid;
                    var itemPtr = CreateForWindowRaw(interopPtr, hwnd, ref iidItem);
                    if (itemPtr == IntPtr.Zero)
                    {
                        throw new InvalidOperationException("CreateForWindow 返回空指针");
                    }
                    try
                    {
                        return MarshalInspectable<GraphicsCaptureItem>.FromAbi(itemPtr);
                    }
                    finally
                    {
                        Marshal.Release(itemPtr);
                    }
                }
                finally
                {
                    Marshal.Release(interopPtr);
                }
            }
            finally
            {
                WindowsDeleteString(hstring);
            }
        }

        /// <summary>
        /// 直接按 vtable 调用 CreateForWindow。
        ///
        /// IGraphicsCaptureItemInterop 继承的是 **IUnknown**（不是 IInspectable），
        /// 所以 QueryInterface 后的 vtable 是：
        ///   0 QueryInterface / 1 AddRef / 2 Release / 3 CreateForWindow / 4 CreateForMonitor
        ///
        /// 索引写错（比如按 IInspectable 的 6）不会崩，而是调到别的方法上，
        /// 表现就是一串每次都不一样的垃圾 HRESULT —— 这个坑实测踩过一次。
        /// </summary>
        private static unsafe IntPtr CreateForWindowRaw(IntPtr interopPtr, IntPtr hwnd, ref Guid iid)
        {            var vtbl = *(IntPtr**)interopPtr;
            var fn = vtbl[3];
            var call = (delegate* unmanaged[Stdcall]<IntPtr, IntPtr, Guid*, IntPtr*, int>)fn;

            var localIid = iid;
            IntPtr itemPtr;
            var hr = call(interopPtr, hwnd, &localIid, &itemPtr);
            if (hr < 0)
            {
                throw new InvalidOperationException(
                    $"CreateForWindow 失败 HRESULT=0x{hr:X8} iid={localIid} hwnd=0x{hwnd.ToInt64():X}");
            }
            return itemPtr;
        }

        /// <summary>
        /// 直接按 vtable 调用 IDirect3DDxgiInterfaceAccess.GetInterface（槽位 3），
        /// 绕开 CsWinRT 的 MarshalInspectable 转换——那条路对 Vortice 的 COM 接口类型必然 cast 失败。
        /// 签名：HRESULT GetInterface(REFIID riid, void** ppvObject)
        /// </summary>
        private static unsafe IntPtr GetDxgiInterfaceRaw(IntPtr accessPtr, Guid iid)
        {
            var vtbl = *(IntPtr**)accessPtr;
            var fn = vtbl[3];
            var call = (delegate* unmanaged[Stdcall]<IntPtr, Guid*, IntPtr*, int>)fn;

            var localIid = iid;
            IntPtr result;
            var hr = call(accessPtr, &localIid, &result);
            if (hr < 0)
            {
                throw new InvalidOperationException($"GetInterface 失败 HRESULT=0x{hr:X8} iid={localIid}");
            }
            return result;
        }

        internal static IDirect3DDevice CreateWinRtDevice(ID3D11Device d3dDevice)
        {
            using var dxgi = d3dDevice.QueryInterface<IDXGIDevice>();
            var hr = CreateDirect3D11DeviceFromDXGIDevice(dxgi.NativePointer, out var inspectable);
            if (hr != 0 || inspectable == IntPtr.Zero)
            {
                throw new InvalidOperationException($"CreateDirect3D11DeviceFromDXGIDevice 失败 0x{hr:X8}");
            }
            try
            {
                return MarshalInspectable<IDirect3DDevice>.FromAbi(inspectable);
            }
            finally
            {
                Marshal.Release(inspectable);
            }
        }

        internal static CaptureResult ReadbackFrame(Direct3D11CaptureFrame frame, ID3D11Device device, ID3D11DeviceContext context)
        {
            // CsWinRT 的公开投影里**没有** IDirect3DDxgiInterfaceAccess（只有 Vortice 那个同名 SharpGen 接口，
            // 它对 frame.Surface.As<T>() 不适用）。所以从 Surface 的 IInspectable 指针直接 QI：
            //   IID_IDirect3DDxgiInterfaceAccess = A9B3D012-3DF2-4EE3-B8D1-8695F457D3C1
            // 再走它的 vtable[3] GetInterface(IID_ID3D11Texture2D)。
            var surfacePtr = MarshalInspectable<global::Windows.Graphics.DirectX.Direct3D11.IDirect3DSurface>
                .FromManaged(frame.Surface);

            IntPtr texturePtr = IntPtr.Zero;
            try
            {
                var iidAccess = new Guid("A9B3D012-3DF2-4EE3-B8D1-8695F457D3C1");
                var hrQi = Marshal.QueryInterface(surfacePtr, ref iidAccess, out var accessPtr);
                if (hrQi != 0 || accessPtr == IntPtr.Zero)
                {
                    throw new InvalidOperationException($"QI IDirect3DDxgiInterfaceAccess 失败 0x{hrQi:X8}");
                }
                try
                {
                    texturePtr = GetDxgiInterfaceRaw(accessPtr, new Guid("6F15AAF2-D208-4E89-9AB4-489535D34F9C"));
                }
                finally
                {
                    Marshal.Release(accessPtr);
                }
            }
            finally
            {
                Marshal.Release(surfacePtr);
            }

            if (texturePtr == IntPtr.Zero) throw new InvalidOperationException("GetInterface(ID3D11Texture2D) 返回空指针");

            using var ownedTexture = new ID3D11Texture2D(texturePtr);
            var desc = ownedTexture.Description;
            var w = (int)desc.Width;
            var h = (int)desc.Height;

            using var staging = device.CreateTexture2D(new Texture2DDescription
            {
                Width = desc.Width,
                Height = desc.Height,
                MipLevels = 1,
                ArraySize = 1,
                Format = Format.B8G8R8A8_UNorm,
                SampleDescription = new SampleDescription(1, 0),
                Usage = ResourceUsage.Staging,
                BindFlags = BindFlags.None,
                CPUAccessFlags = CpuAccessFlags.Read,
                MiscFlags = ResourceOptionFlags.None,
            });

            context.CopyResource(staging, ownedTexture);
            var map = context.Map(staging, 0, Vortice.Direct3D11.MapMode.Read);
            try
            {
                var buf = new byte[w * h * 4];
                for (var y = 0; y < h; y++)
                {
                    var src = IntPtr.Add(map.DataPointer, y * (int)map.RowPitch);
                    Marshal.Copy(src, buf, y * w * 4, w * 4);
                }
                return new CaptureResult
                {
                    Ok = true, Method = "graphics_capture", Bgra = buf, Width = w, Height = h,
                };
            }
            finally
            {
                context.Unmap(staging, 0);
            }
        }
    }
}
