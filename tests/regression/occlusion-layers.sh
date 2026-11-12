#!/bin/bash
# occlusion-layers.sh — 遮挡判定的层级覆盖（v0.4.3 新增）
#
# 针对 v0.4.2 的漏判：旧规则 `layer == target.layer` 只看同层窗口，
# 高层级浮层（NSPanel .floating / Popover / Tooltip）压在目标上时被直接忽略，
# 于是报告「可见」，光标就画到了用户眼前。
#
# 设计要点：全部用**非激活的浮层面板**制造遮挡。
#   · 面板 orderFrontRegardless 不激活自己 → 目标仍在前台，遮挡关系确定
#   · 普通窗口会把目标顶到后面，用户自己的窗口（Edge / 企业微信）也会参与遮挡，
#     变量太多、结论不可复现 —— 所以不用它来断言可见比例
#
# 覆盖：
#   ① layer=3 浮层完全遮挡     ② layer=8 更高的浮层
#   ③ 只盖下半部分（部分遮挡） ④ 同一应用的第二个窗口
#   ⑤ 遮挡时光标抑制，但坐标投递仍然命中
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../lib.sh"
source "$HERE/../lib-lab.sh"

echo "== 遮挡判定的层级覆盖 =="
lab_need_build || exit 1
lab_start_target || exit 1
trap 'lab_stop; "$BIN" ghost stop >/dev/null 2>&1' EXIT

read -r WID CX CY TPID < <(lab_geom btnCount)
read -r WX WY WW WH < <(python3 - "$LAB_DIR/targets.json" <<'PY'
import json,sys
f=json.load(open(sys.argv[1]))["windowCGFrame"]
print(int(f["X"]),int(f["Y"]),int(f["Width"]),int(f["Height"]))
PY
)
LOCALX=$(( CX - WX )); LOCALY=$(( CY - WY ))
note "目标窗口 ${WID} (${WX},${WY} ${WW}x${WH})，点击点局部坐标 (${LOCALX},${LOCALY})"

occ() { "$BIN" occlusion --window "$WID" --x "$CX" --y "$CY" --json 2>/dev/null; }
j() { python3 -c "import sys,json;d=json.load(sys.stdin);print(eval('d'+sys.argv[1],{},{'d':d}))" "$1"; }
# 关掉所有遮挡面板，并**确认真的关掉了**再往下走。
# 只 pkill + sleep 是不够的：窗口销毁有延迟，上一个面板还没消失就开始量下一个，
# 会把「上一个面板」的遮挡算到「这一个」头上（实测出现过假失败）。
kill_cover() {
  pkill -f "$LAB_COVER_APP/Contents/MacOS/Cover" 2>/dev/null
  for _ in $(seq 1 15); do
    local left
    left="$(occ | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin)
except Exception:
    print(0); raise SystemExit
print(sum(1 for c in d.get('stack',[]) if c.get('owner')=='Cover'))" 2>/dev/null)"
    [ "${left:-0}" = "0" ] && return 0
    sleep 0.2
  done
  pkill -9 -f "$LAB_COVER_APP/Contents/MacOS/Cover" 2>/dev/null
  sleep 0.3
}
panel() { open -n "$LAB_COVER_APP" --args --rect "$1" --label "$2" --level "$3" --panel; sleep 1.0; }

# 基线必须是「目标前台且可见」，否则「加了浮层更遮挡」这件事无法证明（本来就被挡着）
kill_cover
BASE_STATE=""
BASE_FRAC=""
for _ in 1 2 3; do
  lab_front_target
  B="$(occ)"
  BASE_STATE="$(printf '%s' "$B" | j "['state']")"
  BASE_FRAC="$(printf '%s' "$B" | j "['visibleFraction']")"
  [ "$BASE_STATE" = "front" ] && break
  sleep 0.6
done
note "基线：state=${BASE_STATE} 可见=${BASE_FRAC}"
if [ "$BASE_STATE" != "front" ]; then
  warn "基线不是 front（用户窗口正在参与遮挡）→ 层级遮挡的可见比例断言 Not Tested，仅跑光标与投递部分"
fi

