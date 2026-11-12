#!/bin/bash
# no-reactivation.sh — 「任务全程不抢前台」回归
#
# 背景（用户实际观察）：
#   WorkBuddy 执行浏览器或桌面任务时，可能每执行一步就把目标窗口重新带到前台。
#
# 这个测试不只断言「结束时前台没变」，而是用被动激活追踪器看**全过程**：
#   ① 前台切换里有几次归因于 wbcu 命令（必须为 0）
#   ② 有几次是「既非用户、也非 wbcu」的外部 activate（必须为 0，脚手架自己切换要登记 harness）
#   ③ 会话是否被复用（重复初始化会让 Agent 反复 `open -a`，那才是真正抢前台的来源）
#
# 判据全部来自真实运行，不看返回码。

set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
BIN="${WBCU_BIN:-$ROOT/bin/wbcu}"
LAB="${LAB:-/tmp/wbcu-lab}"
TARGET_BID="com.apple.calculator"
TARGET_NAME="Calculator"

PASS=0; FAIL=0; WARN=0
ok()   { echo "  ✅ $*"; PASS=$((PASS+1)); }
bad()  { echo "  ❌ $*"; FAIL=$((FAIL+1)); }
warn() { echo "  ⚠️  $*"; WARN=$((WARN+1)); }
note() { echo "  ·  $*"; }

[ -x "$BIN" ] || { echo "找不到 wbcu：$BIN"; exit 1; }

# 注意别写成 eval('d$1')：$1 里的单引号会把 Python 字符串截断，结果永远是空
jget() { python3 -c "import sys,json;d=json.load(sys.stdin);print(d$1)" 2>/dev/null; }

front_name() { lsappinfo front 2>/dev/null | xargs -I{} lsappinfo info -only name {} 2>/dev/null | sed 's/.*=//;s/"//g'; }

echo "=== 不抢前台回归（$TARGET_NAME 125×8，全程后台）==="

# 清场
osascript -e "tell application \"$TARGET_NAME\" to quit" >/dev/null 2>&1
sleep 1

# 起点固定在「用户自己的应用」上，这样中途那次切换才是真实的一次前台变化
osascript -e 'tell application "WorkBuddy" to activate' >/dev/null 2>&1
sleep 0.6

"$BIN" trace reset >/dev/null 2>&1
"$BIN" trace start --restart >/dev/null 2>&1
sleep 0.3
[ "$("$BIN" trace status 2>/dev/null | grep -c "追踪中")" = "1" ] && ok "追踪器已启动" || warn "追踪器未启动，本次只能做功能断言"

FRONT0="$(front_name)"
note "起点前台：${FRONT0}"

# —— ① 后台启动（不是 open -a）
LAUNCH="$("$BIN" launch --app "$TARGET_BID" --json 2>/dev/null)"
L_OK="$(printf '%s' "$LAUNCH" | jget "['launched']")"
L_ACT="$(printf '%s' "$LAUNCH" | jget "['activated']")"
sleep 1.3
[ "$L_OK" = "True" ] && [ "$L_ACT" = "False" ] && ok "后台启动成功且未激活（activated=false）" \
  || bad "启动异常：launched=${L_OK} activated=${L_ACT}"
[ "$(front_name)" = "$FRONT0" ] && ok "启动后前台未变（${FRONT0}）" \
  || bad "启动后前台被改变：${FRONT0} → $(front_name)"

# —— ①b 已在运行时再 launch：必须什么都不做（重复 open -a 正是抢前台的来源）
L2="$("$BIN" launch --app "$TARGET_BID" --json 2>/dev/null)"
L2_AGAIN="$(printf '%s' "$L2" | jget "['alreadyRunning']")"
L2_ACT="$(printf '%s' "$L2" | jget "['activated']")"
[ "$L2_AGAIN" = "True" ] && [ "$L2_ACT" = "False" ]   && ok "已在运行时 launch 不重复启动、不激活（alreadyRunning=true）" \
  || bad "重复 launch 行为异常：alreadyRunning=${L2_AGAIN} activated=${L2_ACT}"
[ "$(front_name)" = "$FRONT0" ] && ok "重复 launch 后前台仍未变" || bad "重复 launch 改变了前台"

# —— ② 会话建立 + 复用
S1="$("$BIN" session start --app "$TARGET_BID" --json 2>/dev/null)"
SID="$(printf '%s' "$S1" | jget "['session']['id']")"
S2="$("$BIN" session start --app "$TARGET_BID" --json 2>/dev/null)"
SID2="$(printf '%s' "$S2" | jget "['session']['id']")"
REUSED="$(printf '%s' "$S2" | jget "['reused']")"
[ -n "$SID" ] && [ "$SID" = "$SID2" ] && [ "$REUSED" = "True" ] \
  && ok "同一 App 复用同一会话（${SID}），没有重复初始化" \
  || bad "会话未复用：${SID} → ${SID2} reused=${REUSED}"

