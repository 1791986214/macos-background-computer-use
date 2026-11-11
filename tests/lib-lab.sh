#!/bin/bash
# lib-lab.sh — 真实桌面实验台
#
# 提供：受控 AppKit 目标（TestTarget）+ 遮挡/前台夹具（Cover）+ 断言小工具。
# 所有用例都建立在同一句话上：**判据是目标 UI 真的变了，不是投递没报错**。
#
# 用法：source 本文件后调 lab_* 函数。

LAB_DIR="${LAB_DIR:-/tmp/wbcu-lab}"
LAB_INTEG="$(cd "$(dirname "${BASH_SOURCE[0]}")/../tests/integration" && pwd)"
LAB_TARGET_APP="$LAB_INTEG/build/TestTarget.app"
LAB_COVER_APP="$LAB_INTEG/build/Cover.app"
LAB_TARGET_BID="com.tencent.wbcu.lab"
LAB_COVER_BID="com.tencent.wbcu.cover"

lab_need_build() {
  if [ ! -x "$LAB_TARGET_APP/Contents/MacOS/TestTarget" ] || [ ! -x "$LAB_COVER_APP/Contents/MacOS/Cover" ]; then
    echo "  构建实验台…"
    bash "$LAB_INTEG/build-fixture.sh" >/dev/null 2>&1 || { echo "构建失败"; return 1; }
  fi
  mkdir -p "$LAB_DIR"
}

lab_stop() {
  pkill -f "$LAB_COVER_APP/Contents/MacOS/Cover" 2>/dev/null
  pkill -f "$LAB_TARGET_APP/Contents/MacOS/TestTarget" 2>/dev/null
  sleep 0.3
}

# 启动目标并要求 targets.json 是「这次新写的」，避免读到上一轮的旧坐标
lab_start_target() {
  lab_stop
  rm -f "$LAB_DIR/targets.json" "$LAB_DIR/state.json"
  open -n "$LAB_TARGET_APP"
  for _ in $(seq 1 80); do
    [ -f "$LAB_DIR/targets.json" ] && break
    sleep 0.1
  done
  if [ ! -f "$LAB_DIR/targets.json" ]; then
    echo "目标没起来"; return 1
  fi
  sleep 1.0
  return 0
}

lab_cover_far() {
  pkill -f "$LAB_COVER_APP/Contents/MacOS/Cover" 2>/dev/null
  sleep 0.2
  open -n "$LAB_COVER_APP" --args --rect 20,20,300,200 --label BGCover
  sleep 0.9
}

lab_cover_over() {
  local rect
  rect="$(python3 - "$LAB_DIR/targets.json" <<'PY'
import json,sys
f=json.load(open(sys.argv[1]))["windowCGFrame"]
print("%d,%d,%d,%d"%(int(f["X"]),int(f["Y"]),int(f["Width"]),int(f["Height"])))
PY
)"
  pkill -f "$LAB_COVER_APP/Contents/MacOS/Cover" 2>/dev/null
  sleep 0.2
  open -n "$LAB_COVER_APP" --args --rect "$rect" --label OccCover
  sleep 0.9
}

lab_front_target() {
  pkill -f "$LAB_COVER_APP/Contents/MacOS/Cover" 2>/dev/null
  sleep 0.2
  osascript -e "tell application id \"$LAB_TARGET_BID\" to activate" >/dev/null 2>&1
  sleep 0.7
}

# 取某个控件的全局中心点与目标窗口信息：输出 "wid cx cy pid"
lab_geom() {
  python3 - "$LAB_DIR/targets.json" "${1:-btnCount}" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
b=d["targets"][sys.argv[2]]
print("%d %d %d %d"%(d["windowNumber"],int(b["cx"]),int(b["cy"]),d["pid"]))
PY
}

lab_clicks() {
  python3 -c "
import json
try: print(json.load(open('$LAB_DIR/state.json'))['clicks'])
except Exception: print(-1)
"
}

lab_front_bid() {
  osascript -e 'tell application "System Events" to get bundle identifier of first application process whose frontmost is true' 2>/dev/null
}

# 用户是否正在用电脑：忙的时候一切实验结论都不可信
lab_user_busy() {
  local idle
  idle="$(python3 -c "
import subprocess,json
out=subprocess.run(['$BIN','idle','--json'],capture_output=True,text=True).stdout
try: print(json.loads(out)['secondsSinceLastInput'])
except Exception: print(999)
")"
  python3 -c "import sys; sys.exit(0 if float('$idle') < 1.5 else 1)"
}

# 有界等待用户空闲：最多等 max 秒，超时就放弃（不阻塞、不猜测结论）
lab_wait_idle() {
  local max="${1:-20}" waited=0
  while [ "$waited" -lt "$max" ]; do
    lab_user_busy || return 0
    sleep 1
    waited=$((waited + 1))
  done
  return 1
}
