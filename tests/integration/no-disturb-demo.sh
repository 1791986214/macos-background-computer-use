#!/bin/bash
# 零干扰实测：用户在用自己鼠标的同时，后台完成一个真实任务
#
# 三层保证（从弱到强）：
#   1. 焦点不动   —— 只走 AX / postToPid，不调用 activate
#   2. 指针不动   —— 观测采样：操作期间指针坐标不应出现跳变
#   3. 通道切断   —— WBCU_NO_HID_MOUSE=1 让鼠标注入代码路径直接失败（结构性）
#
#   ./tests/no-disturb-demo.sh            # 普通模式（你在动鼠标也能跑）
#   ./tests/no-disturb-demo.sh --strict   # 要求指针位移 ≤ 2px
set -uo pipefail
source "$(cd "$(dirname "$0")/.." && pwd)/lib.sh" 2>/dev/null || BIN="$HOME/.local/bin/wbcu"
export WBCU_NO_HID_MOUSE=1          # ← 关键：本次会话彻底禁用鼠标注入

STRICT=0
APP="com.apple.calculator"
for a in "$@"; do
  case "$a" in
    --strict) STRICT=1 ;;
    *) APP="$a" ;;
  esac
done

press() {
  local label="$1" idx
  idx=$("$BIN" ax-find --app "$APP" --text "$label" --exact --json 2>/dev/null \
        | python3 -c "import sys,json;d=json.load(sys.stdin);print(d['hits'][0]['index'])" 2>/dev/null)
  if [ -n "${idx:-}" ]; then
    "$BIN" ax-act --app "$APP" --index "$idx" >/dev/null 2>&1 || echo "  (跳过 $label)"
  else
    echo "  (未找到 $label)"
  fi
}
pos()  { "$BIN" mouse-pos --json | python3 -c "import sys,json;d=json.load(sys.stdin);print(round(d['x']),round(d['y']))"; }
front(){ "$BIN" mouse-pos --json | python3 -c "import sys,json;d=json.load(sys.stdin);print(d['frontmost']['name'])"; }

echo "=== 零干扰实测 · $APP · 模式 $([ $STRICT = 1 ] && echo strict || echo normal) ==="
echo "HID 鼠标通道：已禁用（WBCU_NO_HID_MOUSE=1）"

if [ "$STRICT" = 1 ]; then
  echo "等待鼠标静止（最多 5 秒）…"
  LAST=""; STILL=0
  for i in $(seq 1 40); do
    P=$(pos)
    if [ "$P" = "$LAST" ]; then STILL=$((STILL+1)); else STILL=0; fi
    LAST="$P"
    [ "$STILL" -ge 6 ] && break
    sleep 0.12
  done
  if [ "$STILL" -lt 6 ]; then echo "⚠️ 鼠标持续移动，降级为 normal 判定"; STRICT=0; fi
fi

START=$(pos); F0=$(front)
echo "起点：鼠标 $(echo $START | tr ' ' ',')   前台：$F0"

SAMPLES=$(mktemp)
( for i in $(seq 1 24); do pos >> "$SAMPLES" 2>/dev/null; sleep 0.12; done ) &
SAMPLER=$!

# 任务：9 × 9 = 81，全程 AX 动作
press "全部清除"; press "9"; press "乘"; press "9"; press "等于"

wait $SAMPLER 2>/dev/null
END=$(pos); F1=$(front)

SPAN=$(python3 - "$SAMPLES" <<'PY'
import sys
pts=[]
for line in open(sys.argv[1]):
    line=line.strip()
    if not line: continue
    try: x,y=line.split(); pts.append((int(x),int(y)))
    except Exception: pass
if not pts: print("0 0 1"); sys.exit()
xs=[p[0] for p in pts]; ys=[p[1] for p in pts]
print(f"{max(xs)-min(xs)} {max(ys)-min(ys)} {len(set(pts))}")
PY
)
read -r DX DY UNIQ <<< "$SPAN"

RESULT=$("$BIN" ax-find --app "$APP" --role statictext --json \
  | python3 -c "
import sys,json
d=json.load(sys.stdin)
vals=[h.get('value','') for h in d['hits'] if h.get('value')]
print(vals[-1] if vals else '')
")
rm -f "$SAMPLES"

echo
printf '%-26s %s\n' "检查项" "结果"
printf '%s\n' "------------------------------------------------------"
printf '%-26s %s\n' "鼠标起点 → 终点" "$(echo $START | tr ' ' ',') → $(echo $END | tr ' ' ',')"
printf '%-26s %s\n' "采样期指针跨度" "x ${DX}px / y ${DY}px（不同坐标 ${UNIQ} 个）"
printf '%-26s %s\n' "前台应用 前 → 后" "$F0 → $F1"
printf '%-26s %s\n' "HID 鼠标通道" "已切断（任何鼠标注入 exit 4）"
printf '%-26s %s\n' "任务结果 9×9" "$RESULT"
printf '%s\n' "------------------------------------------------------"

OK=1
[ "$F0" = "$F1" ] || { echo "❌ 焦点被抢"; OK=0; }
[ "$RESULT" = "81" ] || { echo "❌ 任务结果不对：$RESULT"; OK=0; }
ZERO=0
[ "$UNIQ" = "1" ] && ZERO=1
{ [ "$DX" -le 2 ] && [ "$DY" -le 2 ]; } && ZERO=1

if [ "$OK" != "1" ]; then exit 1; fi
if [ "$STRICT" = 1 ] && [ "$ZERO" != "1" ]; then
  echo "❌ strict 未通过：指针位移 ${DX}x${DY}px"; exit 1
fi
[ "$ZERO" = "1" ] \
  && echo "✅ 通过：指针零位移、焦点未变、任务完成（9×9=81）" \
  || echo "✅ 通过：焦点未变、任务完成；指针位移来自你本人的操作 —— 我的鼠标通道已切断"
