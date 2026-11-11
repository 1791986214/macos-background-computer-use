#!/bin/bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SDK="/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk"
[ -d "$SDK" ] || SDK="$(xcrun --show-sdk-path)"
APP="$HERE/build/TestTarget.app"

rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS"
swiftc -sdk "$SDK" -swift-version 5 -O -target arm64-apple-macos14.0 \
  -o "$APP/Contents/MacOS/TestTarget" "$HERE/Fixture.swift" \
  -framework Cocoa -framework WebKit -framework CoreGraphics

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>TestTarget</string>
<key>CFBundleIdentifier</key><string>com.tencent.wbcu.lab</string>
<key>CFBundleExecutable</key><string>TestTarget</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST

codesign --force --deep --sign - --identifier com.tencent.wbcu.lab "$APP" 2>/dev/null || true

swiftc -sdk "$SDK" -swift-version 5 -O -target arm64-apple-macos14.0 \
  -o "$HERE/build/poster" "$HERE/Poster.swift" \
  -framework Cocoa -framework CoreGraphics

# 遮挡/前台夹具：一个「别的 App」，可把窗口摆到任意位置
COVER="$HERE/build/Cover.app"
rm -rf "$COVER"; mkdir -p "$COVER/Contents/MacOS"
swiftc -sdk "$SDK" -swift-version 5 -O -target arm64-apple-macos14.0 \
  -o "$COVER/Contents/MacOS/Cover" "$HERE/Cover.swift" \
  -framework Cocoa -framework CoreGraphics
cat > "$COVER/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Cover</string>
<key>CFBundleIdentifier</key><string>com.tencent.wbcu.cover</string>
<key>CFBundleExecutable</key><string>Cover</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --deep --sign - --identifier com.tencent.wbcu.cover "$COVER" 2>/dev/null || true

echo "built: $APP"
echo "built: $HERE/build/poster"
echo "built: $COVER"
