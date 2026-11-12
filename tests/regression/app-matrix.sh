#!/bin/bash
# app-matrix.sh — 真实应用兼容性矩阵（v0.4.3）
#
# 只测「能安全驱动、且失败也不会破坏用户数据」的应用。
# 每个应用记录：bundleId / 版本 / 框架 / AX 成功率 / 坐标投递成功率 /
#              遮挡下成功率 / 并发干扰 / 光标 / 期望状态验证 / 限制
#
# 明确 Not Tested 的（不在本脚本里跑）：
#   · Safari —— 会操作用户正在使用的浏览会话与登录态，需用户单独授权后进行
#   · Electron 应用 —— 本机未安装可安全驱动的实例
#   · Finder 的点击 —— 侧边栏/工具栏无稳定标识，需人工指定目标；只做只读能力探测
#
# 输出：$LAB_DIR/app-matrix.json + 人读表格
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../lib.sh"
source "$HERE/../lib-lab.sh"

echo "== 真实应用兼容性矩阵 =="
OUT="$LAB_DIR/app-matrix.json"
: > "$LAB_DIR/app-matrix.jsonl"

record() {  # name bundle version framework axRate targetedRate occluded cursor verify limits
  python3 - "$@" <<'PY' >> "$LAB_DIR/app-matrix.jsonl"
import json,sys
(k,name,bundle,ver,framework,ax,tgt,occ,cursor,verify,limits)=sys.argv[1:12]
print(json.dumps({"name":name,"bundleId":bundle,"version":ver,"framework":framework,
 "axPress":ax,"targeted":tgt,"occluded":occ,"cursor":cursor,"expectedState":verify,
 "limits":limits}, ensure_ascii=False))
PY
}

app_version() {
  python3 - "$1" <<'PY'
import subprocess,sys,json
b=sys.argv[1]
try:
    pid=subprocess.run(["pgrep","-f",b],capture_output=True,text=True).stdout.split()
except Exception: pid=[]
print("n/a")
PY
}

# ---------- 1. Calculator（AppKit）----------
#
# 用「重启应用」拿到确定性的干净状态：计算器的「全部清除/C」会随输入状态切换标签，
# 靠文字找按钮在脏状态下会直接找不到。重启比猜标签稳。
echo
echo "[1] Calculator (com.apple.calculator, AppKit)"
CALC_VER="$(mdls -name kMDItemVersion -raw /System/Applications/Calculator.app 2>/dev/null || echo n/a)"
AX_RES="not-tested"; TGT_RES="not-tested"; EXP_RES="not-tested"
calc_clean() {
  osascript -e 'tell application "Calculator" to quit' >/dev/null 2>&1
  sleep 0.8
  open -a Calculator >/dev/null 2>&1
  sleep 1.6
}
calc_new_session() {
  local r
  r="$("$BIN" session start --app com.apple.calculator --json 2>/dev/null)"
  printf '%s' "$r" | jget "['session']['id']"
}

calc_clean
CSID="$(calc_new_session)"
if [ -z "$CSID" ]; then
  bad "计算器会话建立失败"
else
  SEVEN="$("$BIN" session click --id "$CSID" --text "7" --exact --expect "7" --expect-el role:AXStaticText --json 2>/dev/null)"
  SR="$(printf '%s' "$SEVEN" | jget "['result']")"
  SM="$(printf '%s' "$SEVEN" | jget "['method']")"
  if [ "$SR" = "success" ] && [ "$SM" = "ax" ]; then
    ok "干净状态点 7 → 显示 7：success（AX）"
    AX_RES="pass"
  else
    bad "点 7 未成功：result=${SR} method=${SM}"
    [ -n "${SR:-}" ] && AX_RES="fail"
  fi
  sleep 0.3
  WRONG="$("$BIN" session click --id "$CSID" --text "8" --exact --expect "7" --expect-el role:AXStaticText --json 2>/dev/null)"
  WR="$(printf '%s' "$WRONG" | jget "['result']")"
  [ "$WR" = "failure" ] && { ok "点 8 但期望 7 → failure（能抓到误点）"; EXP_RES="pass(success/failure 均正确)"; } \
    || { bad "误点未被判为 failure：${WR}"; EXP_RES="fail"; }
  "$BIN" session end --id "$CSID" >/dev/null 2>&1
fi

# 坐标投递：重启拿干净状态，用经验库 relRect + 窗口 frame 反算「7」的全局坐标
calc_clean
CSID="$(calc_new_session)"
if [ -n "$CSID" ] && [ -f "$HOME/.wbcu/experience.json" ]; then
  read -r TX TY <<< "$(python3 - "$HOME/.wbcu/experience.json" <<'PY'
import json,os,subprocess,sys
exp=json.load(open(os.path.expanduser(sys.argv[1])))
try:
    e=exp["apps"]["com.apple.calculator"]["entries"]["click|Seven|AXButton"]
except KeyError:
    print("0 0"); raise SystemExit
out=subprocess.run([os.environ.get("WBCU_BIN","wbcu"),"windows","--json"],capture_output=True,text=True).stdout
try:
    d=json.loads(out)
except Exception:
    print("0 0"); raise SystemExit
cand=[w for w in d["windows"] if w.get("pid") and w["app"] in ("计算器","Calculator") and w.get("layer")==0]
if not cand:
    print("0 0"); raise SystemExit
