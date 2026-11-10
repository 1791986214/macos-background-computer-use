#!/bin/bash
# record-demo.sh — 录制 Third Hand 实际运行演示（供 README 用）
#
# 原则：
#   1. 只截取目标窗口区域，绝不把用户其他窗口内容录进去（公开仓库）
#   2. 画面里的鼠标坐标、验证状态来自同一次运行的真实采样
#   3. 录完把前台还原，不留副作用
#
# 用法：./scripts/record-demo.sh [输出目录]
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
BIN="${WBCU_BIN:-$REPO/bin/wbcu}"
OUT="${1:-/tmp/thirdhand-frames}"
APP="com.apple.calculator"
WIN_W=240; WIN_H=430          # 计算器窗口 + 内边距
FPS_INTERVAL=0.12             # 目标 ~8fps

rm -rf "$OUT"; mkdir -p "$OUT"

"$BIN" guard --app "$APP" --allow >/dev/null 2>&1
open -g -a Calculator 2>/dev/null
sleep 1.2
"$BIN" window-move --app "$APP" --x 880 --y 240 >/dev/null 2>&1
sleep 0.5

FRAME=$("$BIN" windows --app "$APP" --json 2>/dev/null | python3 -c "
import sys,json
d=json.load(sys.stdin)
for w in d.get('windows',[]):
    if w.get('layer')==0 and w.get('w',0)>100:
        print(int(w['x']), int(w['y']), int(w['w']), int(w['h'])); break
")
read -r WX WY WW WH <<< "$FRAME"
[ -z "${WW:-}" ] && { echo "取不到窗口位置" >&2; exit 1; }
# 只截窗口本身，四周留 4px 阴影边
RX=$((WX-4)); RY=$((WY-4)); RW=$((WW+8)); RH=$((WH+8))
echo "目标窗口 $WX,$WY ${WW}x${WH}  → 录制区域 $RX,$RY ${RW}x${RH}"

# 让目标窗口可见（否则画面被遮挡）。这是录制需要，不是引擎行为。
"$BIN" activate --app "$APP" >/dev/null 2>&1
sleep 0.8

MOUSE0=$("$BIN" idle --json | python3 -c "import sys,json;d=json.load(sys.stdin);print(f\"{d['mouse']['x']:.0f},{d['mouse']['y']:.0f}\")")
IDLE0=$("$BIN" idle --json | python3 -c "import sys,json;print(int(json.load(sys.stdin)['secondsSinceLastInput']))")
echo "基线：真实鼠标 ${MOUSE0}，距上次用户输入 ${IDLE0}s"

# ---- 后台抓帧 ----
(
  i=0
  while [ ! -f "$OUT/.stop" ]; do
    screencapture -x -R"$RX,$RY,$RW,$RH" "$OUT/f$(printf '%03d' $i).png" 2>/dev/null
    i=$((i+1))
  done
) &
CAPPID=$!
sleep 0.5

# ---- 真实操作：建会话 → 清空 → 7+8= ----
SID=$("$BIN" session start --app "$APP" --json | python3 -c "import sys,json;print(json.load(sys.stdin)['session']['id'])")
echo "会话 $SID"
VERIFY=""
for label in "全部清除" "7" "加" "8" "等于"; do
  R=$("$BIN" session click --id "$SID" --text "$label" --exact --label "$label" --json 2>&1)
  MODE=$(echo "$R" | python3 -c "import sys,json;print(json.load(sys.stdin).get('mode','?'))" 2>/dev/null)
  VER=$(echo "$R" | python3 -c "import sys,json;print(json.load(sys.stdin).get('verification','?'))" 2>/dev/null)
  echo "  「${label}」 mode=$MODE verify=$VER"
  VERIFY="$MODE/$VER"
  sleep 0.35
done

V=$("$BIN" session verify --id "$SID" --expect "15" --json 2>&1)
MATCHED=$(echo "$V" | python3 -c "import sys,json;print(json.load(sys.stdin).get('matched'))" 2>/dev/null)
echo "  验证 15 → matched=$MATCHED"

# ---- 停帧，收尾 ----
touch "$OUT/.stop"
wait $CAPPID 2>/dev/null
rm -f "$OUT/.stop"

MOUSE1=$("$BIN" idle --json | python3 -c "import sys,json;d=json.load(sys.stdin);print(f\"{d['mouse']['x']:.0f},{d['mouse']['y']:.0f}\")")
echo "结束：真实鼠标 $MOUSE1"

"$BIN" session end --id "$SID" >/dev/null 2>&1
# 还原前台
osascript -e 'tell application "WorkBuddy" to activate' >/dev/null 2>&1

N=$(ls "$OUT"/*.png 2>/dev/null | wc -l | tr -d ' ')
echo "抓帧 $N 张"
echo "$MOUSE0|$MOUSE1|$VERIFY|$MATCHED|$SID" > "$OUT/meta.txt"
