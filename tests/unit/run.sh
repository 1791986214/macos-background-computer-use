#!/bin/bash
# 单元测试（无 GUI、无 TCC 依赖）
#
# 覆盖：
#   1) 引擎内置纯逻辑自检（参数解析 / 按键 / 坐标换算 / 主窗口判据 / 状态序列化 / 错误码）
#   2) 源码卫生：不得出现硬编码的个人绝对路径、明文密钥、私有框架符号
#
# 可在 CI 的 macOS runner 上直接跑，不需要任何系统授权。
set -uo pipefail
source "$(cd "$(dirname "$0")/.." && pwd)/lib.sh"

echo "== 单元测试 =="
note "二进制: $BIN"

if [ ! -x "$BIN" ]; then
  bad "找不到可执行文件：${BIN}（先跑 ./scripts/build.sh）"
  summary; exit 1
fi

# ---------- 1. 引擎自检 ----------
echo
echo "[1] 引擎 selftest"
if "$BIN" selftest > /tmp/wbcu-selftest.log 2>&1; then
  ok "selftest 全部通过"
  note "$(tail -1 /tmp/wbcu-selftest.log)"
else
  bad "selftest 失败："
  sed 's/^/     /' /tmp/wbcu-selftest.log | tail -20
fi

# ---------- 2. 源码卫生 ----------
echo
echo "[2] 源码卫生"
SRC="$REPO_ROOT/src"

# 2.1 个人绝对路径泄漏
if grep -rEn "/Users/[a-z]+/" "$SRC" "$REPO_ROOT/mcp" 2>/dev/null | grep -v "文档\|注释\|example" | head -5 | grep -q .; then
  bad "源码含个人绝对路径（应为 \$HOME 或相对路径）"
  grep -rEn "/Users/[a-z]+/" "$SRC" "$REPO_ROOT/mcp" 2>/dev/null | head -5 | sed 's/^/     /'
else
  ok "无硬编码个人路径"
fi

# 2.2 明文密钥
if grep -rEin "(api[_-]?key|secret|token|password)\s*[:=]\s*['\"][A-Za-z0-9_\-]{16,}" "$SRC" "$REPO_ROOT/mcp" 2>/dev/null | head -3 | grep -q .; then
  bad "疑似明文密钥"
else
  ok "无明文密钥"
fi

# 2.3 私有 / 未文档化符号
# 规则：SkyLight(SLS/SLPS) 一律不许出现；_AXUIElementGetWindow 允许，但必须经 dlsym 动态解析
# 且带 nil 兜底（不可直接链接，否则换系统版本会直接崩）。
if grep -rEn "SLPS[A-Za-z]+|SLS[A-Za-z]+" "$SRC" 2>/dev/null | grep -q .; then
  bad "出现 SkyLight 私有符号（禁止集成）："
  grep -rEn "SLPS[A-Za-z]+|SLS[A-Za-z]+" "$SRC" 2>/dev/null | head -3 | sed 's/^/     /'
else
  ok "未使用 SkyLight 私有 API"
fi

if grep -rq "_AXUIElementGetWindow" "$SRC" 2>/dev/null; then
  if grep -rq "dlsym" "$SRC" && grep -rq "guard let fn = axGetWindowSym" "$SRC"; then
    ok "_AXUIElementGetWindow 经 dlsym 解析且有 nil 兜底（已记录在案）"
  else
    bad "_AXUIElementGetWindow 直接链接或缺少兜底 → 换系统版本会崩"
  fi
else
  ok "未依赖 _AXUIElementGetWindow"
fi

# 2.3b shell 脚本里 $VAR 紧跟中文会被当成变量名的一部分（zsh/bash 都会），
#      必须写成 ${VAR}。这个坑踩过两次，做成检查。
CJK_BAD=$(grep -rEn '\$[A-Za-z_][A-Za-z0-9_]*[^ -~\n]' "$REPO_ROOT/scripts" "$REPO_ROOT/tests" --include="*.sh" 2>/dev/null | head -5)
if [ -n "$CJK_BAD" ]; then
  bad "shell 脚本存在 \$VAR 紧贴中文（应写 \${VAR}）："
  echo "$CJK_BAD" | sed 's/^/     /'
else
  ok "shell 变量边界正确（无 \$VAR 紧贴中文）"
fi

# 2.4 源码里不得出现「假装成功」的兜底
if grep -rEn "return true\s*//\s*(忽略|假装|fallback)" "$SRC" 2>/dev/null | head -3 | grep -q .; then
  bad "发现疑似假装成功的兜底"
else
  ok "无「假装成功」兜底"
fi

summary
