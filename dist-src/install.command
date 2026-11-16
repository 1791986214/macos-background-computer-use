#!/bin/bash
# Third Hand v0.5.1 安装脚本（双击即可运行）
set -u
cd "$(dirname "$0")" || exit 1
HERE="$(pwd)"

echo "=== Third Hand v0.5.1 安装 ==="
echo

# 1) 架构检查
ARCH="$(uname -m)"
if [ "$ARCH" != "arm64" ]; then
  echo "❌ 这个包里的二进制是 arm64（Apple Silicon），当前机器是 ${ARCH}。"
  echo "   Intel Mac 请从仓库自行编译：git clone 后 bash scripts/build.sh"
  echo
  read -r -p "按回车退出..." _
  exit 1
fi

# 2) 去掉隔离标记（未签名二进制必须做，否则会被 Gatekeeper 拦）
echo "· 移除隔离标记…"
xattr -dr com.apple.quarantine "$HERE" 2>/dev/null || true

# 3) 装二进制
mkdir -p "$HOME/.local/bin" "$HOME/.local/share/wbcu" "$HOME/.workbuddy/skills"
echo "· 安装 wbcu → ~/.local/bin/wbcu"
install -m 0755 "$HERE/bin/wbcu" "$HOME/.local/bin/wbcu" || { echo "❌ 安装失败"; exit 1; }

# 4) 覆盖层（虚拟光标的宿主，LSUIElement，不参与应用切换）
if [ -d "$HERE/ThirdHandOverlay.app" ]; then
  echo "· 安装覆盖层 → ~/.local/share/wbcu/ThirdHandOverlay.app"
  rm -rf "$HOME/.local/share/wbcu/ThirdHandOverlay.app"
  cp -R "$HERE/ThirdHandOverlay.app" "$HOME/.local/share/wbcu/" || true
fi

# 5) 技能
if [ -d "$HERE/skill/workbuddy-third-hand" ]; then
  echo "· 安装技能 → ~/.workbuddy/skills/workbuddy-third-hand"
  rm -rf "$HOME/.workbuddy/skills/workbuddy-third-hand"
  cp -R "$HERE/skill/workbuddy-third-hand" "$HOME/.workbuddy/skills/" || true
fi

echo
echo "=== 自检 ==="
"$HOME/.local/bin/wbcu" doctor || true

echo
echo "=== 还需要你手动做两件事 ==="
echo "1) 系统设置 → 隐私与安全性 → 辅助功能：勾上你用来运行命令的终端 App"
echo "   （或运行：~/.local/bin/wbcu perm --prompt）"
echo "2) 给要操作的应用授权："
echo "   ~/.local/bin/wbcu guard --app com.apple.calculator --allow"
echo
echo "验证一次后台点击："
echo "   ~/.local/bin/wbcu launch --app com.apple.calculator --json"
echo "   ~/.local/bin/wbcu session click --app com.apple.calculator --identifier One --expect 1 --expect-el role:AXStaticText --json"
echo
read -r -p "按回车关闭..." _