# —— ③ 125 × 8
click() {
  local ident="$1" want="${2:-}"
  local args=(--app "$TARGET_BID" --identifier "$ident" --json)
  [ -n "$want" ] && args+=(--expect "$want" --expect-el "role:AXStaticText")
  local out; out="$("$BIN" session click "${args[@]}" 2>/dev/null)"
  printf '%s' "$out" | python3 -c "
import sys,json
d=json.load(sys.stdin)
v=d.get('verificationReport') or {}
t=d.get('timing') or {}
print('%-9s %-16s %6.1fms  actual=%r' % ('$ident', d.get('result'), t.get('totalMs',-1),
      (v.get('actualState') or {}).get('value')))"
}

# 计算器的清除键连 identifier 都会随状态切换：
#   干净状态 → AllClear（全部清除）
#   已有输入 → Clear（清除）
# 所以这里两个都试。这条实测推翻了「identifier 一定稳定」的假设。
R=""
CLEAR_OUT="$(click AllClear 0)"
printf '%s' "$CLEAR_OUT" | grep -q "None\|error" && CLEAR_OUT="$(click Clear 0)"
R+="$CLEAR_OUT"$'\n'
R+="$(click One 1)"$'\n'
R+="$(click Two 12)"$'\n'

# —— ④ 模拟用户切走前台（登记为 harness，不算任何一方）
SW_TS_BEFORE="$(date +%s)"
# 切到哪个应用由环境决定：Safari 在跑就用 Safari（贴近用户场景），否则用 Finder
if pgrep -x Safari >/dev/null 2>&1; then SWITCH_APP="Safari"; else SWITCH_APP="Finder"; fi
"$BIN" trace mark --note "harness: 模拟用户切到 ${SWITCH_APP}" >/dev/null 2>&1
# 重试几次：osascript 偶发被 Automation 授权拦一下，单次失败不代表切不过去
for _ in 1 2 3; do
  osascript -e "tell application \"${SWITCH_APP}\" to activate" >/dev/null 2>&1
  sleep 0.6
  [ "$(front_name)" != "$FRONT0" ] && break
done
FRONT_MID="$(front_name)"
note "切走后前台：${FRONT_MID}（目标：${SWITCH_APP}）"
[ "$FRONT_MID" != "$FRONT0" ] && ok "harness 切换确实改变了前台（${FRONT0} → ${FRONT_MID}）" \
  || warn "harness 切换没生效，本次无法证明「中途切走」这一项"

R+="$(click Five 125)"$'\n'
R+="$(click Multiply)"$'\n'
R+="$(click Eight '125×8')"$'\n'
R+="$(click Equals 1000)"$'\n'

printf '%s' "$R" | sed 's/^/    /'

SUCC=$(printf '%s' "$R" | grep -c "success")
[ "$SUCC" -ge 7 ] && ok "7/7 步验证通过（含结果行与表达式行分离的那一步）" \
  || bad "只有 ${SUCC}/7 步 success"

FINAL_OK=$(printf '%s' "$R" | grep "Equals" | grep -c "1,000")
[ "$FINAL_OK" = "1" ] && ok "最终读数为 1,000" || bad "最终读数不是 1,000"

# —— ⑤ 前台保持
FRONT_END="$(front_name)"
if [ "$FRONT_END" = "$FRONT_MID" ]; then
  ok "计算全程前台停在用户的应用（${FRONT_END}）"
else
  bad "前台被改变：${FRONT_MID} → ${FRONT_END}"
fi

# —— ⑥ 归因：不许有 wbcu / 未登记的外部 activate
TR="$("$BIN" trace report --json 2>/dev/null)"
printf '%s' "$TR" > "$LAB/trace-no-reactivation.json"
WBCU_N="$(printf '%s' "$TR" | python3 -c "import sys,json;print(json.load(sys.stdin)['attribution'].get('wbcu',0))" 2>/dev/null)"
EXT_N="$(printf '%s' "$TR" | python3 -c "import sys,json;print(json.load(sys.stdin)['attribution'].get('external',0))" 2>/dev/null)"
[ "${WBCU_N:-1}" = "0" ] && ok "0 次前台变化归因于 wbcu 命令" \
  || bad "${WBCU_N} 次前台变化归因于 wbcu —— 引擎里有 activate 路径"
[ "${EXT_N:-1}" = "0" ] && ok "0 次未登记的外部 activate（既非用户也非 wbcu）" \
  || warn "${EXT_N} 次外部 activate，需人工确认不是 Agent 自己调的（见 trace 报告）"

# —— ⑦ 退出码与清理
"$BIN" session end --id "$SID" >/dev/null 2>&1
sleep 0.3
"$BIN" ghost stop >/dev/null 2>&1
"$BIN" trace stop >/dev/null 2>&1
LEFT="$(pgrep -f "ThirdHandOverlay.app/Contents/MacOS/wbcu" | head -1)"
if [ -n "$LEFT" ]; then
  # stop 是异步的：给它 1s；仍活着才算残留
  sleep 1
  LEFT="$(pgrep -f "ThirdHandOverlay.app/Contents/MacOS/wbcu" | head -1)"
fi
[ -z "$LEFT" ] && ok "ghost 进程已清理" || bad "ghost 进程残留 pid=${LEFT}"

echo
echo "  结果：通过 ${PASS} / 失败 ${FAIL} / 警告 ${WARN}"
[ "$FAIL" -eq 0 ] || exit 1
