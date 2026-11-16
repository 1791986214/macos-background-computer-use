using System.Globalization;
using Wbcu.Contract;

// 开发用预览工具：把 Ghost Cursor 的纯像素渲染结果落到 PNG，
// 方便在没有 Windows 机器时也能核对视觉风格（浅色箭头 + 柔和光晕）。
//
// 用法： dotnet run --project src-windows/tools/RenderPreview -- <输出目录>

// 契约导出模式：把 C# 侧的契约文档写成 JSON，供 scripts/check-contract-parity.sh
// 与 macOS 引擎的 `wbcu contract --json` 做逐字对比。
if (args.Length >= 2 && args[0] == "--contract")
{
    var contract = ContractSchema.Build(Platforms.Windows, Engines.WindowsUia, "0.6.0");
    File.WriteAllText(args[1], Json.Serialize(contract, pretty: true));
    Console.WriteLine("contract -> " + Path.GetFullPath(args[1]));
    return;
}

var outDir = args.Length > 0 ? args[0] : ".";
Directory.CreateDirectory(outDir);

// 1) 单枚光标，透明底
WriteComposite(Path.Combine(outDir, "ghost-cursor.png"), 126, 126, 1.0, null);

// 2) 在浅色与深色背景上各合成一次，检查可见性
WriteComposite(Path.Combine(outDir, "ghost-cursor-on-light.png"), 126, 126, 1.0, (245, 246, 248));
WriteComposite(Path.Combine(outDir, "ghost-cursor-on-dark.png"), 126, 126, 1.0, (32, 34, 40));

// 3) 2 倍缩放（HiDPI 下的实际渲染尺寸）
WriteComposite(Path.Combine(outDir, "ghost-cursor-2x.png"), 252, 252, 1.0, (245, 246, 248));

// 4) 点击反馈环的四个阶段拼图
WriteRingStrip(Path.Combine(outDir, "ghost-click-ring.png"), 96);

// 5) 一套「动效帧」：光标 + 逐渐扩散的环
WriteClickSequence(Path.Combine(outDir, "ghost-click-sequence.png"), 126);

Console.WriteLine($"渲染完成 → {Path.GetFullPath(outDir)}");

void WriteComposite(string path, int w, int h, double scale, (int R, int G, int B)? bg)
{
    var cur = CursorRaster.RenderCursor(Math.Min(w, h));
    var canvas = new byte[w * h * 4];
    if (bg is { } c)
    {
        for (var i = 0; i < canvas.Length; i += 4)
        {
            canvas[i + 0] = (byte)c.B;
            canvas[i + 1] = (byte)c.G;
            canvas[i + 2] = (byte)c.R;
            canvas[i + 3] = 255;
        }
    }
    Over(cur, Math.Min(w, h), canvas, w, h, 0, 0);
    File.WriteAllBytes(path, PngWriter.FromBgra(canvas, w, h));
    Console.WriteLine($"  {Path.GetFileName(path)}  {w}x{h} scale={scale.ToString(CultureInfo.InvariantCulture)}");
}

void WriteRingStrip(string path, int cell)
{
    const int stages = 4;
    var w = cell * stages;
    var canvas = new byte[w * cell * 4];
    Fill(canvas, (24, 26, 32));
    for (var s = 0; s < stages; s++)
    {
        var ring = CursorRaster.RenderClickRing(cell, s / (double)(stages - 1));
        var cur = CursorRaster.RenderCursor(cell);
        Over(cur, cell, canvas, w, cell, s * cell, 0);
        Over(ring, cell, canvas, w, cell, s * cell, 0);
    }
    File.WriteAllBytes(path, PngWriter.FromBgra(canvas, w, cell));
}

void WriteClickSequence(string path, int cell)
{
    const int stages = 3;
    var w = cell * stages;
    var canvas = new byte[w * cell * 4];
    Fill(canvas, (245, 246, 248));
    for (var s = 0; s < stages; s++)
    {
        var cur = CursorRaster.RenderCursor(cell);
        Over(cur, cell, canvas, w, cell, s * cell, 0);
        if (s > 0)
        {
            var ring = CursorRaster.RenderClickRing(cell, 0.35 + 0.3 * (s - 1));
            Over(ring, cell, canvas, w, cell, s * cell, 0);
        }
    }
    File.WriteAllBytes(path, PngWriter.FromBgra(canvas, w, cell));
}

void Fill(byte[] canvas, (int R, int G, int B) c)
{
    for (var i = 0; i < canvas.Length; i += 4)
    {
        canvas[i + 0] = (byte)c.B;
        canvas[i + 1] = (byte)c.G;
        canvas[i + 2] = (byte)c.R;
        canvas[i + 3] = 255;
    }
}

// 把预乘 BGRA 小图叠到预乘画布上（source-over）
void Over(byte[] src, int srcSize, byte[] dst, int dstW, int dstH, int ox, int oy)
{
    for (var y = 0; y < srcSize; y++)
    {
        for (var x = 0; x < srcSize; x++)
        {
            var dx = ox + x;
            var dy = oy + y;
            if (dx < 0 || dy < 0 || dx >= dstW || dy >= dstH) continue;

            var s = (y * srcSize + x) * 4;
            var d = (dy * dstW + dx) * 4;
            var sa = src[s + 3] / 255.0;
            if (sa <= 0) continue;
            var da = dst[d + 3] / 255.0;
            var outA = sa + da * (1 - sa);
            if (outA <= 0) continue;

            for (var c = 0; c < 3; c++)
            {
                var sv = src[s + c] / 255.0;          // 已预乘
                var dv = dst[d + c] / 255.0 * da;     // 反预乘后重新合成
                var ov = sv + dv * (1 - sa);
                dst[d + c] = (byte)Math.Clamp(ov / outA * 255.0, 0, 255);
            }
            dst[d + 3] = (byte)Math.Clamp(outA * 255.0, 0, 255);
        }
    }
}
