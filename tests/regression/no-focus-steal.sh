#!/bin/bash
# 回归测试：Third Hand 的任何一步都不许抢用户前台
#
# 背景（真实事故）：ghost daemon 是个 NSApplication，启动瞬间被系统激活，
# 用户前台从 WorkBuddy 变成 wbcu。用户会直接感受到「被抢」。
# 修法：启动前记住前台 App，daemon 就绪后把它重新激活。
# 这个测试盯着这件事，防止再犯。
set -uo pipefail
source "$(cd "$(dirname "$0")/.." && pwd)/lib.sh"

APP="com.apple.calculator"
echo "== 回归：不抢前台 =="
note "二进制: $BIN"

require_desktop || { summary; exit 0; }

open -g -a "$APP" 2>/dev/null
sleep 1.5
"$BIN" guard --app "$APP" --allow >/dev/null 2>&1

front() { "$BIN" idle --json 2>/dev/null | python3 -c "import sys,json;print(json.load(sys.stdin)['frontmost']['name'])" 2>/dev/null; }

# 把前台固定到 WorkBuddy，作为「用户正在用它」的基线
osascript -e 'tell application "WorkBuddy" to activate' >/dev/null 2>&1
sleep 1.2
BASE=$(front)
[ -z "$BASE" ] && { bad "取不到前台应用"; summary; exit 1; }
T0=$(date +%s)
IDLE0=$("$BIN" idle --json 2>/dev/null | python3 -c "import sys,json;print(int(json.load(sys.stdin)['secondsSinceLastInput']))" 2>/dev/null)
note "基线前台: $BASE"

echo
echo "[1] 启动虚拟光标 daemon"
"$BIN" ghost stop >/dev/null 2>&1
sleep 0.5
"$BIN" ghost start >/dev/null 2>&1
sleep 1.5
AFTER=$(front)
MISMATCH=0
if [ "$AFTER" = "$BASE" ]; then
  ok "daemon 启动后前台未变（${AFTER}）"
else
  MISMATCH=$((MISMATCH + 1))
  bad "daemon 启动抢了前台：$BASE → $AFTER"
fi

echo
echo "[2] 建会话 + 连续后台点击"
OUT=$("$BIN" session start --app "$APP" --json 2>&1)
SID=$(echo "$OUT" | python3 -c "import sys,json;print(json.load(sys.stdin).get('session',{}).get('id',''))" 2>/dev/null)
if [ -z "$SID" ]; then
  bad "会话建立失败：$OUT"
  summary; exit 1
fi
ok "会话 $SID"

STEALS=0
for label in "全部清除" "7" "加" "8" "等于"; do
  "$BIN" session click --id "$SID" --text "$label" --exact --json >/dev/null 2>&1
  F=$(front)
  if [ "$F" != "$BASE" ]; then
    STEALS=$((STEALS + 1)); note "「${label}」后前台：$BASE → $F"
  fi
done
[ "$STEALS" -eq 0 ] && ok "5 次点击全程前台未变"

echo
echo "[3] 目标应用是否被激活"
ACT=$("$BIN" session state --id "$SID" --json 2>/dev/null | python3 -c "import sys,json;print(json.load(sys.stdin).get('targetActive'))" 2>/dev/null)
[ "$ACT" = "False" ] && ok "目标未被激活" || { TARGET_ACTIVE=1; note "目标当前是激活状态：$ACT"; }

echo
echo "[4] 结果仍然正确"
V=$("$BIN" session verify --id "$SID" --expect "15" --json 2>&1)
[ "$(echo "$V" | python3 -c "import sys,json;print(json.load(sys.stdin).get('matched'))" 2>/dev/null)" = "True" ] \
  && ok "计算器显示 15" || bad "结果不对：$V"

"$BIN" session end --id "$SID" >/dev/null 2>&1
F=$(front)
[ "$F" = "$BASE" ] && ok "收尾后前台未变（${F}）" || note "收尾后前台：${BASE} → ${F}"

echo
echo "[5] 干扰判定"
ELAPSED=$(( $(date +%s) - T0 ))
IDLE1=$("$BIN" idle --json 2>/dev/null | python3 -c "import sys,json;print(int(json.load(sys.stdin)['secondsSinceLastInput']))" 2>/dev/null)
python3 -c "import sys; sys.exit(0 if float('${IDLE1:-999}') < ${ELAPSED} - 1 else 1)" 2>/dev/null && USER_TOUCHED=1 || USER_TOUCHED=0
if [ "$USER_TOUCHED" = "1" ]; then
  warn "测试期间检测到真实用户输入（idle ${IDLE1}s < 耗时 ${ELAPSED}s）→ 前台变化归属不明，本次不做判定"
  note "  请在看屏幕空闲时重跑：./tests/regression/no-focus-steal.sh"
else
  ok "全程无用户输入（idle ${IDLE1}s ≥ 耗时 ${ELAPSED}s）→ 前台断言有效"
  [ "${MISMATCH:-0}" -eq 0 ] && [ "$STEALS" -eq 0 ] && ok "前台全程未变（0 次被抢）" || bad "前台被抢 ${STEALS} 次 + 启动阶段 ${MISMATCH} 次"
  [ "${TARGET_ACTIVE:-0}" = "0" ] && ok "目标全程未被激活" || bad "目标被激活了"
fi

FINAL=$(front)

summary
