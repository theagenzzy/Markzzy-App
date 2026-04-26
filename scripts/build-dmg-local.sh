#!/usr/bin/env bash
# build-dmg-local.sh — produces a Markzzy-dev.dmg on the Desktop with the
# same drag-to-Applications layout the release workflow ships, so you can
# preview the visual experience without running CI or having an Apple
# Developer cert. Re-uses the .app produced by install-to-desktop.sh
# (self-signed) — Gatekeeper will warn on first open, just right-click →
# Open the first time and macOS remembers it.
set -euo pipefail

PROJECT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$HOME/Desktop/Markzzy.app"
DMG="$HOME/Desktop/Markzzy-dev.dmg"
BG="$PROJECT/Resources/dmg-background.png"

# Step 1: ensure create-dmg is installed (homebrew formula).
if ! command -v create-dmg >/dev/null 2>&1; then
    echo "==> Installing create-dmg via Homebrew..."
    brew install create-dmg
fi

# Step 2: ensure the .app is fresh. install-to-desktop.sh handles the
# build + signing; if the user is iterating on the dmg background only,
# they can pass --skip-build to avoid the rebuild.
if [ "${1:-}" != "--skip-build" ]; then
    echo "==> Building Markzzy.app via install-to-desktop.sh..."
    "$PROJECT/scripts/install-to-desktop.sh"
fi

if [ ! -d "$APP" ]; then
    echo "❌ $APP not found. Run install-to-desktop.sh first." >&2
    exit 1
fi

if [ ! -f "$BG" ]; then
    echo "==> Generating dmg background…"
    xcrun swift "$PROJECT/scripts/generate-dmg-background.swift" "$BG"
fi

# Step 3: nuke any leftover dmg + any half-mounted volume from a previous run.
# create-dmg refuses to overwrite, and a stuck mount silently breaks future
# runs with "device busy".
rm -f "$DMG"
hdiutil detach "/Volumes/Markzzy dev" 2>/dev/null || true
hdiutil detach "/Volumes/Markzzy" 2>/dev/null || true

# Step 4: produce the dmg with the same layout release.yml uses, so what
# you see locally is what users will see in production.
echo "==> Building $DMG…"
create-dmg \
    --volname "Markzzy dev" \
    --background "$BG" \
    --window-pos 200 120 \
    --window-size 600 400 \
    --icon-size 128 \
    --icon "Markzzy.app" 150 200 \
    --hide-extension "Markzzy.app" \
    --app-drop-link 450 200 \
    --no-internet-enable \
    "$DMG" \
    "$APP"

echo ""
echo "✅ Listo: $DMG"
echo "   Doble-click para previsualizar el layout drag-to-Applications."
