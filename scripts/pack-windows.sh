#!/usr/bin/env bash
# 在 macOS/Linux 上交叉编译并打包 Windows 发行包。
#
# 为什么维护这个脚本：本机没有 Windows，但交付物必须是「用户能直接跑的东西」。
# dotnet publish -r win-x64 在 macOS 上产出的就是真实的 PE32+ 可执行文件，
# 这里把它连同测试应用、技能文件、安装脚本一起打成 zip。
#
# 用法： ./scripts/pack-windows.sh [win-x64|win-arm64]
set -euo pipefail

RID="${1:-win-x64}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOTNET="${DOTNET:-dotnet}"
if ! command -v "$DOTNET" >/dev/null 2>&1; then
  if [ -x "$HOME/.local/share/dotnet/dotnet" ]; then
    DOTNET="$HOME/.local/share/dotnet/dotnet"
  else
    echo "找不到 dotnet SDK（设置 DOTNET 环境变量，或安装 .NET 8+ SDK）" >&2
    exit 1
  fi
fi

export DOTNET_CLI_TELEMETRY_OPTOUT=1
export DOTNET_NOLOGO=1

VER="$("$DOTNET" msbuild "$ROOT/src-windows/Wbcu.Windows/Wbcu.Windows.csproj" -getProperty:Version -nologo 2>/dev/null | tr -d '\r' | tail -1)"
STAGE="$ROOT/build/windows-$RID"
OUT="$ROOT/dist/wbcu-windows-$RID-$VER.zip"

echo "== 清理 =="
rm -rf "$STAGE"; mkdir -p "$STAGE" "$ROOT/dist"

echo "== 编译 + 单元测试 =="
"$DOTNET" build "$ROOT/src-windows/Wbcu.sln" -c Release -nologo -v q
"$DOTNET" test "$ROOT/src-windows/Wbcu.Tests/Wbcu.Tests.csproj" -c Release --nologo -v q

echo "== 发布 $RID =="
"$DOTNET" publish "$ROOT/src-windows/Wbcu.Windows/Wbcu.Windows.csproj" \
  -c Release -r "$RID" --self-contained false -o "$STAGE" --nologo -v q
"$DOTNET" publish "$ROOT/src-windows/Wbcu.TestApp.Win32/Wbcu.TestApp.Win32.csproj" \
  -c Release -r "$RID" -o "$STAGE/testapps" --nologo -v q
"$DOTNET" publish "$ROOT/src-windows/Wbcu.TestApp/Wbcu.TestApp.csproj" \
  -c Release -r "$RID" -o "$STAGE/testapps" --nologo -v q
"$DOTNET" publish "$ROOT/src-windows/Wbcu.GuiTests/Wbcu.GuiTests.csproj" \
  -c Release -r "$RID" -o "$STAGE/testapps" --nologo -v q

echo "== 附带技能与脚本 =="
mkdir -p "$STAGE/skill"
cp "$ROOT/skills/workbuddy-third-hand/SKILL.md" "$STAGE/skill/SKILL.md"
cp "$ROOT/src-windows/install.ps1" "$ROOT/src-windows/uninstall.ps1" "$STAGE/"
cp "$ROOT/src-windows/install-windows.ps1" "$STAGE/"

echo "== 打包 =="
( cd "$STAGE" && zip -qr "$OUT" . )
ls -lh "$OUT"
echo "完成：$OUT"
