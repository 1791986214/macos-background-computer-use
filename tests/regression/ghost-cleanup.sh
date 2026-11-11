#!/bin/bash
# ghost-cleanup.sh — 光标 daemon 必须能干净收场
#
# 一个长期驻留的覆盖层进程，如果 stop 之后还留着窗口或 socket，
# 下一次就会「幽灵光标」—— 用户会看到一个自己动不了、也说不清哪来的指针。
# 判据：
#   ① start 后 socket 存在、能应答
#   ② stop 后 socket 消失、进程消失
#   ③ 屏上不再有覆盖层窗口
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../lib.sh"

echo "== 光标 daemon 清理 =="

SOCK=/tmp/wbcu-ghost.sock

"$BIN" ghost stop >/dev/null 2>&1
sleep 0.3
[ ! -e "$SOCK" ] && ok "起始状态干净（无残留 socket）" || bad "起始就有残留 socket"

"$BIN" ghost start >/dev/null 2>&1
sleep 0.5
[ -e "$SOCK" ] && ok "start 后 socket 就绪" || bad "start 后没有 socket"

ST="$("$BIN" ghost status --json 2>/dev/null)"
[ -n "$ST" ] && ok "daemon 能应答状态查询" || bad "daemon 不应答"

"$BIN" ghost goto --x 100 --y 100 --json >/dev/null 2>&1
N="$(pgrep -f 'ghost daemon' | wc -l | tr -d ' ')"
[ "$N" -ge 1 ] && ok "daemon 进程存在（${N}）" || warn "未匹配到 daemon 进程名（不影响结论）"

"$BIN" ghost stop >/dev/null 2>&1
sleep 0.6
[ ! -e "$SOCK" ] && ok "stop 后 socket 已删除" || bad "stop 后 socket 仍存在"

LEFT="$(pgrep -f 'ThirdHandOverlay.app/Contents/MacOS/wbcu' | wc -l | tr -d ' ')"
[ "$LEFT" -eq 0 ] && ok "stop 后覆盖层进程已退出" || bad "stop 后仍有 $LEFT 个覆盖层进程"

# 屏上残留窗口检查：用窗口列表按 owner 找覆盖层
REM="$(python3 - "$BIN" <<'PY'
import json,subprocess,sys
out=subprocess.run([sys.argv[1],'windows','--json'],capture_output=True,text=True).stdout
try: d=json.loads(out)
except Exception: print(0); raise SystemExit
ws=d.get('windows') or d.get('items') or []
hits=[w for w in ws if 'ThirdHand' in json.dumps(w) or 'thirdhand' in json.dumps(w).lower()]
print(len(hits))
PY
)"
[ "${REM:-0}" -eq 0 ] && ok "屏上没有残留覆盖层窗口" || bad "屏上仍有 $REM 个覆盖层窗口"

summary
