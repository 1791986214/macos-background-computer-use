#!/bin/bash
# version-consistency.sh — 引擎与技能版本一致性回归
#
# 背景（v0.5.0 真实事故）：
#   install.sh 默认只装二进制，技能要显式 --skill。
#   结果 `wbcu version` = 0.5.0，而 SKILL.md 还是 0.4.2（177 行、没有 launch/trace），
#   Agent 照着技能敲 `wbcu launch` 直接报 unknown command。
#
# 这个测试要证明三件事：
#   ① 正常安装后 doctor 判定一致（exit 0）
#   ② 人为制造版本漂移时 doctor 能抓到（exit≠0，且明确点名 version_match）
#   ③ 技能里引用的每个 `wbcu <cmd>` 都真的存在

set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
BIN="${WBCU_BIN:-$ROOT/bin/wbcu}"
SKILL="$HOME/.workbuddy/skills/workbuddy-third-hand/SKILL.md"
PASS=0; FAIL=0; WARN=0
ok()   { echo "  ✅ $*"; PASS=$((PASS+1)); }
bad()  { echo "  ❌ $*"; FAIL=$((FAIL+1)); }
warn() { echo "  ⚠️  $*"; WARN=$((WARN+1)); }

[ -x "$BIN" ] || { echo "找不到 wbcu：$BIN"; exit 1; }
[ -f "$SKILL" ] || { echo "技能未安装：${SKILL}（先 bash scripts/install.sh）"; exit 1; }

echo "=== 引擎 / 技能版本一致性 ==="

ENGINE="$("$BIN" version 2>/dev/null | tr -d '[:space:]')"
SKILL_V="$(python3 - "$SKILL" <<'PY'
import sys,re
s=open(sys.argv[1],encoding='utf-8').read()
m=re.search(r'^---\n(.*?)\n---', s, re.S)
if m:
    for line in m.group(1).split("\n"):
        if line.strip().lower().startswith("version:"):
            print(line.split(":",1)[1].strip()); raise SystemExit
print("")
PY
)"
echo "  engine=${ENGINE}  skill=${SKILL_V}"

[ -n "$SKILL_V" ] && ok "技能声明了版本号（${SKILL_V}）" || bad "技能没有 version 字段，doctor 无法比对"
[ "$ENGINE" = "$SKILL_V" ] && ok "版本一致（${ENGINE}）" || bad "版本不一致：engine=${ENGINE} skill=${SKILL_V}"

# ① 正常状态下 doctor 应判定一致
OUT="$("$BIN" doctor --json 2>/dev/null)"
VERDICT="$(printf '%s' "$OUT" | python3 -c "import sys,json;print(json.load(sys.stdin)['verdict'])" 2>/dev/null)"
case "$VERDICT" in
  healthy) ok "doctor 判定 healthy" ;;
  degraded) warn "doctor 判定 degraded（有警告项，见 wbcu doctor）" ;;
  *) bad "doctor 判定 ${VERDICT:-失败}" ;;
esac

# ③ 技能引用的命令必须都存在
UNKNOWN="$(printf '%s' "$OUT" | python3 -c "
import sys,json
d=json.load(sys.stdin)
for c in d['checks']:
    if c['name']=='skill_commands' and c['level']!='pass':
        print(c['detail'])
" 2>/dev/null)"
[ -z "$UNKNOWN" ] && ok "技能引用的 wbcu 命令全部存在" || bad "技能引用了不存在的命令：${UNKNOWN}"

# ② 人为制造漂移：改版本号 → doctor 必须抓到 → 还原
BAK="$(mktemp /tmp/skill-bak.XXXXXX)"
cp "$SKILL" "$BAK"
trap 'cp "$BAK" "$SKILL"; rm -f "$BAK"' EXIT

python3 - "$SKILL" <<'PY'
import sys,re
p=sys.argv[1]
s=open(p,encoding='utf-8').read()
s=re.sub(r'^(version:\s*).*$', r'\g<1>0.0.0-drift', s, count=1, flags=re.M)
open(p,'w',encoding='utf-8').write(s)
PY

DRIFT_OUT="$("$BIN" doctor --json 2>/dev/null)"
DRIFT_CODE=$?
DRIFT_VERDICT="$(printf '%s' "$DRIFT_OUT" | python3 -c "import sys,json;print(json.load(sys.stdin)['verdict'])" 2>/dev/null)"
DRIFT_HIT="$(printf '%s' "$DRIFT_OUT" | python3 -c "
import sys,json
d=json.load(sys.stdin)
print(any(c['name']=='version_match' and c['level']=='fail' for c in d['checks']))
" 2>/dev/null)"

[ "$DRIFT_CODE" -ne 0 ] && ok "漂移时 doctor 退出码非 0（${DRIFT_CODE}）" \
  || bad "漂移时 doctor 仍然 exit 0 —— 自检无效"
[ "$DRIFT_HIT" = "True" ] && ok "漂移被 version_match 明确点名" \
  || bad "漂移没有被 version_match 捕获（verdict=${DRIFT_VERDICT}）"

# 还原
cp "$BAK" "$SKILL"
AFTER="$("$BIN" doctor --json 2>/dev/null | python3 -c "import sys,json;print(json.load(sys.stdin)['verdict'])" 2>/dev/null)"
case "$AFTER" in
  healthy|degraded) ok "还原后 doctor 恢复正常（${AFTER}）" ;;
  *) bad "还原后 doctor 仍异常（${AFTER}）" ;;
esac

# ④ 安装路径与技能目录同源（防止「装了 A 却读 B」）
ENGINE_BIN="$(command -v wbcu 2>/dev/null || echo "$HOME/.local/bin/wbcu")"
REL_ENGINE="$("$ENGINE_BIN" version 2>/dev/null | tr -d '[:space:]')"
[ "$REL_ENGINE" = "$ENGINE" ] && ok "PATH 上的 wbcu 与本次测试的二进制同版本（${REL_ENGINE}）" \
  || warn "PATH 上的 wbcu=${REL_ENGINE}，本次测试用=${ENGINE}（安装后才一致）"

echo
echo "  结果：通过 ${PASS} / 失败 ${FAIL} / 警告 ${WARN}"
[ "$FAIL" -eq 0 ] || exit 1
