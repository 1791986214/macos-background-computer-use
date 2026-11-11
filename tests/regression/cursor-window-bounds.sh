#!/bin/bash
# cursor-window-bounds.sh — 虚拟光标必须是「小窗口」，不能是整屏透明面板
#
# 回归目标（v0.4.1 的实际缺陷）：
#   Ghost.swift 里 `contentRect: screen.frame` + `GhostView(frame: screen.frame)`，
#   等于在用户前台窗口上面挂了一层全屏透明窗口。视觉上是「虚拟鼠标在我前台乱飞」。
#
# 判据（三条同时成立才算通过）：
#   ① 光标窗口尺寸 = 126×126（对齐 Codex Software Cursor 实测值）
#   ② 光标尖端落在光标窗口内部（画的和点的必须是同一个像素）
#   ③ 光标窗口面积远小于屏幕，且任一时刻都能被整窗隐藏
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../lib.sh"
source "$HERE/../lib-lab.sh"

echo "== 虚拟光标窗口边界 =="
lab_need_build || exit 1
lab_start_target || exit 1
trap 'lab_stop; "$BIN" ghost stop >/dev/null 2>&1' EXIT

read -r WID CX CY TPID < <(lab_geom btnCount)
note "目标窗口 $WID  按钮中心 ($CX,$CY)"

"$BIN" ghost stop >/dev/null 2>&1
"$BIN" ghost start >/dev/null 2>&1
sleep 0.4

ST="$("$BIN" ghost goto --x "$CX" --y "$CY" --json 2>/dev/null)"
[ -z "$ST" ] && { bad "ghost goto 无返回"; summary; exit 1; }

W="$(printf '%s' "$ST" | jget "['winW']")"
H="$(printf '%s' "$ST" | jget "['winH']")"
GX="$(printf '%s' "$ST" | jget "['winCGX']")"
GY="$(printf '%s' "$ST" | jget "['winCGY']")"
SHOWN="$(printf '%s' "$ST" | jget "['shown']")"

[ "$W" = "126" ] && [ "$H" = "126" ] && ok "光标窗口 126×126" \
  || bad "光标窗口尺寸 ${W}×${H}（期望 126×126）"

python3 - "$CX" "$CY" "$GX" "$GY" "$W" "$H" <<'PY' && ok "光标尖端落在窗口内（$GX,$GY ${W}×${H}）" || bad "光标尖端不在窗口内：点($CX,$CY) 窗口($GX,$GY ${W}×${H})"
import sys
cx,cy,gx,gy,w,h=[float(x) for x in sys.argv[1:7]]
sys.exit(0 if (gx-1 <= cx <= gx+w+1 and gy-1 <= cy <= gy+h+1) else 1)
PY

python3 - "$W" "$H" <<'PY' && ok "光标窗口面积远小于全屏（不构成全屏覆盖层）" || bad "光标窗口过大"
import sys
w,h=float(sys.argv[1]),float(sys.argv[2])
# 4K 屏幕约 3840x2160；126×126 ≈ 0.2%。阈值放到 300×300 仍算「小窗口」
sys.exit(0 if w*h <= 300*300 else 1)
PY

[ "$SHOWN" = "True" ] && ok "光标已显示" || bad "光标未显示（shown=${SHOWN}）"

# —— 显式隐藏 ——
"$BIN" ghost hide >/dev/null 2>&1
sleep 0.3
S2="$("$BIN" ghost status --json 2>/dev/null)"
[ "$(printf '%s' "$S2" | jget "['shown']")" = "False" ] && ok "ghost hide 后整窗隐藏" \
  || bad "ghost hide 后窗口仍在屏上"

# —— 空闲自动隐藏（对齐 Codex：空闲时 onscreen=false）——
"$BIN" ghost goto --x "$CX" --y "$CY" --json >/dev/null 2>&1
sleep 2.6
S3="$("$BIN" ghost status --json 2>/dev/null)"
[ "$(printf '%s' "$S3" | jget "['shown']")" = "False" ] && ok "空闲 1.8s 后自动隐藏" \
  || bad "空闲后光标仍挂在屏幕上"

# —— 屏幕边缘：窗口必须夹在屏内，且尖端仍指向真实点 ——
EDGE="$("$BIN" ghost goto --x 2 --y 2 --json 2>/dev/null)"
EGX="$(printf '%s' "$EDGE" | jget "['winCGX']")"
EGY="$(printf '%s' "$EDGE" | jget "['winCGY']")"
python3 - "$EGX" "$EGY" <<'PY' && ok "贴边时窗口被夹在屏幕内" || bad "贴边时窗口越界（$EGX,${EGY}）"
import sys
gx,gy=float(sys.argv[1]),float(sys.argv[2])
sys.exit(0 if gx >= 0 and gy >= 0 else 1)
PY

summary
