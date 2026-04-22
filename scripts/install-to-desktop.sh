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

# Sparkle.framework must sit next to the executable because the binary
# was linked with rpath @loader_path (set by SwiftPM).
if [ -d "$BUILD_DIR/Sparkle.framework" ]; then
    cp -R "$BUILD_DIR/Sparkle.framework" "$BUNDLE/Contents/MacOS/Sparkle.framework"
fi

LS_ENV_BLOCK=""
if [ -n "${MARKZZY_API_BASE:-}" ]; then
    echo "==> Baking MARKZZY_API_BASE=$MARKZZY_API_BASE into Info.plist"
    LS_ENV_BLOCK="
    <key>LSEnvironment</key>
    <dict>
        <key>MARKZZY_API_BASE</key><string>${MARKZZY_API_BASE}</string>
    </dict>"
fi

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
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key><string>dev.markzzy.app.activate</string>
            <key>CFBundleURLSchemes</key>
            <array>
                <string>markzzy</string>
            </array>
        </dict>
    </array>${LS_ENV_BLOCK}
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
    # Explicit designated requirement based on identifier + cert hash (both stable
    # across rebuilds). Without this, codesign falls back to cdhash-based DR which
    # changes every build and forces macOS TCC (Privacy) to re-prompt for screen
    # recording, camera, mic, etc. on every rebuild.
    REQ_FILE="$PROJECT/.build/markzzy.req"
    cat > "$REQ_FILE" <<REQ
designated => identifier "dev.markzzy.app" and certificate leaf = H"$CERT_SHA"
REQ
    codesign --force --deep \
        --sign "$CERT_SHA" \
        --identifier dev.markzzy.app \
        --requirements "$REQ_FILE" \
        "$BUNDLE"
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
