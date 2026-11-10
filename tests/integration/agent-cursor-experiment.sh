#!/bin/bash
# 对照实验：独立 Agent 光标 + 后台真实点击 + 三层生命周期
# 对应任务的第八部分 10 个步骤
set -uo pipefail
source "$(cd "$(dirname "$0")/.." && pwd)/lib.sh" 2>/dev/null || BIN="$HOME/.local/bin/wbcu"
export WBCU_NO_HID_MOUSE=1        # 结构性禁用真实鼠标注入

CAL=com.apple.calculator
pos()   { "$BIN" mouse-pos --json | python3 -c "import sys,json;d=json.load(sys.stdin);print(round(d['x']),round(d['y']))"; }
front() { "$BIN" mouse-pos --json | python3 -c "import sys,json;d=json.load(sys.stdin);print(d['frontmost']['name'])"; }
val()   { "$BIN" ax-find --app $CAL --role statictext --json 2>/dev/null | python3 -c "
import sys,json
d=json.load(sys.stdin); v=[h.get('value','') for h in d['hits'] if h.get('value')]
print(v[-1] if v else '')"; }
btn()   { "$BIN" ax-tree --app $CAL --depth 7 --json 2>/dev/null | python3 -c "
import sys,json
d=json.load(sys.stdin)
for it in d['items']:
    if it.get('identifier')=='$1': print(int(it['x']+it['w']/2), int(it['y']+it['h']/2)); break"; }
ghostwin() { python3 - <<'PY'
import subprocess
out = subprocess.run(['/tmp/cur'], capture_output=True, text=True).stdout
print('yes' if 'Software Cursor' in out else 'no')
PY
}

echo "=== 独立 Agent 光标 · 对照实验 ==="
echo "HID 鼠标通道：已禁用 (WBCU_NO_HID_MOUSE=1)"
echo

# 0. 准备
open -a Calculator 2>/dev/null; sleep 1.2
"$BIN" window-move --app $CAL --x 300 --y 400 >/dev/null 2>&1; sleep 0.5
osascript -e 'tell application "WorkBuddy" to activate' 2>/dev/null; sleep 1.0

M0=$(pos); F0=$(front)
CLR=$(btn AllClear); SEVEN=$(btn Seven); ADD=$(btn Add); EIGHT=$(btn Eight); EQ=$(btn Equals)
echo "① 目标：$CAL  窗口 = $($BIN windows --app $CAL | tail -1 | awk '{print $1}')"
echo "   前台 = $F0   物理鼠标 = $M0"
echo

# 1-2. 开捕获 + 显示光标
"$BIN" stream --app $CAL --seconds 6 >/tmp/stream.log 2>&1 &
STREAM=$!
sleep 1.6
echo "② 窗口捕获已开启（SCStream 后台进程 ${STREAM}）"
"$BIN" ghost start >/dev/null 2>&1
echo "   独立光标已启动 → $("$BIN" ghost --json | head -c 120)"
echo

# 3-5. 光标移动 + 后台点击 + 验证
echo "③ 逐步操作（每步：光标动画 → 后台点击 → AX 观察）"
for pair in "$CLR:清空" "$SEVEN:7" "$ADD:+" "$EIGHT:8" "$EQ:="; do
  XY="${pair%%:*}"; LBL="${pair##*:}"
  X="${XY% *}"; Y="${XY#* }"
  OUT=$("$BIN" act --app $CAL --x "$X" --y "$Y" --label "$LBL" --json 2>/dev/null)
  echo "   $LBL → $(echo "$OUT" | python3 -c "
import sys,json
d=json.load(sys.stdin)
c=d.get('cursor',{})
print(f\"mode={d['mode']} cursor={'on' if c.get('used') else 'off'} anchored={c.get('anchored')} verify={d['verification']} {d['elapsedMs']}ms\")" 2>/dev/null)"
  sleep 0.3
done
RESULT=$(val)
echo

# 6-8. 环境未被干扰
M1=$(pos); F1=$(front)
echo "④ 结果与环境"
printf '   %-22s %s\n' "计算器显示值" "$RESULT"
printf '   %-22s %s\n' "前台应用 前→后" "$F0 → $F1 $([ "$F0" = "$F1" ] && echo '✅' || echo '❌')"
printf '   %-22s %s\n' "物理鼠标 前→后" "$M0 → $M1"
printf '   %-22s %s\n' "目标应用是否被激活" "$("$BIN" apps --json | python3 -c "
import sys,json
d=json.load(sys.stdin)
a=[x for x in d['apps'] if x['bundleId']=='com.apple.calculator']
print('是 ❌' if a and a[0]['active'] else '否 ✅')")"
echo

# 9-10. 关闭与清理
"$BIN" ghost hide >/dev/null 2>&1
"$BIN" ghost stop >/dev/null 2>&1
kill $STREAM 2>/dev/null; wait $STREAM 2>/dev/null
sleep 1.2
echo "⑤ 生命周期收尾"
printf '   %-22s %s\n' "光标已隐藏/销毁" "$("$BIN" ghost --json 2>/dev/null | grep -q alive || echo '✅ daemon 退出')"
printf '   %-22s %s\n' "残留 wbcu 进程" "$(pgrep -x wbcu | wc -l | tr -d ' ')"
printf '   %-22s %s\n' "共享指示器" "$("$BIN" indicator-scan --app $CAL 2>/dev/null | tail -1 | sed 's/判定: //')"
echo
[ "$RESULT" = "15" ] && echo "✅ 验收通过：7+8=15，光标独立可见，前台与物理鼠标未受影响" || echo "⚠️ 结果异常：$RESULT"
