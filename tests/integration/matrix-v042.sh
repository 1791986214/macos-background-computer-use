#!/bin/bash
# matrix-v042.sh — v0.4.2 定向投递真实行为矩阵
#
# 目的：把「投递成功」和「操作成功」彻底分开。
# 判据只有一个：目标 UI 真的变了（计数按钮的 count 有没有 +1）。
#
# 六个用例把三个变量拆开：
#   · 目标 App 是不是前台
#   · 目标窗口有没有被别的 App 遮挡
#   · 目标控件是不是 acceptsFirstMouse（NSButton=false / CanvasView=true）
#
# 输出：/tmp/wbcu-lab/matrix-v042.jsonl（每行一个用例的完整结果）
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
LAB=/tmp/wbcu-lab
TT="$HERE/build/TestTarget.app"
POSTER="$HERE/build/poster"
COVER="$HERE/build/Cover.app"
OUT="$LAB/matrix-v042.jsonl"

mkdir -p "$LAB"
: > "$OUT"

kill_all() {
  pkill -f "$COVER/Contents/MacOS/Cover" 2>/dev/null
  pkill -f "$TT/Contents/MacOS/TestTarget" 2>/dev/null
  sleep 0.3
}

kill_cover() { pkill -f "$COVER/Contents/MacOS/Cover" 2>/dev/null; sleep 0.3; }

FRONT_BEFORE="$(osascript -e 'tell application "System Events" to get bundle identifier of first application process whose frontmost is true' 2>/dev/null)"
RESTORE_APP="$(osascript -e 'tell application "System Events" to get name of first application process whose frontmost is true' 2>/dev/null)"

cleanup() {
  kill_all
  [ -n "${RESTORE_APP:-}" ] && osascript -e "tell application \"${RESTORE_APP}\" to activate" >/dev/null 2>&1
}
trap cleanup EXIT

kill_all
open -n "$TT"
# 等 targets.json 新鲜出炉
for _ in $(seq 1 60); do
  [ -f "$LAB/targets.json" ] && break
  sleep 0.1
done
sleep 1.2

read -r WINX WINY WINW WINH < <(python3 - "$LAB/targets.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
f=d["windowCGFrame"]
print(int(f["X"]),int(f["Y"]),int(f["Width"]),int(f["Height"]))
PY
)
echo "目标窗口 CG frame: ($WINX,$WINY) ${WINW}x${WINH}"

set_state() {
  case "$1" in
    front)
      kill_cover
      osascript -e 'tell application id "com.tencent.wbcu.lab" to activate' >/dev/null 2>&1
      sleep 0.7
      ;;
    bg)
      kill_cover
      open -n "$COVER" --args --rect 20,20,300,200 --label BGCover
      sleep 1.0
      ;;
    occluded)
      kill_cover
      open -n "$COVER" --args --rect "$WINX,$WINY,$WINW,$WINH" --label OccCover
      sleep 1.0
      ;;
  esac
}

run_case() {
  local id="$1" state="$2" mode="$3" tgt="$4" note="$5"
  set_state "$state"
  local front
  front="$(osascript -e 'tell application "System Events" to get bundle identifier of first application process whose frontmost is true' 2>/dev/null)"
  local res
  res="$("$POSTER" --mode "$mode" --target "$tgt" --json 2>/dev/null)"
  python3 - "$id" "$state" "$mode" "$tgt" "$note" "$front" "$res" <<'PY' >> "$OUT"
import json,sys
cid,state,mode,tgt,note,front,raw=sys.argv[1:8]
try:
    r=json.loads(raw) if raw.strip() else {}
except Exception:
    r={}
rec={"id":cid,"state":state,"mode":mode,"target":tgt,"note":note,
     "frontAtRun":front,
     "uiObserved":r.get("uiObserved"),
     "uiDelta":r.get("uiDelta"),
     "appActiveAtEvent":r.get("appActiveAtEvent"),
     "events":r.get("events"),
     "frontmostChanged":r.get("frontmostChanged"),
     "mouseMoved":r.get("mouseMoved"),
     "axError":r.get("axError","")}
print(json.dumps(rec,ensure_ascii=False))
PY
}

echo "── 用例 ──"
run_case E1 front     w5158local btnCount "目标前台，NSButton"
run_case E2 bg        w5158local btnCount "目标后台不遮挡，NSButton"
run_case E3 occluded  w5158local btnCount "目标后台且被遮挡，NSButton"
run_case E4 occluded  ax         btnCount "目标后台且被遮挡，AXPress"
run_case E5 bg        w5158local canvas   "目标后台不遮挡，Canvas(acceptsFirstMouse)"
run_case E6 occluded  keywin     btnCount "目标被遮挡，AX设main/focused后投递"
run_case E7 occluded  w5158local canvas   "目标被遮挡，Canvas(acceptsFirstMouse)"
run_case E8 occluded  w5158local webBtn   "目标被遮挡，WKWebView 按钮"
run_case E9 occluded  ax         webBtn   "目标被遮挡，WKWebView 走 AXPress"

echo
python3 - "$OUT" <<'PY'
import json,sys
rows=[json.loads(l) for l in open(sys.argv[1]) if l.strip()]
w=max(len(r["id"]+" "+r["state"]) for r in rows)
print(f"{'用例':<{w}}  {'模式':<14} {'控件':<10} {'UI变了':<6} {'事件数':<6} 说明")
for r in rows:
    ok = "是" if r["uiObserved"] else "否"
    ev = len(r["events"] or [])
    print(f'{(r["id"]+" "+r["state"]):<{w}}  {r["mode"]:<14} {r["target"]:<10} {ok:<6} {ev:<6} {r["note"]}')
PY
