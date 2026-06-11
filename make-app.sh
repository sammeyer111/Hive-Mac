#!/bin/zsh
# Builds Hive.app from the SwiftPM executable.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP="Hive.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp .build/release/Hive "$APP/Contents/MacOS/Hive"

# Piece art lives in the SPM resource bundle; Bundle.module finds it in
# Contents/Resources at runtime.
cp -R .build/release/Hive_Hive.bundle "$APP/Contents/Resources/"

# Icon is checked in; regenerate with:
#   swift tools/make-icon.swift /tmp/AppIcon.png  (then iconutil, see README)
cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>Hive</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>com.local.hive-p2p</string>
    <key>CFBundleName</key>
    <string>Hive</string>
    <key>CFBundleDisplayName</key>
    <string>Hive</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSLocalNetworkUsageDescription</key>
    <string>Hive uses the local network to find and join games hosted nearby.</string>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP"
echo "Built $APP"
