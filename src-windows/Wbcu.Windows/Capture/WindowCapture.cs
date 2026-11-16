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
    public static CaptureResult Capture(IntPtr hwnd, bool preferGraphicsCapture = true)
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

        var pw = PrintWindowBackend.Capture(hwnd);
        if (result != null && result.Failure != null) pw.Warnings.Add("Graphics Capture 未取到帧：" + result.Failure);
        return pw;
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

        private static GraphicsCaptureItem CreateItem(IntPtr hwnd)
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

                var interop = (IGraphicsCaptureItemInterop)Marshal.GetTypedObjectForIUnknown(
                    interopPtr, typeof(IGraphicsCaptureItemInterop));
                try
                {
                    var iidItem = typeof(GraphicsCaptureItem).GUID;
                    var itemPtr = interop.CreateForWindow(hwnd, ref iidItem);
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

        private static IDirect3DDevice CreateWinRtDevice(ID3D11Device d3dDevice)
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

        private static CaptureResult ReadbackFrame(Direct3D11CaptureFrame frame, ID3D11Device device, ID3D11DeviceContext context)
        {
            var access = frame.Surface.As<IDirect3DDxgiInterfaceAccess>();
            using var texture = access.GetInterface<ID3D11Texture2D>();
            var desc = texture.Description;
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

            context.CopyResource(staging, texture);
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
