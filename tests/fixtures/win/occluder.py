"""可控遮挡窗口：盖在目标窗口上，用于验证 capture 是否受遮挡影响。

用法：
  python occluder.py <x> <y> <w> <h> [color]
窗口无边框、置顶、纯色，覆盖指定屏幕区域。
"""
import sys
import tkinter as tk

x, y, w, h = (int(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4]))
color = sys.argv[5] if len(sys.argv) > 5 else "#202020"

root = tk.Tk()
root.overrideredirect(True)
root.geometry(f"{w}x{h}+{x}+{y}")
root.configure(bg=color)
root.attributes("-topmost", True)
tk.Label(root, text="OCCLUDER", font=("Consolas", 14), bg=color, fg="#808080").place(relx=0.5, rely=0.5, anchor="center")
root.mainloop()
