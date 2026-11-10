#!/bin/bash
# 只读示例：读出某个应用窗口里的文本（不点任何东西）
set -euo pipefail
BIN="${WBCU_BIN:-wbcu}"
APP="${1:-com.apple.calculator}"

"$BIN" session start --app "$APP" --no-ghost --json > /tmp/_s.json
SID=$(python3 -c "import json;print(json.load(open('/tmp/_s.json'))['session']['id'])")

# 只看有文本值的节点
"$BIN" session inspect --id "$SID" --max 300 --json \
  | python3 -c "
import sys, json
d = json.load(sys.stdin)
for it in d['items']:
    if it.get('value') or it.get('title'):
        print(f\"[{it['index']:>3}] {it['role']:<16} {it.get('title','')[:24]:<26} {it.get('value','')[:40]}\")
"

"$BIN" session end --id "$SID"
