#!/bin/bash
# background-targeted-click.sh — 目标在后台时，「坐标投递」必须真的点中
#
# 背景：v0.4.1 记录里有一条「目标非前台时 targeted 静默失败」。
# v0.4.2 用受控夹具重新验证，把它变成可重复的判定：
#   投递成功只是「事件进了进程」，操作成功必须是「UI 真的变了」。
#
# 判据：
#   ① 计数按钮 count 真的 +1
#   ② ok/verified 都是 true（不是靠 ok:true 蒙过去）
#   ③ 用户前台没被顶掉（frontAppPreserved）
#   ④ 物理鼠标没被挪动（physicalCursorPreserved）
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../lib.sh"
source "$HERE/../lib-lab.sh"

echo "== 后台定向点击 =="
lab_need_build || exit 1
lab_start_target || exit 1
trap 'lab_stop; "$BIN" ghost stop >/dev/null 2>&1' EXIT

if ! lab_wait_idle 15; then
  warn "用户正在使用电脑，后台点击结论不可信 → 本轮跳过（SKIPPED，不算通过）"
  summary; exit 0
fi

read -r WID CX CY TPID < <(lab_geom btnCount)
lab_cover_far
FRONT_BEFORE="$(lab_front_bid)"
C0="$(lab_clicks)"
note "目标窗口 $WID  按钮中心 ($CX,$CY)  点击前 count=$C0  前台=$FRONT_BEFORE"

R="$("$BIN" act --window "$WID" --x "$CX" --y "$CY" --mode targeted --json 2>/dev/null)"
[ -z "$R" ] && { bad "act 无返回"; summary; exit 1; }

C1="$(lab_clicks)"
FRONT_AFTER="$(lab_front_bid)"

[ "$C1" -eq "$((C0 + 1))" ] && ok "UI 真的变了：count $C0 → $C1" \
  || bad "UI 没变：count $C0 → ${C1}（投递成功但操作失败）"

[ "$(printf '%s' "$R" | jget "['ok']")" = "True" ] && ok "ok=true（已判定成功）" \
  || bad "ok≠true：$(printf '%s' "$R" | jget "['failureReason']")"

[ "$(printf '%s' "$R" | jget "['method']")" = "targeted" ] && ok "走的确实是 targeted 路径" \
  || bad "method=$(printf '%s' "$R" | jget "['method']")（本用例要求强制坐标投递）"

[ "$(printf '%s' "$R" | jget "['frontAppPreserved']")" = "True" ] && ok "用户前台未被顶掉（${FRONT_BEFORE}）" \
  || bad "前台被改动：$FRONT_BEFORE → $FRONT_AFTER"

[ "$(printf '%s' "$R" | jget "['physicalCursorPreserved']")" = "True" ] && ok "物理鼠标未被挪动" \
  || bad "物理鼠标被挪动了"

VS="$(printf '%s' "$R" | jget "['visibility']['state']")"
note "动手前窗口状态：${VS}（后台可见属正常）"

# —— 反向用例：目标最小化后必须「明确失败」，不能静默 ok ——
# 不能用 osascript 的 set miniaturized（对未声明脚本支持的 App 直接 -10006），
# 所以由夹具自己执行最小化，确保造出来的是真实状态而不是「以为最小化了」。
echo "minimize" > "$LAB_DIR/cmd"
sleep 2.2
VS2="$("$BIN" vis --window "$WID" --json 2>/dev/null | jget "['state']")"
[ "$VS2" = "minimized" ] && ok "可见性判定为 minimized（真实最小化状态）" \
  || warn "最小化后可见性判定为 ${VS2}（期望 minimized）"

C2="$(lab_clicks)"
R2="$("$BIN" act --window "$WID" --x "$CX" --y "$CY" --mode targeted --json 2>/dev/null)"
C3="$(lab_clicks)"
OK2="$(printf '%s' "$R2" | jget "['ok']")"
FR2="$(printf '%s' "$R2" | jget "['failureReason']")"
if [ "$C3" -eq "$C2" ]; then
  [ "$OK2" = "False" ] && ok "最小化后如实报失败（failureReason=${FR2}）" \
    || bad "最小化后点击没生效，却仍然返回 ok=true —— 这就是「静默失败」"
else
  warn "最小化状态下点击仍然生效（count ${C2} → ${C3}）：事件确实进了目标进程，不算失败"
fi
echo "deminimize" > "$LAB_DIR/cmd"
sleep 2.2

summary
