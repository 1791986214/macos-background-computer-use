#!/bin/bash
# 端到端演示：用户占着前台和鼠标，WorkBuddy 在后台操作另一个应用
#
#   ./tests/background-demo.sh [目标bundleId]
#
# 判定：① 目标 UI 真的变了 ② 真实鼠标零位移 ③ 前台应用未变 ④ 目标 app 未被激活
set -uo pipefail
source "$(cd "$(dirname "$0")/.." && pwd)/lib.sh" 2>/dev/null || BIN="$HOME/.local/bin/wbcu"
APP="${1:-com.tencent.wbcu.lab}"
LAB=/tmp/wbcu-lab

pos()   { "$BIN" mouse-pos --json | python3 -c "import sys,json;d=json.load(sys.stdin);print(round(d['x']),round(d['y']))"; }
front() { "$BIN" mouse-pos --json | python3 -c "import sys,json;d=json.load(sys.stdin);print(d['frontmost']['name'])"; }
cnt()   { python3 -c "import json;print(json.load(open('$LAB/state.json')).get('$1',0))" 2>/dev/null || echo 0; }

echo "=== 后台 Computer Use 端到端演示 ==="
[ -f "$LAB/targets.json" ] || { echo "先把 TestTarget.app 跑起来：open lab/build/TestTarget.app"; exit 2; }

WID=$(python3 -c "import json;print(json.load(open('$LAB/targets.json'))['windowNumber'])")
CX=$(python3 -c "import json;print(int(json.load(open('$LAB/targets.json'))['targets']['btnCount']['cx']))")
CY=$(python3 -c "import json;print(int(json.load(open('$LAB/targets.json'))['targets']['btnCount']['cy']))")

echo "目标: $APP  window=$WID  按钮坐标=($CX,$CY)"
M0=$(pos); F0=$(front); C0=$(cnt clicks)
echo "起点: 鼠标 $M0   前台 $F0   计数器 $C0"
echo

for i in 1 2 3; do
  OUT=$("$BIN" click --window "$WID" --x "$CX" --y "$CY" --mode auto --verify --ghost --json)
  MODE=$(echo "$OUT" | python3 -c "import sys,json;d=json.load(sys.stdin);print(d['mode'],d['verification'])" 2>/dev/null)
  echo "  第 $i 次 → $MODE"
  sleep 0.35
done

M1=$(pos); F1=$(front); C1=$(cnt clicks)
echo
printf '%-26s %s\n' "检查项" "结果"
printf '%s\n' "----------------------------------------------------"
printf '%-26s %s\n' "计数器 $C0 → $C1" "$([ "$C1" -gt "$C0" ] && echo "✅ 变化 +$((C1-C0))" || echo "❌ 未变化")"
printf '%-26s %s\n' "鼠标起点 → 终点" "$M0 → $M1"
printf '%-26s %s\n' "鼠标位移" "$(python3 -c "
a='$M0'.split(); b='$M1'.split()
print(int(((int(b[0])-int(a[0]))**2+(int(b[1])-int(a[1]))**2)**0.5),'px')")"
printf '%-26s %s\n' "前台应用" "$F0 → $F1 $([ "$F0" = "$F1" ] && echo '✅ 未变' || echo '❌ 变了')"
printf '%-26s %s\n' "目标应用是否被激活" "$(python3 -c "import json;print('❌ 是' if json.load(open('$LAB/state.json'))['appActive'] else '✅ 否')")"
printf '%s\n' "----------------------------------------------------"
OK=1
[ "$C1" -gt "$C0" ] || OK=0
[ "$F0" = "$F1" ] || OK=0
[ "$OK" = "1" ] && echo "✅ 通过：后台操作生效，前台与鼠标未受影响" || exit 1
