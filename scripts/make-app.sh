#!/bin/bash
# Builds the menu bar app as "dist/Clean Mirror.app".
# Signs it with the "Clean Mirror Local Signing" certificate in the login keychain, if there is one
# (create it once with scripts/make-signing-cert.sh), so macOS sees the same app after every rebuild and
# keeps its Screen Recording permission. Without it, it signs ad hoc, which loses the permission on every rebuild.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product CleanMirrorApp

APP="dist/Clean Mirror.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/CleanMirrorApp "$APP/Contents/MacOS/Clean Mirror"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>Clean Mirror</string>
    <key>CFBundleDisplayName</key>
    <string>Clean Mirror</string>
    <key>CFBundleIdentifier</key>
    <string>local.cleanmirror</string>
    <key>CFBundleExecutable</key>
    <string>Clean Mirror</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>15.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

IDENTITY="Clean Mirror Local Signing"
if security find-identity -p codesigning 2>/dev/null | grep -q "\"$IDENTITY\""; then
    codesign --force --sign "$IDENTITY" --identifier local.cleanmirror "$APP"
    echo "Signed with \"$IDENTITY\": Screen Recording permission carries over between builds."
else
    codesign --force --sign - --identifier local.cleanmirror "$APP"
    echo "Warning: \"$IDENTITY\" not found, so signed ad-hoc. macOS will need Screen Recording permission again."
fi
echo "Built $(pwd)/$APP"
