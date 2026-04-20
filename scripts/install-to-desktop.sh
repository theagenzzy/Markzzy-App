#!/usr/bin/env bash
# install-to-desktop.sh
# Builds Markzzy, wraps it in a .app bundle with a generated icon, and places it on ~/Desktop.
set -euo pipefail

PROJECT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$PROJECT/.build/release"
BUNDLE="$HOME/Desktop/Markzzy.app"
ICONSET="$PROJECT/.build/AppIcon.iconset"
ICNS="$PROJECT/.build/AppIcon.icns"

echo "==> Building Markzzy (release)..."
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
(cd "$PROJECT" && xcrun swift build -c release)

echo "==> Generating icon..."
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
xcrun swift "$PROJECT/scripts/generate-icon.swift" "$ICONSET"
iconutil -c icns -o "$ICNS" "$ICONSET"

echo "==> Assembling Markzzy.app..."
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp "$BUILD_DIR/Markzzy" "$BUNDLE/Contents/MacOS/Markzzy"
cp "$ICNS" "$BUNDLE/Contents/Resources/AppIcon.icns"

cat > "$BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Markzzy</string>
    <key>CFBundleDisplayName</key><string>Markzzy</string>
    <key>CFBundleIdentifier</key><string>dev.markzzy.app</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleExecutable</key><string>Markzzy</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSCameraUsageDescription</key><string>Markzzy usa la cámara (o tu iPhone vía Continuity) para grabar tu cara.</string>
    <key>NSMicrophoneUsageDescription</key><string>Markzzy graba tu voz junto con la pantalla.</string>
    <key>NSScreenCaptureUsageDescription</key><string>Markzzy necesita grabar tu pantalla.</string>
</dict>
</plist>
PLIST

# Sign with stable self-signed identity if cert exists.
# Use SHA-1 hash directly (find-identity doesn't always surface it as a valid identity,
# but codesign accepts the hash fine).
CERT_SHA=$(security find-certificate -c "Markzzy Self Sign" -Z login.keychain 2>/dev/null \
    | awk '/SHA-1 hash:/ {print $NF}' | head -1)
if [ -n "$CERT_SHA" ]; then
    echo "==> Firmando con Markzzy Self Sign ($CERT_SHA)"
    codesign --force --deep --sign "$CERT_SHA" --identifier dev.markzzy.app "$BUNDLE"
else
    echo "==> ⚠️  Sin cert estable — firmando ad-hoc (TCC va a repreguntar)."
    echo "    Corre una vez: ./scripts/setup-signing.sh"
    codesign --force --deep --sign - --identifier dev.markzzy.app "$BUNDLE"
fi

# Bounce Finder to refresh icon cache
touch "$BUNDLE"

echo ""
echo "✅ Listo. Abre el icono en tu Escritorio:"
echo "    open \"$BUNDLE\""
