using Wbcu.Contract;
using Xunit;

namespace Wbcu.Tests;

/// <summary>
/// Ghost Cursor 与截图编码的纯逻辑测试。
/// 这两块以前最容易「看起来对」：位图画出来没人校验，PNG 写坏了要到落盘才发现。
/// </summary>
public class CursorRasterTests
{
    [Fact]
    public void Buffer_size_matches_requested_bitmap()
    {
        var buf = CursorRaster.RenderCursor(126);
        Assert.Equal(126 * 126 * 4, buf.Length);
    }

    [Fact]
    public void Corners_are_fully_transparent()
    {
        const int size = 64;
        var buf = CursorRaster.RenderCursor(size);
        int A(int x, int y) => buf[(y * size + x) * 4 + 3];

        Assert.Equal(0, A(0, 0));
        Assert.Equal(0, A(size - 1, 0));
        Assert.Equal(0, A(0, size - 1));
        Assert.Equal(0, A(size - 1, size - 1));
    }

    [Fact]
    public void Cursor_has_opaque_pixels_somewhere()
    {
        var buf = CursorRaster.RenderCursor(96);
        var hasSolid = false;
        for (var i = 3; i < buf.Length; i += 4)
        {
            if (buf[i] > 200) { hasSolid = true; break; }
        }
        Assert.True(hasSolid, "光标主体应该有不透明像素，否则等于没画出来");
    }

    [Fact]
    public void Pixels_are_premultiplied()
    {
        // UpdateLayeredWindow + AC_SRC_ALPHA 要求预乘：任何通道都不能大于 alpha
        var buf = CursorRaster.RenderCursor(64);
        for (var i = 0; i < buf.Length; i += 4)
        {
            var b = buf[i];
            var g = buf[i + 1];
            var r = buf[i + 2];
            var a = buf[i + 3];
            Assert.True(b <= a, $"B 通道未预乘 @{i / 4}");
            Assert.True(g <= a, $"G 通道未预乘 @{i / 4}");
            Assert.True(r <= a, $"R 通道未预乘 @{i / 4}");
        }
    }

    [Fact]
    public void Rendering_is_deterministic()
    {
        Assert.Equal(CursorRaster.RenderCursor(48), CursorRaster.RenderCursor(48));
    }

    [Fact]
    public void Click_ring_fades_out_at_progress_one()
    {
        var start = CursorRaster.RenderClickRing(64, 0.0);
        var end = CursorRaster.RenderClickRing(64, 1.0);
        Assert.True(MaxAlpha(start) > MaxAlpha(end));
    }

    [Fact]
    public void Click_ring_is_centered_on_the_tip_not_the_bitmap_center()
    {
        const int size = 126;
        const double progress = 0.3;
        var ring = CursorRaster.RenderClickRing(size, progress);

        // 热点在 (24,24)；环半径 = (10 + 16*progress) DIP
        var radius = 10 + 16 * progress;
        var cx = (int)Math.Round(24 + radius);
        var onRing = (24 * size + cx) * 4 + 3;
        Assert.True(ring[onRing] > 20, "环必须出现在热点周围，而不是位图中心");

        // 位图中心 (63,63) 距热点约 55px，远超最大环半径，必须完全为空
        var atCenter = (63 * size + 63) * 4 + 3;
        Assert.Equal(0, ring[atCenter]);
    }

    [Fact]
    public void Click_ring_uses_mid_luminance_blue()
    {
        // 白环在浅色桌面消失、黑环在深色桌面消失；中亮度蓝对两者都有对比度。
        var ring = CursorRaster.RenderClickRing(126, 0.5);
        var found = 0;

        for (var i = 0; i < ring.Length; i += 4)
        {
            var a = ring[i + 3];
            if (a < 30) continue;
            var b = ring[i + 0] * 255.0 / a;
            var g = ring[i + 1] * 255.0 / a;
            var r = ring[i + 2] * 255.0 / a;
            var lum = 0.299 * r + 0.587 * g + 0.114 * b;

            Assert.True(b > r + 40, "反馈环应偏蓝（B 明显大于 R）");
            Assert.InRange(lum, 60, 220);   // 既不是纯白也不是纯黑
            found++;
        }

        Assert.True(found >= 8, $"反馈环像素太少（{found}），可能没画出来");
    }

