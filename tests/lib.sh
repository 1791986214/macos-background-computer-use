#!/bin/bash
# 共享测试辅助：统一解析 wbcu 路径与前置检查
#
# 优先级：$WBCU_BIN → 仓库内 bin/wbcu → ~/.local/bin/wbcu
# 让测试既能测「刚编出来的二进制」，也能测「已安装版本」。

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="${WBCU_BIN:-$REPO_ROOT/bin/wbcu}"
[ -x "$BIN" ] || BIN="$HOME/.local/bin/wbcu"

GREEN=$'\033[32m'; RED=$'\033[31m'; YELLOW=$'\033[33m'; DIM=$'\033[2m'; NC=$'\033[0m'

FAILED=0
SKIPPED=0
ok()   { echo "  ${GREEN}✅${NC} $*"; }
bad()  { echo "  ${RED}❌${NC} $*"; FAILED=$((FAILED + 1)); }
warn() { echo "  ${YELLOW}⚠️${NC} $*"; SKIPPED=$((SKIPPED + 1)); }
note() { echo "  ${DIM}$*${NC}"; }

perm_json() { "$BIN" perm --json 2>/dev/null; }
has_ax()    { [ "$(perm_json | python3 -c "import sys,json;print(json.load(sys.stdin).get('accessibility'))" 2>/dev/null)" = "True" ]; }
has_scr()   { [ "$(perm_json | python3 -c "import sys,json;print(json.load(sys.stdin).get('screenRecording'))" 2>/dev/null)" = "True" ]; }

# 需要真实桌面会话 + TCC 授权；缺失时跳过并计入 SKIPPED（不是通过）
require_desktop() {
  if ! has_ax; then
    warn "辅助功能未授权 → 跳过需要 AX 的用例（SKIPPED，不算通过）"
    return 1
  fi
  return 0
}

require_screen_recording() {
  if ! has_scr; then
    warn "屏幕录制未授权 → 跳过捕获用例（SKIPPED，不算通过）"
    return 1
  fi
  return 0
}

# 从 stdin 的 JSON 里取值：jget "['session']['id']"
# 表达式走 argv 传参，避免 shell 引号把 ['x'] 拆成字符串拼接
jget() {
  python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
    v = eval("d" + sys.argv[1], {"__builtins__": {}}, {"d": d})
    print(v)
except Exception:
    print("")
' "$1" 2>/dev/null
}

summary() {
  echo
  if [ "$FAILED" -eq 0 ] && [ "$SKIPPED" -eq 0 ]; then
    echo "${GREEN}全部通过${NC}"
  elif [ "$FAILED" -eq 0 ]; then
    echo "${YELLOW}通过，但有 $SKIPPED 项跳过（未验证）${NC}"
  else
    echo "${RED}失败 $FAILED 项${NC}，跳过 $SKIPPED 项"
  fi
  [ "$FAILED" -eq 0 ]
}
