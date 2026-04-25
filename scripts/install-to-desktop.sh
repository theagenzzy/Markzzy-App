#!/usr/bin/env bash
# install-to-desktop.sh
# Builds Markzzy, wraps it in a .app bundle with a generated icon, and places it on ~/Desktop.
set -euo pipefail

PROJECT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$PROJECT/.build/release"
BUNDLE="$HOME/Desktop/Markzzy.app"
ICONSET="$PROJECT/.build/AppIcon.iconset"
ICNS="$PROJECT/.build/AppIcon.icns"
ENTITLEMENTS="$PROJECT/Resources/Markzzy.entitlements"

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
    <key>NSCameraUseContinuityCameraDeviceType</key><true/>
    <!-- Disable Sparkle auto-updates on local dev builds. Local builds
         intentionally don't ship SUPublicEDKey, so Sparkle would refuse
         to install any update anyway — this flag just prevents the
         silent feed fetch that happens on launch. Release builds
         (via .github/workflows/release.yml) override these. -->
    <key>SUEnableAutomaticChecks</key><false/>
    <key>SUEnableInstallerLauncherService</key><false/>
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

# ---------------------------------------------------------------------------
# Code signing
#
# We use the stable self-signed identity ("Markzzy Self Sign") so macOS TCC
# (Camera, Mic, Screen Recording) keeps the app's permissions across rebuilds.
# Without a stable identity, every rebuild would force the user to re-grant
# every permission.
#
# Why we DO NOT use `codesign --deep`:
#   Sparkle.framework ships 5 nested signed bundles (Sparkle, Updater.app,
#   Autoupdate, Downloader.xpc, Installer.xpc), each with its OWN bundle
#   identifier (e.g. org.sparkle-project.Sparkle). `--deep --identifier
#   dev.markzzy.app` would (a) overwrite every nested identifier with our
#   own — which breaks Sparkle at runtime — and (b) trigger a separate
#   keychain access for every nested binary, prompting the user 3-5 times
#   per build. Instead we sign each piece individually (deepest first,
#   per Apple's docs) and `--preserve-metadata=identifier,entitlements,flags`
#   so Sparkle's identifiers and hardened-runtime flags survive.
# ---------------------------------------------------------------------------

CERT_SHA=$(security find-certificate -c "Markzzy Self Sign" -Z login.keychain 2>/dev/null \
    | awk '/SHA-1 hash:/ {print $NF}' | head -1)

# Helper: sign a single bundle/binary, preserving its original identifier,
# entitlements, and runtime flags. One codesign invocation = at most one
# keychain access. With the partition-list correctly authorized in
# scripts/setup-signing.sh, this should be ZERO prompts.
sign_one() {
    local target="$1"
    local req_file="$2"
    codesign --force \
        --sign "$CERT_SHA" \
        --preserve-metadata=identifier,entitlements,flags \
        --requirements "$req_file" \
        --timestamp=none \
        "$target"
}

if [ -n "$CERT_SHA" ]; then
    echo "==> Firmando con Markzzy Self Sign ($CERT_SHA)"

    # Designated requirement that doesn't move per-build.
    REQ_FILE="$PROJECT/.build/markzzy.req"
    cat > "$REQ_FILE" <<REQ
designated => identifier "dev.markzzy.app" and certificate leaf = H"$CERT_SHA"
REQ

    # Generic DR for nested Sparkle pieces (use their own identifier, hashed cert).
    REQ_NESTED="$PROJECT/.build/markzzy-nested.req"
    cat > "$REQ_NESTED" <<REQ
designated => certificate leaf = H"$CERT_SHA"
REQ

    SPARKLE_FW="$BUNDLE/Contents/MacOS/Sparkle.framework"
    if [ -d "$SPARKLE_FW" ]; then
        # Deepest first: helper executables, then XPC services, then Updater.app,
        # then the framework itself. Each is one codesign invocation.
        echo "    · Sparkle/Autoupdate"
        sign_one "$SPARKLE_FW/Versions/B/Autoupdate" "$REQ_NESTED"
        echo "    · Sparkle/Updater.app"
        sign_one "$SPARKLE_FW/Versions/B/Updater.app" "$REQ_NESTED"
        echo "    · Sparkle/Downloader.xpc"
        sign_one "$SPARKLE_FW/Versions/B/XPCServices/Downloader.xpc" "$REQ_NESTED"
        echo "    · Sparkle/Installer.xpc"
        sign_one "$SPARKLE_FW/Versions/B/XPCServices/Installer.xpc" "$REQ_NESTED"
        echo "    · Sparkle.framework"
        sign_one "$SPARKLE_FW" "$REQ_NESTED"
    fi

    echo "    · Markzzy (outer)"
    # Outer binary signed with our identifier + entitlements (camera/mic) +
    # Hardened Runtime. Hardened Runtime blocks dylib injection, prevents
    # arbitrary code from claiming our entitlements, and is required for
    # notarization. Self-signed builds work fine with --options=runtime;
    # no notarization needed for direct distribution.
    # No --deep: nested pieces are already signed and we don't want them
    # rewritten.
    codesign --force \
        --sign "$CERT_SHA" \
        --identifier dev.markzzy.app \
        --entitlements "$ENTITLEMENTS" \
        --requirements "$REQ_FILE" \
        --options=runtime \
        --timestamp=none \
        "$BUNDLE"

    echo "    · Verificando firma…"
    codesign --verify --verbose=2 "$BUNDLE" 2>&1 | head -10 || {
        echo ""
        echo "    ⚠️  La verificación de firma falló."
        echo "       Esto suele significar que la partition list de la llave"
        echo "       privada NO está autorizada para codesign."
        echo "       Corre: ./scripts/setup-signing.sh"
        exit 1
    }
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
