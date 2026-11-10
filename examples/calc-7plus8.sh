#!/bin/bash
# 最小示例：后台让计算器算出 7+8，全程不动真实鼠标
set -euo pipefail
BIN="${WBCU_BIN:-wbcu}"

open -g -a Calculator              # -g = 后台启动，不抢焦点
sleep 1.5
"$BIN" guard --app com.apple.calculator --allow >/dev/null 2>&1

START=$("$BIN" session start --app com.apple.calculator --json)
SID=$(echo "$START" | python3 -c "import sys,json;print(json.load(sys.stdin)['session']['id'])")
echo "会话 $SID"

for label in "全部清除" "7" "加" "8" "等于"; do
  "$BIN" session click --id "$SID" --text "$label" --exact --json \
    | python3 -c "import sys,json;d=json.load(sys.stdin);print(f\"  {d['target'].get('matchedText','?'):>6}  mode={d['mode']}  {d['verification']}\")"
done

"$BIN" session verify --id "$SID" --expect "15"
"$BIN" session end --id "$SID"
