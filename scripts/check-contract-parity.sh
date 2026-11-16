#!/usr/bin/env bash
# 校验 macOS 与 Windows 两个引擎的契约输出是否逐字一致。
#
# 这是「同一份技能、两个引擎」这件事唯一能自动证明的部分：
# 动作名、错误码、验证分类、匹配模式、能力键、结果字段、纪律条款，
# 只要有一边改了一个字，这里就会红。
#
# 用法：./scripts/check-contract-parity.sh
# 依赖：dotnet（跑 C# 契约库）、jq（可选，纯 python 也可）
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOTNET="${DOTNET:-dotnet}"
command -v "$DOTNET" >/dev/null 2>&1 || {
  [ -x "$HOME/.local/share/dotnet/dotnet" ] && DOTNET="$HOME/.local/share/dotnet/dotnet" || {
    echo "找不到 dotnet SDK" >&2; exit 1; }
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "== 生成 macOS 侧契约 =="
"$ROOT/bin/wbcu" contract --json > "$TMP/mac.json" 2>/dev/null || {
  echo "bin/wbcu 不可用，先跑 ./scripts/build.sh" >&2; exit 1; }

echo "== 生成 Windows 侧契约（C# 契约库） =="
"$DOTNET" run --project "$ROOT/src-windows/tools/RenderPreview" -v q -- --contract "$TMP/win.json"

echo "== 逐字对比 =="
python3 - "$TMP/mac.json" "$TMP/win.json" <<'PY'
import json, sys

mac = json.load(open(sys.argv[1]))
win = json.load(open(sys.argv[2]))
shared = ["schemaVersion", "actions", "errorCodes", "verifyCategories", "verifyMethods",
          "verifyProviders", "matchModes", "capabilityKeys", "capabilityStatus",
          "selectorKinds", "resultFields", "invariants"]
allow_diff = {"platform", "engine", "engineVersion"}

bad = 0
for k in shared:
    if k not in mac or k not in win:
        print(f"MISSING {k}: mac={k in mac} win={k in win}"); bad += 1; continue
    if mac[k] != win[k]:
        print(f"DIFF {k}\n  mac = {mac[k]}\n  win = {win[k]}"); bad += 1

extra_mac = set(mac) - set(win) - allow_diff
extra_win = set(win) - set(mac) - allow_diff
if extra_mac: print("mac 独有字段:", sorted(extra_mac)); bad += 1
if extra_win: print("win 独有字段:", sorted(extra_win)); bad += 1

print(f"platform: {mac['platform']} / {win['platform']}")
print(f"engine:   {mac['engine']} / {win['engine']}")
print("PARITY OK" if bad == 0 else f"{bad} 处不一致")
sys.exit(0 if bad == 0 else 1)
PY
