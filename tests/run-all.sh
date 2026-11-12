#!/bin/bash
# 测试总入口
#
#   ./tests/run-all.sh            # 单元 + 集成（缺权限则跳过，不假绿）
#   ./tests/run-all.sh unit       # 只跑单元（CI 默认）
#   ./tests/run-all.sh all        # 单元 + 集成 + 回归（含 fixture，最完整）
#
# 分层原则：
#   单元  = 纯逻辑，任何机器都能跑，CI 必跑
#   集成  = 需要真实桌面 + 系统授权，人在机器前时跑
#   回归  = 历史验收矩阵（指示器生命周期等），需要 GUI
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
MODE="${1:-auto}"
FAIL=0

echo "######## 单元测试 ########"
"$HERE/unit/run.sh" || FAIL=$((FAIL + 1))

if [ "$MODE" = "unit" ]; then
  [ "$FAIL" -eq 0 ] && echo "✅ 单元测试通过" || echo "❌ 单元测试失败"
  exit "$FAIL"
fi

echo
echo "######## 集成测试：会话层 ########"
"$HERE/integration/session.sh" || FAIL=$((FAIL + 1))

if [ "$MODE" = "all" ]; then
  echo
  echo "######## 集成测试：后台投递对照（需 fixture） ########"
  if [ -x "$HERE/integration/build-fixture.sh" ]; then
    "$HERE/integration/build-fixture.sh" >/dev/null 2>&1 && \
      "$HERE/integration/background-demo.sh" || \
      echo "  ⚠️ fixture 未就绪，跳过"
  fi

  echo
  echo "######## 回归测试：v0.4.2 光标窗口与后台投递 ########"
  # 这五条是本轮修复的验收面；任一条失败都不允许发版。
  # 全部需要真实桌面 + GUI，缺授权时各自 warn 并计入 SKIPPED。
  for t in cursor-window-bounds background-targeted-click window-switch-isolation \
           occlusion-behavior occlusion-layers ghost-cleanup; do
    echo
    "$HERE/regression/$t.sh" || FAIL=$((FAIL + 1))
  done

  echo
  echo "######## 真实用户并发交互（需要用户在场操作）########"
  "$HERE/concurrency/user-concurrent.sh" 8 26 || FAIL=$((FAIL + 1))

  echo
  echo "######## 真实应用兼容性矩阵 ########"
  "$HERE/regression/app-matrix.sh" || FAIL=$((FAIL + 1))

  echo
  echo "######## 回归测试：历史验收矩阵 ########"
  # 需要 Calculator + GUI；首次跑可能需要重新授权
  "$HERE/regression/verify.sh" com.apple.calculator || FAIL=$((FAIL + 1))
fi

echo
if [ "$FAIL" -eq 0 ]; then echo "✅ 全部测试通过"; else echo "❌ 有 $FAIL 组失败"; fi
exit "$FAIL"
