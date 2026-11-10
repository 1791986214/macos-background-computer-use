#!/bin/bash
# 把 wbcu 打包成独立 .app bundle —— 获得自己的 TCC 身份（与 Codex 的
# "Codex Computer Use.app / com.openai.sky.CUAService" 同一套路）
#
# 为什么需要：CLI 子进程的权限归因给父 App（WorkBuddy）。想做到
# 「Computer Use 的屏幕录制/辅助功能权限独立于 WorkBuddy」，就必须是一个
# 独立签名的 bundle，并由父进程用 responsibility_spawnattrs_setdisclaim 启动。
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
APP="${1:-$HERE/build/WorkBuddy Computer Use.app}"
BIN="$HERE/bin/wbcu"
[ -x "$BIN" ] || { echo "先跑 ./build.sh"; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/wbcu"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>WorkBuddy Computer Use</string>
  <key>CFBundleDisplayName</key><string>WorkBuddy Computer Use</string>
  <key>CFBundleIdentifier</key><string>com.tencent.workbuddy.computeruse</string>
  <key>CFBundleExecutable</key><string>wbcu</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSScreenCaptureUsageDescription</key>
  <string>WorkBuddy 需要读取你指定的应用窗口画面，以便代替你完成界面操作。</string>
  <key>NSAccessibilityUsageDescription</key>
  <string>WorkBuddy 需要读取并操作你指定的应用界面元素。</string>
</dict>
</plist>
PLIST

echo 'APPL????' > "$APP/Contents/PkgInfo"
# ad-hoc 签名即可让 TCC 把它当作独立主体；正式分发需 Developer ID + notarize
codesign --force --deep --sign - --identifier com.tencent.workbuddy.computeruse "$APP" 2>&1 | tail -2

echo "打包完成: $APP"
echo "检查 TCC 身份（应当与 WorkBuddy 分离，权限默认为 false）:"
"$APP/Contents/MacOS/wbcu" perm || true
