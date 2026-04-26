#!/usr/bin/env bash
# build-dmg-local.sh — produces a Markzzy-dev.dmg on the Desktop with the
# same drag-to-Applications layout the release workflow ships, so you can
# preview the visual experience without running CI or having an Apple
# Developer cert. Re-uses the .app produced by install-to-desktop.sh
# (self-signed) — Gatekeeper will warn on first open, just right-click →
# Open the first time and macOS remembers it.
#
# Uses `dmgbuild` (Python) rather than `create-dmg` (Homebrew bash) so we
# can write the .DS_Store ourselves. The settings file monkey-patches the
# icvp `backgroundColor*` keys to dark navy → Finder's contrast check
# picks white label text. With create-dmg we always got dark labels on
# the dark navy bg (unreadable). See scripts/dmgbuild-settings.py.
set -euo pipefail

PROJECT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$HOME/Desktop/Markzzy.app"
DMG="$HOME/Desktop/Markzzy-dev.dmg"
BG="$PROJECT/Resources/dmg-background.png"
SETTINGS="$PROJECT/scripts/dmgbuild-settings.py"

# Step 1: ensure dmgbuild is installed. It's a tiny pure-python package
# (~600 KB w/ deps: ds_store + mac_alias). Apple's stock python3 ships
# with macOS, so a `pip3 install --user` is enough — no Homebrew needed
# for the dmg tool itself.
if ! command -v dmgbuild >/dev/null 2>&1; then
    # Account for Library/Python/X.Y/bin not always being on PATH.
    DMGBUILD="$(python3 -c 'import sys, os; print(os.path.join(os.path.expanduser("~"), "Library", "Python", f"{sys.version_info.major}.{sys.version_info.minor}", "bin", "dmgbuild"))')"
    if [ ! -x "$DMGBUILD" ]; then
        echo "==> Installing dmgbuild via pip3..."
        pip3 install --user --break-system-packages dmgbuild
    fi
else
    DMGBUILD="$(command -v dmgbuild)"
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

# Always regenerate the background — it's cheap and guarantees recent
# tweaks to generate-dmg-background.swift land in the dmg.
echo "==> Generating dmg background…"
xcrun swift "$PROJECT/scripts/generate-dmg-background.swift" "$BG"

# Step 3: nuke any leftover dmg + any half-mounted volume from a previous run.
# dmgbuild refuses to overwrite, and a stuck mount silently breaks future
# runs with "device busy".
rm -f "$DMG"
hdiutil detach "/Volumes/Markzzy dev" 2>/dev/null || true
hdiutil detach "/Volumes/Markzzy" 2>/dev/null || true

# Step 4: produce the dmg with the same layout release.yml uses, so what
# you see locally is what users will see in production. Settings
# (window size, icon positions, white text color) live in the shared
# settings file so the local + CI dmgs stay byte-identical in layout.
echo "==> Building ${DMG}…"
"$DMGBUILD" \
    -s "$SETTINGS" \
    -D "app=$APP" \
    -D "background=$BG" \
    "Markzzy dev" \
    "$DMG"

echo ""
echo "✅ Listo: $DMG"
echo "   Doble-click para previsualizar el layout drag-to-Applications."
