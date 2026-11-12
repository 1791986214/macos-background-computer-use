#!/bin/bash
# user-concurrent.sh — 真实用户并发交互测试
#
# 这不是「前台没变」那种弱断言。它做三件事：
#   ① 用 listen-only 事件 tap 记录**用户真实输入**的时间线（鼠标/键盘/滚动）
#   ② 同一时段让 Third Hand 在后台连续操作受控目标，每次带显式期望状态
#   ③ 事后做**责任归因**：每次前台变化，若有用户输入在 ±0.4s 内 → 归因用户，否则归因 Agent
#
# 前置条件：用户正在真实使用电脑（有人在动鼠标/打字）。若整段没有任何用户输入，
# 结论无意义 → 记为 SKIPPED/Not Tested，而不是「通过」。
#
# 用法：
#   bash tests/concurrency/user-concurrent.sh [动作次数] [总时长秒]
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
source "$ROOT/tests/lib.sh"
source "$ROOT/tests/lib-lab.sh"

ACTIONS="${1:-8}"
DURATION="${2:-26}"
# targeted = 强制坐标投递（不许走 AX 语义路径）；auto = 默认（AX 优先）
MODE="${WBCU_CONC_MODE:-auto}"
# 1 = 测试中途由脚本切一次前台（模拟用户切窗口，登记为 harness 行为，不算 Agent 的锅）
SWITCH="${WBCU_CONC_SWITCH:-0}"
LAB="$LAB_DIR"
ACT_JSONL="$LAB/agent-actions.jsonl"
ACTIVITY="$LAB/activity.jsonl"
META="$LAB/concurrency-meta.json"
REPORT="$LAB/concurrency-report.json"

echo "== 真实用户并发交互 =="
lab_need_build || exit 1
lab_start_target || exit 1
trap 'lab_stop; "$BIN" ghost stop >/dev/null 2>&1' EXIT

# 探针
PROBE="$HERE/build/activity-probe"
if [ ! -x "$PROBE" ]; then
  SDK="/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk"
  [ -d "$SDK" ] || SDK="$(xcrun --show-sdk-path)"
  mkdir -p "$HERE/build"
  swiftc -sdk "$SDK" -swift-version 5 -O -target arm64-apple-macos14.0 \
    -o "$PROBE" "$HERE/ActivityProbe.swift" \
    -framework Cocoa -framework CoreGraphics 2>&1 | head -5
fi
[ -x "$PROBE" ] || { bad "探针编译失败"; summary; exit 1; }

read -r WID CX CY TPID < <(lab_geom btnCount)
C0="$(lab_clicks)"
: > "$ACT_JSONL"
note "目标窗口 $WID  按钮中心 ($CX,$CY)  初始 count=$C0"

# 等用户真的在动（最多 40s）。没有真实用户活动，这条测试没有意义。
BUSY=0
for _ in $(seq 1 40); do
  if lab_user_busy; then BUSY=$((BUSY + 1)); else BUSY=0; fi
  [ "$BUSY" -ge 2 ] && break
  sleep 1
done
if [ "$BUSY" -lt 2 ]; then
  warn "40 秒内没有检测到真实用户输入 → 并发结论无意义，标记 Not Tested（不算通过）"
  python3 - "$REPORT" <<'PY'
import json,sys
json.dump({"ok": False, "notTested": True,
           "reason": "no real user input within 40s; concurrency claim cannot be made"},
          open(sys.argv[1],"w"), ensure_ascii=False, indent=2)
PY
  summary; exit 0
fi

echo "  检测到用户正在使用电脑，开始记录时间线（${DURATION}s）"
"$PROBE" "$ACTIVITY" "$DURATION" &
PROBE_PID=$!
sleep 1.2

SUCC=0
FAILED=0
for i in $(seq 1 "$ACTIONS"); do
  WANT="count = $((C0 + i))"
  T0="$(python3 -c 'import time;print(time.time())')"
  # 用 act（无会话）保持流程简单：坐标与期望都显式给
  MODE_ARG=()
  [ "$MODE" != "auto" ] && MODE_ARG=(--mode "$MODE")
  OUT="$("$BIN" act --window "$WID" --x "$CX" --y "$CY" ${MODE_ARG[@]+"${MODE_ARG[@]}"} \
         --focus-check --expect "$WANT" --expect-el id:countLabel --expect-timeout 900 --json 2>/dev/null)"
  T1="$(python3 -c 'import time;print(time.time())')"
  if [ -z "$OUT" ]; then
    FAILED=$((FAILED + 1)); echo "  ⚠️ 第 $i 次无返回"
  else
    printf '%s' "$OUT" | python3 -c "
import sys,json
d=json.load(sys.stdin)
d['t0']=$T0; d['t1']=$T1
print(json.dumps(d,ensure_ascii=False))" >> "$ACT_JSONL"
    R="$(printf '%s' "$OUT" | jget "['result']")"
    [ "$R" = "success" ] && SUCC=$((SUCC + 1)) || FAILED=$((FAILED + 1))
  fi
  # 中途模拟一次「用户切走前台」：由脚本发起并登记，避免把 harness 行为判成 Agent 抢前台
  if [ "$SWITCH" = "1" ] && [ "$i" -eq $((ACTIONS / 2)) ]; then
    SW_TS="$(python3 -c 'import time;print(time.time())')"
    osascript -e 'tell application "Finder" to activate' >/dev/null 2>&1
    echo "$SW_TS" >> "$LAB/harness-switches.txt"
  fi
  sleep 1.1
done

wait "$PROBE_PID" 2>/dev/null || true
C1="$(lab_clicks)"

MODE_FOR_META="$MODE" SW_FILE="$LAB/harness-switches.txt" \
python3 -c 'import json,os,sys; p=sys.argv[1]; sw=[float(x) for x in open(os.environ["SW_FILE"]).read().split()] if os.path.exists(os.environ["SW_FILE"]) else []; json.dump({"fixture":{"count_before":int(sys.argv[2]),"count_after":int(sys.argv[3]),"expected_actions":int(sys.argv[4]),"window_id":int(sys.argv[5])},"mode":os.environ["MODE_FOR_META"],"harness_activations":sw,"actions_raw":sys.argv[6]}, open(p,"w"), ensure_ascii=False, indent=2)' \
  "$META" "$C0" "$C1" "$ACTIONS" "$WID" "$ACT_JSONL"
rm -f "$LAB/harness-switches.txt"

echo "  动作完成：success=$SUCC failed=$FAILED  count $C0 → $C1"
echo
python3 "$HERE/analyze.py" "$ACTIVITY" "$META" "$REPORT"
RC=$?

# 额外断言：每次动作的 result 必须是 success（报告里已检查，这里补充退出码语义）
if [ "$RC" -ne 0 ]; then
  bad "并发交互测试未通过，详见 $REPORT"
else
  ok "并发交互测试通过"
fi
summary
exit "$RC"
