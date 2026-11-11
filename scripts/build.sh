#!/bin/bash
# build.sh — 编译 wbcu（WorkBuddy Background Computer Use 原生引擎）
#
# 用法：
#   ./scripts/build.sh [输出路径]
#
# 注意：本机 macOS 27.0 SDK 与 CommandLineTools 的 Swift 6.3.3 不匹配，
# 默认优先使用 MacOSX26.5.sdk；不存在时才回落到 xcrun --show-sdk-path。
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$REPO_DIR/bin/wbcu}"

pick_sdk() {
  for c in /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
           /Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk; do
    [ -d "$c" ] && { echo "$c"; return; }
  done
  xcrun --show-sdk-path
}
SDK="$(pick_sdk)"

# 递归收集全部 Swift 源（模块已按职责分目录）
SOURCES=()
while IFS= read -r f; do SOURCES+=("$f"); done < <(find "$REPO_DIR/src" -name '*.swift' -type f | sort)
if [ ${#SOURCES[@]} -eq 0 ]; then echo "没有找到 Swift 源码" >&2; exit 1; fi

TARGET_FLAG=()
if [ "$(uname -m)" = "arm64" ]; then TARGET_FLAG=(-target arm64-apple-macos14.0);
else TARGET_FLAG=(-target x86_64-apple-macos14.0); fi

mkdir -p "$(dirname "$OUT")"
swiftc \
  -sdk "$SDK" \
  -swift-version 5 \
  -O \
  "${TARGET_FLAG[@]}" \
  -o "$OUT" \
  "${SOURCES[@]}" \
  -framework AppKit \
  -framework Cocoa \
  -framework ScreenCaptureKit \
  -framework ApplicationServices \
  -framework CoreGraphics \
  -framework CoreMedia \
  -framework ImageIO \
  -framework UniformTypeIdentifiers \
  -framework CoreImage

echo "built: $OUT  (sdk=$(basename "$SDK"), files=${#SOURCES[@]})"

# 覆盖层辅助 bundle：虚拟光标 daemon 必须是「代理型 App」（LSUIElement），
# 否则它作为普通可激活进程启动时会顶掉用户前台（实测：WorkBuddy → wbcu）。
# 用「事后把前台还回去」去补是错的：抢的那一下用户已经感觉到了，
# 而且还原时机一旦有偏差，会把焦点还给错误的应用（实测还成了 ChatGPT）。
make_overlay_bundle() {
  local app="$REPO_DIR/build/ThirdHandOverlay.app"
  rm -rf "$app"
  mkdir -p "$app/Contents/MacOS"
  cp "$OUT" "$app/Contents/MacOS/wbcu"
  cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>ThirdHandOverlay</string>
<key>CFBundleIdentifier</key><string>com.workbuddy.thirdhand.overlay</string>
<key>CFBundleExecutable</key><string>wbcu</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.4.1</string>
<key>LSUIElement</key><true/>
<key>LSBackgroundOnly</key><false/>
<key>NSHighResolutionCapable</key><true/>
<key>LSMinimumSystemVersion</key><string>14.0</string>
</dict></plist>
PLIST
  codesign --force --sign - "$app" 2>/dev/null || true
  echo "built overlay: $app (LSUIElement, 不参与应用切换)"
}
make_overlay_bundle
"$OUT" version
