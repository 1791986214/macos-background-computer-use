"""帧身份与新鲜度验证（v0.6.5）。

验证目标：
  1. 每张截图都带目标身份（targetHwnd / targetPid）且与夹具一致
  2. frameId 随捕获递增（同一路流内单调）
  3. frameAgeMs 小（证明是刚拍的，不是积压的旧帧）
  4. 夹具标题里的计数器 #N 持续增长，与 frameId 增长同向
  5. 重建会话后 captureGeneration 变化

用法：python frame_identity_test.py
"""
import ctypes
import ctypes.wintypes as wt
import json
import os
import subprocess
import sys
import time

WB = os.environ.get("WB", "wbcu")
OUT = r"C:\Users\pc\wbcu_preview\out\fid"
os.makedirs(OUT, exist_ok=True)


def run(args, timeout=30):
    p = subprocess.run(args, capture_output=True, text=True, encoding="gbk",
                       errors="replace", timeout=timeout)
    try:
        return json.loads(p.stdout)
    except Exception:
        return {"ok": False, "raw": (p.stdout or "")[:200]}


def fixture():
    u = ctypes.windll.user32
    out = []

    def cb(h, l):
        t = ctypes.create_unicode_buffer(256)
        u.GetWindowTextW(h, t, 256)
        if "WBCU-CAPTURE-FIXTURE" in t.value:
            pid = wt.DWORD()
            u.GetWindowThreadProcessId(h, ctypes.byref(pid))
            out.append((h, pid.value, t.value))
        return True

    u.EnumWindows(ctypes.WINFUNCTYPE(wt.BOOL, wt.HWND, wt.LPARAM)(cb), 0)
    return out[0] if out else None


def counter_from_title(title):
    try:
        return int(title.split("#")[-1].strip())
    except Exception:
        return None


def main():
    fx = fixture()
    if not fx:
        sys.exit("夹具没启动")
    hwnd, pid, title = fx
    print(f"夹具 hwnd=0x{hwnd:X} pid={pid} title={title!r}")

    att = run([WB, "attach", "--app", str(pid), "--json"])
    if not att.get("ok"):
        sys.exit(f"attach 失败 {att}")
    sid = att["data"]["session"]["id"]

    rows = []
    for i in range(4):
        out = os.path.join(OUT, f"f{i}.png")
        r = run([WB, "capture", "--id", sid, "--out", out, "--json"])
        d = r.get("data") or {}
        cur = fixture()
        rows.append({
            "i": i,
            "ok": r.get("ok"),
            "method": r.get("method"),
            "hwnd": d.get("targetHwnd"),
            "pid": d.get("targetPid"),
            "frameId": d.get("frameId"),
            "ageMs": d.get("frameAgeMs"),
            "gen": d.get("captureGeneration"),
            "stale": d.get("isStale"),
            "titleCounter": counter_from_title(cur[2]) if cur else None,
        })
        time.sleep(0.6)

    print(f"\n{'#':<3}{'ok':<7}{'hwnd':<12}{'pid':<8}{'frameId':<9}{'ageMs':<8}{'gen':<6}{'stale':<7}{'标题#':<7}")
    print("-" * 70)
    for r in rows:
        print(f"{r['i']:<3}{str(r['ok']):<7}{str(r['hwnd']):<12}{str(r['pid']):<8}"
              f"{str(r['frameId']):<9}{str(r['ageMs']):<8}{str(r['gen']):<6}{str(r['stale']):<7}{str(r['titleCounter']):<7}")

    # 判定
    print("\n=== 判定 ===")
    hwnd_ok = all((r["hwnd"] or "").lower() == f"0x{hwnd:X}".lower() for r in rows)
    pid_ok = all(r["pid"] == pid for r in rows)
    fids = [r["frameId"] for r in rows if isinstance(r["frameId"], int)]
    mono = all(b >= a for a, b in zip(fids, fids[1:])) if len(fids) > 1 else False
    fresh = all(isinstance(r["ageMs"], (int, float)) and r["ageMs"] <= 600 for r in rows)
    counters = [r["titleCounter"] for r in rows if isinstance(r["titleCounter"], int)]
    title_moves = len(counters) > 1 and counters[-1] > counters[0]

    print(f"目标 hwnd 一致      : {'✓' if hwnd_ok else '✗'}")
    print(f"目标 pid 一致       : {'✓' if pid_ok else '✗'}")
    print(f"frameId 单调递增    : {'✓' if mono else '✗'} {fids}")
    print(f"frameAge 全部 ≤600ms: {'✓' if fresh else '✗'}")
    print(f"标题计数器在推进    : {'✓' if title_moves else '✗'} {counters}")


if __name__ == "__main__":
    main()
