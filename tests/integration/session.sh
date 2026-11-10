#!/bin/bash
# 集成测试：会话层端到端（需要真实桌面 + 已授权）
#
# 验证的是一条完整链路：
#   session start → capture → inspect → click → verify → end
# 并且同时断言「用户不受打扰」：真实鼠标零位移、前台应用不变、目标未被激活。
#
# 使用 Calculator（系统自带、AX 树完整、结果可读值断言）。
# 目标窗口会被有意移到屏幕右下角并可能被其他窗口遮挡——这正是要测的场景。
set -uo pipefail
source "$(cd "$(dirname "$0")/.." && pwd)/lib.sh"

APP="com.apple.calculator"
echo "== 集成测试：会话层 =="
note "二进制: $BIN"

require_desktop || { summary; exit 0; }

# 前置：启动目标并授权
open -g -a Calculator 2>/dev/null
sleep 1.5
"$BIN" guard --app "$APP" --allow >/dev/null 2>&1

mouse_pos() { "$BIN" mouse-pos --json 2>/dev/null | python3 -c "import sys,json;d=json.load(sys.stdin);print(f\"{d['x']:.0f},{d['y']:.0f}\")" 2>/dev/null; }
front_app() { "$BIN" apps --json 2>/dev/null | python3 -c "
import sys,json
d=json.load(sys.stdin)
for a in d['apps']:
    if a.get('frontmost') or a.get('active'): print(a['bundleId']); break
" 2>/dev/null; }

echo
echo "[1] 建立会话"
START=$("$BIN" session start --app "$APP" --json 2>&1)
SID=$(echo "$START" | jget "['session']['id']")
if [ -n "$SID" ]; then
  ok "session $SID 已建立"
  note "window=$(echo "$START" | jget "['session']['windowId']") frame=$(echo "$START" | jget "['session']['windowFrame']")"
else
  bad "会话建立失败：$START"
  summary; exit 1
fi

MOUSE0=$(mouse_pos)
FRONT0=$(front_app)
T0=$(date +%s)
IDLE0=$("$BIN" idle --json 2>/dev/null | jget "['secondsSinceLastInput']")
note "基线：鼠标 $MOUSE0  前台 $FRONT0  距上次用户输入 ${IDLE0}s"

echo
echo "[2] 会话内捕获窗口"
if require_screen_recording; then
  CAP=$("$BIN" session capture --id "$SID" --out /tmp/wbcu-sess-cap.png --json 2>&1)
  PIX=$(echo "$CAP" | jget "['pixels']")
  if [ -n "$PIX" ]; then
    ok "捕获成功 $PIX → /tmp/wbcu-sess-cap.png"
    [ -s /tmp/wbcu-sess-cap.png ] && ok "文件非空 $(stat -f%z /tmp/wbcu-sess-cap.png) 字节"
  else
    bad "捕获失败：$CAP"
  fi
fi

echo
echo "[3] 读取 UI 树"
INSPECT=$("$BIN" session inspect --id "$SID" --max 200 --json 2>&1)
N=$(echo "$INSPECT" | jget "['count']")
if [ "${N:-0}" -gt 10 ] 2>/dev/null; then
  ok "读到 $N 个 AX 节点"
else
  bad "AX 树异常：$INSPECT"
fi

echo
echo "[4] 后台点击：清空 → 6 × 7 ="
for label in "全部清除" "6" "乘" "7" "等于"; do
  R=$("$BIN" session click --id "$SID" --text "$label" --label "$label" --json 2>&1)
  MODE=$(echo "$R" | jget "['mode']")
  VER=$(echo "$R" | jget "['verification']")
  if [ "$MODE" = "ax" ] && { [ "$VER" = "changed" ] || [ "$VER" = "no_observable_change" ]; }; then
    if [ "$VER" = "changed" ]; then
      ok "「${label}」 mode=$MODE verify=$VER"
    else
      ok "「${label}」 mode=$MODE verify=${VER}（动作已被接受，但界面无差异——例如本来就是清零状态）"
    fi
  else
    bad "「${label}」 mode=$MODE verify=$VER"
  fi
done

echo
echo "[5] 结果断言（必须读到 42）"
V=$("$BIN" session verify --id "$SID" --expect "42" --json 2>&1)
if [ "$(echo "$V" | jget "['matched']")" = "True" ]; then
  ok "计算器显示 42 —— 后台点击真实生效"
else
  bad "未读到 42：$V"
fi

echo
echo "[6] 目标未被激活"
ACT=$("$BIN" session state --id "$SID" --json 2>&1 | jget "['targetActive']")
if [ "$ACT" = "False" ]; then ok "目标 app 未激活（后台完成）"; else bad "目标被激活了：targetActive=$ACT"; fi

echo
echo "[7] 用户不受打扰"
MOUSE1=$(mouse_pos)
FRONT1=$(front_app)
ELAPSED=$(( $(date +%s) - T0 ))
IDLE1=$("$BIN" idle --json 2>/dev/null | jget "['secondsSinceLastInput']")

# 判据：如果测试期间没有真实用户输入，那么「距上次输入」必然 ≥ 测试耗时。
# 若 IDLE1 < ELAPSED，说明中途有人动了键鼠 —— 此时鼠标/前台的变化归属不明，
# 只能记为「不确定」，既不能算引擎的锅，也不能算过。
USER_TOUCHED=0
python3 -c "import sys; sys.exit(0 if float('${IDLE1:-999}') < ${ELAPSED} - 1 else 1)" 2>/dev/null && USER_TOUCHED=1

if [ "$USER_TOUCHED" = "1" ]; then
  warn "测试期间检测到真实用户输入（idle ${IDLE1}s < 耗时 ${ELAPSED}s）→ 鼠标/前台断言标记为「不确定」"
  note "  鼠标 $MOUSE0 → $MOUSE1   前台 $FRONT0 → $FRONT1"
  note "  这不是引擎缺陷；请在看屏幕没被占用时重跑本测试以获得确定结论"
else
  if [ "$MOUSE0" = "$MOUSE1" ]; then
    ok "真实鼠标零位移（${MOUSE0}，整个 ${ELAPSED}s 内无人操作）"
  else
    bad "无人操作期间鼠标却动了：$MOUSE0 → $MOUSE1"
  fi
  if [ "$FRONT0" = "$FRONT1" ]; then
    ok "前台应用未变（${FRONT1}）"
  else
    bad "前台被切换：$FRONT0 → $FRONT1"
  fi
fi

echo
echo "[8] 结束会话并释放资源"
"$BIN" session end --id "$SID" >/dev/null 2>&1
# 只断言「本次会话」被释放，不要求全局为 0（可能还有用户自己的会话）
GONE=$("$BIN" session state --id "$SID" --json 2>/dev/null | jget "['error']")
if [ "$GONE" = "session_not_found" ]; then
  ok "本次会话已释放（状态文件已删除）"
else
  bad "会话仍未释放：$GONE"
fi
if pgrep -x wbcu >/dev/null 2>&1; then
  # ghost daemon 是唯一允许常驻的（且会话清空时应已隐藏）
  note "存在 wbcu 进程（可能是 ghost daemon，检查可见性）"
  "$BIN" ghost hide >/dev/null 2>&1
  ok "已隐藏虚拟光标"
else
  ok "无 wbcu 残留进程"
fi

echo
echo "[9] 错误路径"
E1=$("$BIN" session state --id __nope__ --json 2>&1 | jget "['error']")
[ "$E1" = "session_not_found" ] && ok "未知会话 → $E1" || bad "错误码异常：$E1"
E2=$("$BIN" session click --id "$SID" --x 1 --y 1 --json 2>&1 | jget "['error']")
[ "$E2" = "session_not_found" ] && ok "已结束会话不可再操作 → $E2" || bad "错误码异常：$E2"

summary
