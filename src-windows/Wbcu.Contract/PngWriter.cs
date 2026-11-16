using System.IO.Compression;

namespace Wbcu.Contract;

/// <summary>
/// 极简 PNG 编码器（BGRA/BGRX → PNG）。
///
/// 为什么不用 System.Drawing.Common：它从 .NET 6 起只在 Windows 上受支持，
/// 而截图落盘这段逻辑我们希望能在 macOS / CI 上直接单测（本轮就是在 Mac 上验证的）。
/// 不用 Windows.Graphics.Imaging.BitmapEncoder：那需要 WinRT 异步流，跨平台不可测。
/// 自己写 60 行，零依赖，两个平台的行为完全一致。
/// </summary>
public static class PngWriter
{
    /// <summary>BGRA（或 BGRX）缓冲 → PNG 字节。alpha 通道按原值写出。</summary>
    public static byte[] FromBgra(byte[] bgra, int width, int height, bool opaque = false)
    {
        if (width <= 0 || height <= 0) throw new ArgumentOutOfRangeException(nameof(width));
        if (bgra.Length < width * height * 4) throw new ArgumentException("buffer too small", nameof(bgra));

        var stride = width * 4;
        var raw = new byte[(stride + 1) * height]; // 每行前面加 filter byte 0

        for (var y = 0; y < height; y++)
        {
            var dst = y * (stride + 1);
            raw[dst] = 0;
            var src = y * stride;
            for (var x = 0; x < width; x++)
            {
                var s = src + x * 4;
                var d = dst + 1 + x * 4;
                raw[d + 0] = bgra[s + 2]; // R
                raw[d + 1] = bgra[s + 1]; // G
                raw[d + 2] = bgra[s + 0]; // B
                raw[d + 3] = opaque ? (byte)255 : bgra[s + 3];
            }
        }

        using var ms = new MemoryStream();
        ms.Write(new byte[] { 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A });

        // IHDR
        var ihdr = new byte[13];
        WriteBE(ihdr, 0, width);
        WriteBE(ihdr, 4, height);
        ihdr[8] = 8;   // bit depth
        ihdr[9] = 6;   // color type RGBA
        ihdr[10] = 0;  // deflate
        ihdr[11] = 0;  // filter
        ihdr[12] = 0;  // no interlace
        WriteChunk(ms, "IHDR", ihdr);

        // IDAT
        using (var comp = new MemoryStream())
        {
            using (var z = new ZLibStream(comp, CompressionLevel.Fastest, leaveOpen: true))
            {
                z.Write(raw, 0, raw.Length);
            }
            WriteChunk(ms, "IDAT", comp.ToArray());
        }

        // IEND
        WriteChunk(ms, "IEND", Array.Empty<byte>());
        return ms.ToArray();
    }

    private static void WriteChunk(Stream s, string type, byte[] data)
    {
        var len = new byte[4];
        WriteBE(len, 0, data.Length);
        s.Write(len);

        var typeBytes = System.Text.Encoding.ASCII.GetBytes(type);
        s.Write(typeBytes);
        s.Write(data);

        var crc = Crc32(typeBytes, data);
        var crcBytes = new byte[4];
        WriteBE(crcBytes, 0, unchecked((int)crc));
        s.Write(crcBytes);
    }

    private static void WriteBE(byte[] buf, int offset, int value)
    {
        buf[offset + 0] = (byte)(value >> 24);
        buf[offset + 1] = (byte)(value >> 16);
        buf[offset + 2] = (byte)(value >> 8);
        buf[offset + 3] = (byte)value;
    }

    private static readonly uint[] CrcTable = BuildCrcTable();

    private static uint[] BuildCrcTable()
    {
        var t = new uint[256];
        for (uint n = 0; n < 256; n++)
        {
            var c = n;
            for (var k = 0; k < 8; k++)
            {
                c = (c & 1) != 0 ? 0xEDB88320u ^ (c >> 1) : c >> 1;
            }
            t[n] = c;
        }
        return t;
    }

    private static uint Crc32(byte[] a, byte[] b)
    {
        var c = 0xFFFFFFFFu;
        foreach (var x in a) c = CrcTable[(c ^ x) & 0xFF] ^ (c >> 8);
        foreach (var x in b) c = CrcTable[(c ^ x) & 0xFF] ^ (c >> 8);
        return c ^ 0xFFFFFFFFu;
    }
}
