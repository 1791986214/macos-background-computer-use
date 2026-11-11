#!/bin/bash
# occlusion-behavior.sh — 目标被遮挡时：光标不许画在用户窗口上，结果不许假装成功
#
# 这是 v0.4.2 的核心用例。两条红线：
#   ① 视觉：目标窗口被别的应用盖住时，虚拟光标必须整窗隐藏 ——
#      绝不能把光标画到用户当前正在看的窗口上面。
#   ② 语义：如果点击确实没生效，必须返回 ok=false + failureReason，
#      **禁止** 出现「ok=true 但 uiChanged=false」这种静默失败。
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../lib.sh"
source "$HERE/../lib-lab.sh"

echo "== 遮挡行为 =="
lab_need_build || exit 1
lab_start_target || exit 1
trap 'lab_stop; "$BIN" ghost stop >/dev/null 2>&1' EXIT

if ! lab_wait_idle 15; then
  warn "用户正在使用电脑 → 本轮跳过（SKIPPED，不算通过）"
  summary; exit 0
fi

read -r WID CX CY TPID < <(lab_geom btnCount)
lab_cover_over
note "已用 Cover 窗口完全压住目标窗口 $WID"

# —— ① 可见性判定 ——
V="$("$BIN" vis --window "$WID" --x "$CX" --y "$CY" --json 2>/dev/null)"
STATE="$(printf '%s' "$V" | jget "['state']")"
PV="$(printf '%s' "$V" | jget "['pointVisible']")"
FR="$(printf '%s' "$V" | jget "['visibleFraction']")"
case "$STATE" in
  fully_occluded|partially_occluded) ok "可见性判定正确：${STATE}（可见比例 ${FR}）" ;;
  *) bad "可见性判定错误：state=${STATE}（期望 fully/partially_occluded）" ;;
esac
[ "$PV" = "False" ] && ok "命中点判定为「被遮住」" || bad "命中点仍被判为可见"

# —— ② 光标必须隐藏 ——
"$BIN" ghost start >/dev/null 2>&1
sleep 0.3
A="$("$BIN" act --window "$WID" --x "$CX" --y "$CY" --mode targeted --json 2>/dev/null)"
SUP="$(printf '%s' "$A" | jget "['cursor']['suppressed']")"
[ "$SUP" = "True" ] && ok "目标被遮挡 → 光标整窗隐藏（不会画到用户窗口上）" \
  || bad "目标被遮挡时光标仍然显示（suppressed=${SUP}）"

sleep 0.6
GS="$("$BIN" ghost status --json 2>/dev/null)"
[ "$(printf '%s' "$GS" | jget "['shown']")" = "False" ] && ok "光标窗口确实离屏" \
  || bad "遮挡时光标窗口仍在屏上"

# —— ③ 禁止静默失败 ——
OK="$(printf '%s' "$A" | jget "['ok']")"
CH="$(printf '%s' "$A" | jget "['uiChanged']")"
RS="$(printf '%s' "$A" | jget "['failureReason']")"
if [ "$OK" = "True" ] && [ "$CH" = "False" ]; then
  bad "静默失败：ok=true 但 uiChanged=false（failureReason=${RS}）"
elif [ "$OK" = "False" ]; then
  [ -n "$RS" ] && ok "如实上报失败：$RS" || bad "失败但没给原因"
else
  ok "遮挡下依然点中（AppKit 进程级投递不受遮挡影响），且已通过验证"
fi

# —— ④ 恢复：遮挡解除后光标应重新可见 ——
pkill -f "$LAB_COVER_APP/Contents/MacOS/Cover" 2>/dev/null
sleep 0.6
A2="$("$BIN" act --window "$WID" --x "$CX" --y "$CY" --mode targeted --json 2>/dev/null)"
SUP2="$(printf '%s' "$A2" | jget "['cursor']['suppressed']")"
[ "$SUP2" = "False" ] && ok "遮挡解除后光标恢复显示" || bad "遮挡解除后光标仍未显示"

summary
