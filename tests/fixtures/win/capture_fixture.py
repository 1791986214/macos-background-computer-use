"""遮挡测试夹具：一个内容持续变化的窗口。

设计目的：证明 capture 拿到的是**实时画面**，不是旧帧或缓存。
每 300ms 计数器 +1，背景色同时切换 —— 所以任意两次捕获的 PNG 字节必然不同。
如果两次捕获完全一样，就说明拿到的是缓存/旧帧。

用法：
  python capture_fixture.py            # 启动窗口
窗口标题固定为 WBCU-CAPTURE-FIXTURE，便于按标题定位 hwnd。
"""
import tkinter as tk
import itertools

PALETTE = ["#1e3a5f", "#2d5a3d", "#5f1e3a", "#4a3f1e", "#1e4f5f", "#3f1e5f"]
STATE = {"n": 0}


def main():
    root = tk.Tk()
    root.title("WBCU-CAPTURE-FIXTURE")
    root.geometry("640x420+380+300")
    root.attributes("-topmost", False)

    frame = tk.Frame(root)
    frame.pack(fill="both", expand=True)

    big = tk.Label(frame, text="FRAME 0", font=("Consolas", 64, "bold"), fg="#ffffff")
    big.pack(expand=True)

    sub = tk.Label(frame, text="live probe", font=("Consolas", 16), fg="#e0e0e0")
    sub.pack()

    colors = itertools.cycle(PALETTE)

    def tick():
        STATE["n"] += 1
        n = STATE["n"]
        c = next(colors)
        # 计数器同时出现在标题和画面上：标题可被 UIA 直接读取，
        # 于是可以拿「标题里的 N」去核对「截图的帧号/新鲜度」，不需要 OCR。
        root.title(f"WBCU-CAPTURE-FIXTURE #{n}")
        frame.configure(bg=c)
        big.configure(text=f"FRAME {n}", bg=c)
        sub.configure(text=f"n={n}  {c}", bg=c)
        root.after(300, tick)

    tick()
    root.mainloop()


if __name__ == "__main__":
    main()