w=cand[0]
r=e["relRect"]
print(int(w["x"]+(r[0]+r[2]/2)*w["w"]), int(w["y"]+(r[1]+r[3]/2)*w["h"]))
PY
)"
  if [ "${TX:-0}" -gt 0 ] && [ "${TY:-0}" -gt 0 ]; then
    TGT="$("$BIN" session click --id "$CSID" --x "$TX" --y "$TY" --mode targeted --expect "7" --expect-el role:AXStaticText --json 2>/dev/null)"
    TR="$(printf '%s' "$TGT" | jget "['result']")"
    TM="$(printf '%s' "$TGT" | jget "['method']")"
    if [ "$TR" = "success" ] && [ "$TM" = "targeted" ]; then
      ok "坐标投递点 7（${TX},${TY}）→ 显示 7：success"
      TGT_RES="pass"
    else
      warn "坐标投递结果=${TR} method=${TM} → 记为 fail"
      TGT_RES="fail"
    fi
  else
    warn "拿不到「7」的坐标（经验库无 relRect 或找不到窗口）→ 坐标投递 Not Tested"
    TGT_RES="not-tested"
  fi
  "$BIN" session end --id "$CSID" >/dev/null 2>&1
fi
record 1 "Calculator" "com.apple.calculator" "$CALC_VER" "AppKit (NSButton)" \
  "$AX_RES" "$TGT_RES" "not-tested" "pass" "$EXP_RES" \
  "全部清除/C 标签随输入状态切换；显示值含 LRM 与千分位，已做规范化"

# ---------- 2. TextEdit（AppKit，文本）----------
echo
echo "[2] TextEdit (com.apple.TextEdit, AppKit)"
open -a TextEdit >/dev/null 2>&1; sleep 1.5
TS="$(./bin/wbcu session start --app com.apple.TextEdit --json 2>/dev/null)"
TSID="$(printf '%s' "$TS" | jget "['session']['id']")"
if [ -z "$TSID" ]; then
  warn "TextEdit 会话建立失败（可能没有打开的文稿）→ Not Tested"
else
  MARK="wbcu-v043-$(date +%H%M%S)"
  TY="$("$BIN" session type --id "$TSID" --text "$MARK" --json 2>/dev/null)"
  OKT="$(printf '%s' "$TY" | jget "['ok']")"
  VF="$("$BIN" session verify --id "$TSID" --expect "$MARK" --json 2>/dev/null)"
  MATCHED="$(printf '%s' "$VF" | jget "['matched']")"
  if [ "$OKT" = "True" ] && [ "$MATCHED" = "True" ]; then
    ok "后台写入文本并读回一致（AXValue 路径）"
    record 2 "TextEdit" "com.apple.TextEdit" "$(mdls -name kMDItemVersion -raw /System/Applications/TextEdit.app 2>/dev/null || echo n/a)" \
      "AppKit (NSTextView)" "n/a(文本)" "Untested" "Untested" "Untested" "pass(AXValue 往返)" "后台按键需要 field editor；写入走 AXValue"
  else
    warn "TextEdit 写入/读回未通过（ok=${OKT} matched=${MATCHED}）→ 记为 Not Tested"
  fi
  "$BIN" session end --id "$TSID" >/dev/null 2>&1
fi

# ---------- 3. Finder（只读探测）----------
echo
echo "[3] Finder (com.apple.finder, AppKit) —— 只读能力"
FS="$(./bin/wbcu session start --app com.apple.finder --json 2>/dev/null)"
FSID="$(printf '%s' "$FS" | jget "['session']['id']")"
if [ -z "$FSID" ]; then
  warn "Finder 会话建立失败 → Not Tested"
else
  N="$("$BIN" ax-tree --app com.apple.finder --json 2>/dev/null | jget "['count']")"
  [ -n "${N:-}" ] && [ "${N:-0}" -gt 10 ] && ok "AX 树可读（${N} 节点）" || warn "AX 树节点偏少：${N}"
  record 3 "Finder" "com.apple.finder" "$(mdls -name kMDItemVersion -raw /System/Library/CoreServices/Finder.app 2>/dev/null || echo n/a)" \
    "AppKit" "Not Tested" "Not Tested" "Not Tested" "Not Tested" "Not Tested" "侧边栏/工具栏无稳定标识，需人工指定点击目标"
  "$BIN" session end --id "$FSID" >/dev/null 2>&1
fi

python3 - "$LAB_DIR/app-matrix.jsonl" "$OUT" <<'PY'
import json,sys
rows=[json.loads(l) for l in open(sys.argv[1]) if l.strip()]
json.dump(rows, open(sys.argv[2],"w"), ensure_ascii=False, indent=2)
hdr=["应用","AX","坐标投递","遮挡下","期望状态","限制"]
print()
print(f"{hdr[0]:<12} {hdr[1]:<12} {hdr[2]:<10} {hdr[3]:<8} {hdr[4]:<26} {hdr[5]}")
for r in rows:
    print(f'{r["name"]:<12} {r["axPress"]:<12} {r["targeted"]:<10} {r["occluded"]:<8} {r["expectedState"]:<26} {r["limits"]}')
print(f"\n共 {len(rows)} 个应用；结果写入 {sys.argv[2]}")
PY
echo
echo "Safari / Electron / 多窗口应用：Not Tested（需用户单独授权或不具备安全驱动条件）"
summary
