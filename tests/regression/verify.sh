#!/bin/bash
# wbcu 验收矩阵：把「能否显示系统指示器」和「能否实际控制应用」分开验证
# 用法: ./tests/verify.sh [app-bundle-id]
set -uo pipefail
source "$(cd "$(dirname "$0")/.." && pwd)/lib.sh" 2>/dev/null || BIN="$HOME/.local/bin/wbcu"
APP="${1:-com.apple.calculator}"
PASS=0; FAIL=0; ROWS=()

check() { # name expected actual
  local name="$1" exp="$2" act="$3"
  if [ "$exp" = "$act" ]; then ROWS+=("✅|$name|$act"); PASS=$((PASS+1));
  else ROWS+=("❌|$name|期望 $exp 实得 $act"); FAIL=$((FAIL+1)); fi
}

json() { "$BIN" "$@" --json 2>/dev/null; }
field() { python3 -c "import sys,json;d=json.load(sys.stdin);print(d$1)" 2>/dev/null; }

echo "== 探针目标: $APP =="
PID=$(json apps | python3 -c "
import sys,json
d=json.load(sys.stdin)
for a in d['apps']:
    if a['bundleId']=='$APP': print(a['pid']); break
")
[ -z "$PID" ] && { echo "应用未运行: $APP"; exit 1; }

# 1. TCC 三态
P=$(json perm)
check "辅助功能授权" "True" "$(echo "$P" | field "['accessibility']")"
check "屏幕录制授权" "True" "$(echo "$P" | field "['screenRecording']")"
check "输入注入授权" "True" "$(echo "$P" | field "['postEvent']")"

# 2. 发现能力
check "应用发现" "True" "$(json apps | field "['ok']")"
WID=$(json windows --app "$APP" | field "['windows'][0]['windowId']")
check "窗口发现" "True" "$([ -n "$WID" ] && echo True || echo False)"

# 3. AX 读取
T=$(json ax-tree --app "$APP" --max 200)
check "AX 树读取" "True" "$(echo "$T" | field "['ok']")"
N=$(echo "$T" | field "['count']")
ROWS+=("ℹ️|AX 节点数|$N")

# 4. AX 操作（后台，不抢焦点）：算出 7+8
CLR=$("$BIN" ax-find --app "$APP" --text "全部清除" --json | python3 -c "import sys,json;print(json.load(sys.stdin)['hits'][0]['index'])" 2>/dev/null)
[ -n "$CLR" ] && "$BIN" ax-act --app "$APP" --index "$CLR" >/dev/null 2>&1
for L in "7" "加" "8" "等于"; do
  I=$("$BIN" ax-find --app "$APP" --text "$L" --json | python3 -c "import sys,json;print(json.load(sys.stdin)['hits'][0]['index'])" 2>/dev/null)
  [ -n "$I" ] && "$BIN" ax-act --app "$APP" --index "$I" >/dev/null 2>&1
done
sleep 0.5
RES=$(json ax-find --app "$APP" --role statictext | python3 -c "
import sys,json
d=json.load(sys.stdin)
vals=[h.get('value','') for h in d['hits'] if h.get('value')]
print(vals[-1] if vals else '')
")
check "AX 后台操作 (7+8)" "15" "$RES"

# 5. 键盘注入（后台）：4+5
"$BIN" key "Escape" --app "$APP" >/dev/null 2>&1
"$BIN" key "4" --app "$APP" >/dev/null 2>&1
"$BIN" key "shift+equal" --app "$APP" >/dev/null 2>&1
"$BIN" key "5" --app "$APP" >/dev/null 2>&1
"$BIN" key "Return" --app "$APP" >/dev/null 2>&1
sleep 0.5
RES2=$(json ax-find --app "$APP" --role statictext | python3 -c "
import sys,json
d=json.load(sys.stdin)
vals=[h.get('value','') for h in d['hits'] if h.get('value')]
print(vals[-1] if vals else '')
")
check "键盘后台注入 (4+5)" "9" "$RES2"

# 6. 窗口截图
SHOT=$("$BIN" shot --app "$APP" --out /tmp/wbcu-verify.png --analyze --json)
check "窗口级单帧截图" "True" "$(echo "$SHOT" | field "['ok']")"
check "单帧截图不触发指示器" "0" "$(echo "$SHOT" | field "['purplePixels']")"

# 7. 持续捕获 → 指示器
EXP=$("$BIN" indicator-exp --app "$APP" --seconds 4 --json)
check "SCStream 持续捕获启动" "True" "$(echo "$EXP" | field "['captureStarted']")"
check "捕获中出现指示器(AX)" "1" "$(echo "$EXP" | field "['duringCapture']['axShares']")"
check "捕获中 AX 窗口数+1" "2" "$(echo "$EXP" | field "['duringCapture']['axWindowCount']")"
check "停止后指示器消失(AX)" "0" "$(echo "$EXP" | field "['afterStop']['axShares']")"
check "停止后 AX 窗口数还原" "1" "$(echo "$EXP" | field "['afterStop']['axWindowCount']")"
PB=$(echo "$EXP" | field "['duringCapture']['purple']")
if [ "$PB" -gt 100 ] 2>/dev/null; then ROWS+=("✅|捕获中标题栏紫色像素|$PB"); PASS=$((PASS+1)); else ROWS+=("⚠️|捕获中标题栏紫色像素|$PB（窗口可能被遮挡）"); fi

# 8. 资源释放
check "无残留 wbcu 进程" "" "$(pgrep -x wbcu | tr -d '[:space:]')"

echo
printf '%-4s %-32s %s\n' "" "检查项" "结果"
printf '%s\n' "------------------------------------------------------------"
for r in "${ROWS[@]}"; do IFS='|' read -r a b c <<< "$r"; printf '%-4s %-32s %s\n' "$a" "$b" "$c"; done
printf '%s\n' "------------------------------------------------------------"
echo "通过 $PASS / 失败 $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
