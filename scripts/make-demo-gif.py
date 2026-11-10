#!/usr/bin/env python3
"""把录制的真实帧合成 README 用的演示 GIF。

原则：
  * 帧来自 scripts/record-demo.sh 的实际录屏，不做任何画面合成/伪造
  * 字幕条里的鼠标坐标、验证状态取自同一次运行的采样（meta.txt）
  * 只截目标窗口区域，不含用户其他窗口内容
"""
import math
import pathlib
import sys

from PIL import Image, ImageDraw, ImageFont

SRC = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else "/tmp/thirdhand-frames")
OUT = pathlib.Path(sys.argv[2] if len(sys.argv) > 2 else "docs/images/demo.gif")

WIDTH = 320          # 输出宽度（原帧 476px @2x）
STEP = 4             # 每 4 帧取 1，控制体积与时长
DURATION_MS = 110
CAPTION_H = 56
MAX_COLORS = 128

FONT_CANDIDATES = [
    ("/System/Library/Fonts/Hiragino Sans GB.ttc", 0),
    ("/System/Library/Fonts/STHeiti Medium.ttc", 0),
    ("/System/Library/Fonts/Supplemental/Songti.ttc", 0),
]


def load_font(size: int) -> ImageFont.FreeTypeFont:
    for path, idx in FONT_CANDIDATES:
        try:
            return ImageFont.truetype(path, size, index=idx)
        except Exception:
            continue
    return ImageFont.load_default()


def read_meta() -> str:
    meta = SRC / "meta.txt"
    if not meta.exists():
        return ""
    mouse0, mouse1, verify, matched, sid = (meta.read_text().strip().split("|") + [""] * 5)[:5]
    same = "未移动" if mouse0 == mouse1 else f"→ {mouse1}"
    ok = "通过" if matched in ("True", "true") else "未验证"
    # 保持短：宽度 320 只放得下约 26 个全角字符
    return f"真实鼠标{same} · {verify} · 结果 15 {ok}"


def main() -> int:
    frames = sorted(SRC.glob("f*.png"))
    if not frames:
        print("没有找到帧", file=sys.stderr)
        return 1
    picked = frames[::STEP]
    print(f"总帧 {len(frames)}，取样 {len(picked)} 张")

    # 以第一帧算出目标尺寸
    with Image.open(picked[0]) as im0:
        ratio = WIDTH / im0.width
        height = int(im0.height * ratio)

    canvas_w, canvas_h = WIDTH, height + CAPTION_H
    caption = read_meta()
    font = load_font(11)
    font_brand = load_font(12)

    images = []
    for i, f in enumerate(picked):
        with Image.open(f) as im:
            im = im.convert("RGB").resize((WIDTH, height), Image.LANCZOS)
        canvas = Image.new("RGB", (canvas_w, canvas_h), (17, 17, 19))
        canvas.paste(im, (0, 0))

        d = ImageDraw.Draw(canvas)
        # 品牌行
        d.text((10, height + 8), "WorkBuddy Third Hand · 实际录屏", font=font_brand, fill=(168, 152, 255))
        # 实测数据行（可能过长，做一次截断保护）
        text = caption
        while d.textlength(text, font=font) > canvas_w - 20 and len(text) > 4:
            text = text[:-2]
        d.text((10, height + 28), text, font=font, fill=(176, 176, 184))

        images.append(canvas.quantize(colors=MAX_COLORS, method=Image.MEDIANCUT))

    OUT.parent.mkdir(parents=True, exist_ok=True)
    images[0].save(
        OUT,
        save_all=True,
        append_images=images[1:],
        duration=DURATION_MS,
        loop=0,
        optimize=True,
        disposal=2,
    )
    size_kb = OUT.stat().st_size / 1024
    print(f"写出 {OUT}  尺寸 {canvas_w}x{canvas_h}  {len(images)} 帧  {size_kb:.0f} KB")
    return 0


if __name__ == "__main__":
    sys.exit(main())