    [Fact]
    public void Click_ring_center_is_empty()
    {
        const int size = 64;
        var buf = CursorRaster.RenderClickRing(size, 0.5);
        var center = ((size / 2) * size + size / 2) * 4;
        Assert.Equal(0, buf[center + 3]);
    }

    private static int MaxAlpha(byte[] buf)
    {
        var max = 0;
        for (var i = 3; i < buf.Length; i += 4) max = Math.Max(max, buf[i]);
        return max;
    }
}

public class PngWriterTests
{
    [Fact]
    public void Writes_valid_png_header_and_dimensions()
    {
        const int w = 4, h = 3;
        var bgra = new byte[w * h * 4];
        for (var i = 0; i < bgra.Length; i += 4)
        {
            bgra[i + 0] = 10;  // B
            bgra[i + 1] = 20;  // G
            bgra[i + 2] = 30;  // R
            bgra[i + 3] = 255; // A
        }

        var png = PngWriter.FromBgra(bgra, w, h);

        Assert.True(png.Length > 8);
        Assert.Equal(new byte[] { 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A }, png.Take(8).ToArray());

        // IHDR 紧跟签名：长度(4) + "IHDR"(4) + width(4) + height(4)
        Assert.Equal("IHDR", System.Text.Encoding.ASCII.GetString(png, 12, 4));
        Assert.Equal(w, ReadBE(png, 16));
        Assert.Equal(h, ReadBE(png, 20));
        Assert.Equal(8, png[24]);  // bit depth
        Assert.Equal(6, png[25]);  // RGBA
    }

    [Fact]
    public void Rejects_too_small_buffer()
    {
        Assert.Throws<ArgumentException>(() => PngWriter.FromBgra(new byte[10], 4, 4));
    }

    [Fact]
    public void Rejects_non_positive_dimensions()
    {
        Assert.Throws<ArgumentOutOfRangeException>(() => PngWriter.FromBgra(new byte[16], 0, 4));
    }

    private static int ReadBE(byte[] b, int off) =>
        (b[off] << 24) | (b[off + 1] << 16) | (b[off + 2] << 8) | b[off + 3];
}

public class ExperienceTests
{
    [Fact]
    public void Key_prefers_package_family()
    {
        Assert.Equal("pkg:microsoft.windowscalculator_8wekyb3d8bbwe",
            AppExperience.KeyOf(@"C:\Windows\System32\calc.exe", "microsoft.windowscalculator_8wekyb3d8bbwe", "ApplicationFrameWindow"));
    }

    [Fact]
    public void Key_falls_back_to_exe_and_class()
    {
        var k = AppExperience.KeyOf(@"C:\Windows\notepad.exe", "", "Notepad");
        Assert.Equal(@"exe:c:\windows\notepad.exe|class:notepad", k);
    }

    [Fact]
    public void Element_memory_never_prefers_coordinates()
    {
        var mem = new ElementMemory { Name = "7", ControlType = "Button", LastSeenRect = new double[] { 1, 2, 3, 4 } };
        var sel = mem.ToSelector();
        Assert.Equal(SelectorKind.Name, sel.Kind);
        Assert.DoesNotContain("1", sel.Value);
    }

    [Fact]
    public void Element_memory_prefers_automation_id_over_path_and_name()
    {
        var mem = new ElementMemory { Name = "7", AutomationId = "num7Button", Path = new[] { 0, 1, 2 } };
        Assert.Equal(SelectorKind.AutomationId, mem.ToSelector().Kind);
    }

    [Fact]
    public void Session_record_roundtrips_through_json()
    {
        var s = new SessionRecord
        {
            Id = "s123", Pid = 4242, WindowHandle = "0x1A2B", Executable = "calc.exe",
            Frame = new double[] { 10, 20, 300, 400 }, Dpi = 144, Scale = 1.5,
        };
        var back = Json.Deserialize<SessionRecord>(Json.Serialize(s));
        Assert.NotNull(back);
        Assert.Equal("s123", back!.Id);
        Assert.Equal(144, back.Dpi);
        Assert.Equal(new double[] { 10, 20, 300, 400 }, back.Frame);
        Assert.True(back.IsUsable);
    }
}
