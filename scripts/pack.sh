#!/bin/bash
# pack.sh — 打「发给别人」的分发包
#
#   ./scripts/pack.sh            # 产出 dist/third-hand-v<ver>-full.zip 与 -skill-only.zip
#
# 两个包的区别：
#   full      = 技能 + 二进制 + 覆盖层 + install.command + README（双击即装，对方不用懂命令行）
#   skill-only= 只有 SKILL.md / examples / references（对方自己 clone 仓库装二进制）
#
# 为什么要打包脚本：手工 zip 容易漏文件、容易把绝对路径打进包里（解压出来是 Users/lang/...），
# 也容易忘记先跑 install.sh 把技能同步到本地。这里把三件事一起做掉。
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
VER="$(cd "$REPO" && ./bin/wbcu version 2>/dev/null | tr -d '[:space:]')"
[ -n "$VER" ] || { echo "读不到版本，先 ./scripts/build.sh" >&2; exit 1; }

SKILL_SRC="$REPO/skills/workbuddy-third-hand"
[ -f "$SKILL_SRC/SKILL.md" ] || { echo "技能源缺失: $SKILL_SRC" >&2; exit 1; }

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
PKG="$STAGE/third-hand-v$VER"
mkdir -p "$PKG/bin" "$PKG/skill"

cp "$REPO/bin/wbcu" "$PKG/bin/wbcu"
cp -R "$SKILL_SRC" "$PKG/skill/"
cp -R "$REPO/build/ThirdHandOverlay.app" "$PKG/" 2>/dev/null || true
cp "$REPO/dist-src/README.md" "$PKG/README.md" 2>/dev/null || true
cp "$REPO/dist-src/install.command" "$PKG/" 2>/dev/null || true
chmod +x "$PKG/install.command" 2>/dev/null || true

mkdir -p "$REPO/dist"
( cd "$STAGE" && zip -qr "$REPO/dist/third-hand-v$VER-full.zip" "third-hand-v$VER" -x "*.DS_Store" )
( cd "$SKILL_SRC/.." && zip -qr "$REPO/dist/third-hand-v$VER-skill-only.zip" "workbuddy-third-hand" -x "*.DS_Store" )

echo "✅ 产物："
ls -lh "$REPO/dist"/third-hand-v"$VER"-*.zip | awk '{print "   "$5"  "$9}'
echo
shasum -a 256 "$REPO/dist"/third-hand-v"$VER"-*.zip | sed 's/^/   /'