# ---------- ① layer=3 浮层完全遮挡 ----------
if [ "$BASE_STATE" = "front" ]; then
panel "$WX,$WY,$WW,$WH" "Float3" 3
O="$(occ)"
S="$(printf '%s' "$O" | j "['state']")"; FR="$(printf '%s' "$O" | j "['visibleFraction']")"
PB="$(printf '%s' "$O" | j "['pointBlockedByConfident']")"
case "$S" in fully_occluded|partially_occluded) ok "① layer=3 浮层被计入遮挡（${S}，可见 ${FR}）" ;;
  *) bad "① layer=3 浮层被漏判：state=${S} visible=${FR}" ;; esac
[ "$PB" = "True" ] && ok "① 命中点被判为被覆盖" || bad "① 命中点未判为覆盖"
kill_cover
else
  warn "① 跳过（基线非前台）"
fi

# ---------- ② layer=8 更高的浮层 ----------
if [ "$BASE_STATE" = "front" ]; then
panel "$WX,$WY,$WW,$WH" "Float8" 8
O="$(occ)"
S="$(printf '%s' "$O" | j "['state']")"; FR="$(printf '%s' "$O" | j "['visibleFraction']")"
case "$S" in fully_occluded|partially_occluded) ok "② layer=8 浮层被计入遮挡（${S}，可见 ${FR}）" ;;
  *) bad "② layer=8 浮层被漏判：state=${S}" ;; esac
kill_cover
else
  warn "② 跳过（基线非前台）"
fi

# ---------- ③ 只盖下半部分：部分遮挡 ----------
if [ "$BASE_STATE" = "front" ]; then
HALF=$(( WH / 2 ))
panel "$WX,$(( WY + HALF )),$WW,$HALF" "Half" 3
O="$(occ)"
S="$(printf '%s' "$O" | j "['state']")"; FR="$(printf '%s' "$O" | j "['visibleFraction']")"
python3 - "$S" "$FR" <<'PY' && ok "③ 部分遮挡被识别（state=${S}，可见 ${FR}）" || bad "③ 部分遮挡失真：state=${S} visible=${FR}"
import sys
s, fr = sys.argv[1], float(sys.argv[2])
sys.exit(0 if s == "partially_occluded" and fr < 0.95 else 1)
PY
# 命中点在未盖住的上半部分 → 应判为可见
OX="$(occ)"
PT="$(printf '%s' "$OX" | j "['pointBlockedByConfident']")"
[ "$PT" = "False" ] && ok "③ 未盖住的命中点判为可见" || bad "③ 未盖住的点被判为遮挡"
kill_cover
else
  warn "③ 跳过（基线非前台）"
fi

# ---------- ④ 同一应用的第二个窗口 ----------
echo "secondWindow" > "$LAB_DIR/cmd"; sleep 2.2
O="$(occ)"
AFW="$(printf '%s' "$O" | j "['targetIsAppFrontWindow']")"
[ "$AFW" = "False" ] && ok "④ 识别出「目标上方有本应用的其它窗口」" \
  || bad "④ 未识别出同应用窗口遮挡（targetIsAppFrontWindow=${AFW}）"
echo "closeSecond" > "$LAB_DIR/cmd"; sleep 2.2

# ---------- ⑤ 遮挡下：光标抑制 + 点击仍然命中 ----------
panel "$WX,$WY,$WW,$WH" "Blocker" 3
G="$("$BIN" ghost goto --window "$WID" --localX "$LOCALX" --localY "$LOCALY" --json 2>/dev/null)"
SUP="$(printf '%s' "$G" | j "['suppressed']")"
[ "$SUP" = "True" ] && ok "⑤ 遮挡时光标被抑制（不会画到前台窗口上）" || bad "⑤ 遮挡时光标仍显示（suppressed=${SUP}）"
BEFORE="$(lab_clicks)"
R="$("$BIN" act --window "$WID" --x "$CX" --y "$CY" --mode targeted --json 2>/dev/null)"
AFTER="$(lab_clicks)"
[ "$AFTER" -eq "$((BEFORE + 1))" ] && ok "⑤ 遮挡下坐标投递仍然命中（count ${BEFORE}→${AFTER}）" \
  || bad "⑤ 遮挡下点击丢失（count ${BEFORE}→${AFTER}）"
[ "$(printf '%s' "$R" | j "['delivered']")" = "True" ] && ok "⑤ 事件确实投递到目标进程" || bad "⑤ 未投递"
kill_cover
"$BIN" ghost hide >/dev/null 2>&1

summary
