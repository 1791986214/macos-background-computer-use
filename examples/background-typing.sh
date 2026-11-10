#!/bin/bash
# 后台写入文本：不激活 TextEdit，把内容写进它的文本框
#
# 注意：这里走 AXValue 而不是键盘。非激活窗口没有 field editor，
# 按键事件无处落地 —— 这不是投递失败，是 AppKit 的结构性限制。
set -euo pipefail
BIN="${WBCU_BIN:-wbcu}"
TEXT="${1:-后台写入的文本}"

open -g -a TextEdit
sleep 2
"$BIN" guard --app com.apple.TextEdit --allow >/dev/null 2>&1

SID=$("$BIN" session start --app com.apple.TextEdit --json \
      | python3 -c "import sys,json;print(json.load(sys.stdin)['session']['id'])")

"$BIN" key --app com.apple.TextEdit --combo "cmd+n" >/dev/null 2>&1   # 新文档（应用级命令，后台可用）
sleep 1

"$BIN" session type --id "$SID" --text "$TEXT"
"$BIN" session verify --id "$SID" --expect "$TEXT"
"$BIN" session end --id "$SID"
