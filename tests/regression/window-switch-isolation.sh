#!/bin/bash
# window-switch-isolation.sh — 用户切窗口不能影响点击，点击也不能影响用户
#
# 用户原话：「我切换窗口还会影响你点击，这没道理」。
# 这条用例就是给这句话立的规矩：
#   用户在点击途中切走前台 → 点击仍然落在目标进程的目标窗口上；
#   wbcu 自己始终不进入前台；物理鼠标一动不动。
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../lib.sh"
source "$HERE/../lib-lab.sh"

echo "== 切窗口隔离性 =="
lab_need_build || exit 1
lab_start_target || exit 1
trap 'lab_stop; "$BIN" ghost stop >/dev/null 2>&1' EXIT

if ! lab_wait_idle 15; then
  warn "用户正在使用电脑 → 本轮跳过（SKIPPED，不算通过）"
  summary; exit 0
fi

read -r WID CX CY TPID < <(lab_geom btnCount)
lab_cover_far
C0="$(lab_clicks)"
FRONT0="$(lab_front_bid)"
note "点击前 count=$C0  前台=$FRONT0"

# 点击发出的同时，把目标 App 拉到前台 —— 模拟用户正在切窗口
( "$BIN" act --window "$WID" --x "$CX" --y "$CY" --mode targeted --json > /tmp/wbcu-switch.json 2>/dev/null ) &
ACTPID=$!
sleep 0.04
osascript -e "tell application id \"$LAB_TARGET_BID\" to activate" >/dev/null 2>&1
wait "$ACTPID" 2>/dev/null || true
sleep 0.4

C1="$(lab_clicks)"
FRONT1="$(lab_front_bid)"
R="$(cat /tmp/wbcu-switch.json 2>/dev/null)"

[ "$C1" -eq "$((C0 + 1))" ] && ok "切换窗口途中点击仍然命中：count $C0 → $C1" \
  || bad "切换窗口导致点击丢失：count $C0 → $C1"

# wbcu 自己（含覆盖层）绝不能出现在前台。
# 注意：不能用 *wbcu* 通配，夹具自己的 bundle id 就是 com.tencent.wbcu.cover，
# 会把「正常」误判成「抢前台」。
case "$FRONT1" in
  com.workbuddy.thirdhand.overlay|ThirdHandOverlay)
    bad "wbcu 覆盖层抢到了前台（${FRONT1}）" ;;
  "")
    warn "取不到前台应用（可能无辅助功能授权），本条未验证" ;;
  *)
    ok "前台始终是用户自己的应用（${FRONT1}）" ;;
esac

if [ -n "$R" ]; then
  [ "$(printf '%s' "$R" | jget "['physicalCursorPreserved']")" = "True" ] \
    && ok "物理鼠标未动" || bad "物理鼠标被挪动"
else
  warn "点击进程未回写结果（并发时序），本条以计数变化为准"
fi

# —— 锚定稳定性：前台切换后，同一个窗口锚点必须算出同一个全局点 ——
"$BIN" ghost start >/dev/null 2>&1
sleep 0.3
G1="$("$BIN" ghost goto --x "$CX" --y "$CY" --json 2>/dev/null)"
osascript -e "tell application id \"$LAB_TARGET_BID\" to activate" >/dev/null 2>&1
sleep 0.5
G2="$("$BIN" ghost status --json 2>/dev/null)"
X1="$(printf '%s' "$G1" | jget "['tipX']")"; Y1="$(printf '%s' "$G1" | jget "['tipY']")"
X2="$(printf '%s' "$G2" | jget "['tipX']")"; Y2="$(printf '%s' "$G2" | jget "['tipY']")"
[ "$X1" = "$X2" ] && [ "$Y1" = "$Y2" ] && ok "前台切换后光标位置不变（$X1,${Y1}）" \
  || bad "前台切换导致光标漂移：(X1,$Y1)=($X1,$Y1) → ($X2,$Y2)"

summary
