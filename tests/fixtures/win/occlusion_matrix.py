"""遮挡测试矩阵：验证 wbcu capture 与前台/遮挡完全解耦。

判定原则：
  目标窗口每 300ms 计数器+1、背景换色，所以**两次捕获的 PNG 必然不同**。
  - PNG 变 → 拿到的是实时画面
  - PNG 不变 → 拿到的是旧帧/缓存（失败）
"""
import ctypes
import ctypes.wintypes as wt
import hashlib
import json
import subprocess
import sys
import time
import os

OUT = r"C:\Users\pc\wbcu_preview\out\occl"
os.makedirs(OUT, exist_ok=True)
FIXTURE_TITLE = "WBCU-CAPTURE-FIXTURE"
WB = os.environ.get("WB", "wbcu")


def find(hwnd_or_title):
    u = ctypes.windll.user32
    res = []

    def cb(h, l):
        t = ctypes.create_unicode_buffer(256)
        u.GetWindowTextW(h, t, 256)
        if FIXTURE_TITLE in t.value:
            c = ctypes.create_unicode_buffer(256)
            u.GetClassNameW(h, c, 256)
            pid = wt.DWORD()
            u.GetWindowThreadProcessId(h, ctypes.byref(pid))
            r = wt.RECT()
            u.GetWindowRect(h, ctypes.byref(r))
            res.append((h, pid.value, (r.left, r.top, r.right - r.left, r.bottom - r.top)))
        return True

    u.EnumWindows(ctypes.WINFUNCTYPE(wt.BOOL, wt.HWND, wt.LPARAM)(cb), 0)
    return res[0] if res else None


def run(args):
    p = subprocess.run(args, capture_output=True, text=True, encoding="gbk", errors="replace")
    try:
        return json.loads(p.stdout)
    except Exception:
        return {"ok": False, "raw": (p.stdout or "")[:200] + "|" + (p.stderr or "")[:200]}


def md5(p):
    return hashlib.md5(open(p, "rb").read()).hexdigest()[:12]


def fg_title():
    u = ctypes.windll.user32
    h = u.GetForegroundWindow()
    t = ctypes.create_unicode_buffer(256)
    u.GetWindowTextW(h, t, 256)
    return t.value


def main():
    info = find(FIXTURE_TITLE)
    if not info:
        sys.exit("夹具窗口没找到")
    hwnd, pid, (x, y, w, h) = info
    print(f"夹具 hwnd=0x{hwnd:X} pid={pid} rect=({x},{y}) {w}x{h}")

    attach = run([WB, "attach", "--app", str(pid), "--json"])
    if not attach.get("ok"):
        sys.exit(f"attach 失败: {attach}")
    sid = attach["data"]["session"]["id"]
    print(f"session={sid}\n")

    def cap(tag):
        out = os.path.join(OUT, f"{tag}.png")
        r = run([WB, "capture", "--id", sid, "--out", out, "--json"])
        if not r.get("ok"):
            return {"tag": tag, "ok": False, "method": "-", "md5": "-", "ms": r.get("elapsedMs"),
                    "size": "-", "err": r.get("failureReason") or r.get("errorCode")}
        d = r.get("data") or {}
        return {"tag": tag, "ok": True, "method": r.get("method"), "md5": md5(out),
                "ms": round(r.get("elapsedMs", 0), 1),
                "size": f"{d.get('width')}x{d.get('height')}"}

    occ = None

    def start_occ(ox, oy, ow, oh):
        nonlocal occ
        occ = subprocess.Popen([sys.executable, r"C:\Users\pc\wbcu_preview\occluder.py",
                                str(ox), str(oy), str(ow), str(oh)])
        time.sleep(1.0)

    def stop_occ():
        nonlocal occ
        if occ:
            occ.terminate()
            try:
                occ.wait(timeout=3)
            except Exception:
                occ.kill()
            occ = None
            time.sleep(0.6)

    rows = []

    # ① 完全可见
    time.sleep(0.5)
    rows.append(cap("1_visible"))
    rows.append(cap("1b_visible"))

    # ② 部分遮挡：只盖左侧 55%
    start_occ(x, y, int(w * 0.55), h)
    rows.append(cap("2_partial"))
    rows.append(cap("2b_partial"))
    stop_occ()

    # ③ 完全遮挡：四周各外扩 10px
    start_occ(x - 10, y - 10, w + 20, h + 20)
    rows.append(cap("3_full"))
    rows.append(cap("3b_full"))
    stop_occ()

    # ④ 用户连续切换前台（用 occluder 反复抢焦点模拟前台切换）
    for i in range(2):
        start_occ(x - 10, y - 10, w + 20, h + 20)
        time.sleep(0.4)
        stop_occ()
    rows.append(cap("4_switching"))

    # ⑤ 移动目标窗口（+60,+40）
    u = ctypes.windll.user32
    u.SetWindowPos(hwnd, 0, x + 60, y + 40, 0, 0, 0x0001 | 0x0004)  # NOSIZE|NOZORDER
    time.sleep(0.8)
    rows.append(cap("5_moved"))

    # ⑥ 缩放目标窗口（-120,-80）
    u.SetWindowPos(hwnd, 0, 0, 0, w - 120, h - 80, 0x0002 | 0x0004)  # NOMOVE|NOZORDER
    time.sleep(0.9)
    rows.append(cap("6_resized"))

    # 还原
    u.SetWindowPos(hwnd, 0, x, y, w, h, 0x0004)
    time.sleep(0.6)

    # ⑦ 最小化
    u.ShowWindow(hwnd, 6)  # SW_MINIMIZE
    time.sleep(0.9)
    rows.append(cap("7_minimized"))
    u.ShowWindow(hwnd, 9)  # SW_RESTORE
    time.sleep(0.9)

    # 输出
    print(f"{'场景':<14}{'ok':<6}{'method':<22}{'尺寸':<12}{'md5':<14}{'ms':<8}备注")
    print("-" * 100)
    for r in rows:
        note = r.get("err") or ""
        print(f"{r['tag']:<14}{str(r['ok']):<6}{(r['method'] or '-'):<22}{str(r['size']):<12}{r['md5']:<14}{str(r['ms']):<8}{note[:40]}")

    # 判定：同一场景两次捕获是否不同
    print("\n=== 实时性判定（同场景连续两次 PNG 必须不同）===")
    pairs = [("1_visible", "1b_visible"), ("2_partial", "2b_partial"), ("3_full", "3b_full")]
    for a, b in pairs:
        ra = next(r for r in rows if r["tag"] == a)
        rb = next(r for r in rows if r["tag"] == b)
        if ra["ok"] and rb["ok"]:
            print(f"{a:<14} {ra['md5']}  vs  {rb['md5']}  -> {'实时 ✓' if ra['md5'] != rb['md5'] else '旧帧 ✗'}")
        else:
            print(f"{a:<14} 捕获失败，无法判定")

    print(f"\n当前前台：{fg_title()}")


if __name__ == "__main__":
    main()
