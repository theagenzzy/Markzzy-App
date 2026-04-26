#!/usr/bin/env bash
# sign-dmg-local.sh — wraps Sparkle's `sign_update` so the Phase C local
# update test can produce the EdDSA signature that goes into appcast.xml.
# Sparkle rejects every download whose signature doesn't validate against
# the SUPublicEDKey embedded in the running app, so this is mandatory
# even for localhost-only testing.
#
# Usage:
#   ./scripts/sign-dmg-local.sh ~/Desktop/Markzzy-dev.dmg
#
# Prints the base64 signature on stdout, ready to drop into the appcast
# `sparkle:edSignature="…"` attribute.
#
# Where the private key lives: defaults to ~/.markzzy-sparkle.pem (the
# file `generate_keys -x` produced). Override with SPARKLE_PEM=/path/.
set -euo pipefail

DMG="${1:-}"
if [ -z "$DMG" ] || [ ! -f "$DMG" ]; then
    echo "usage: $0 <path-to.dmg>" >&2
    exit 1
fi

PEM="${SPARKLE_PEM:-$HOME/.markzzy-sparkle.pem}"
if [ ! -f "$PEM" ]; then
    cat >&2 <<EOF
❌ Sparkle private key not found at $PEM.

Generate one with:
    brew install --cask sparkle
    generate_keys
    generate_keys -x $PEM

Then keep $PEM safe — losing it strands every installed copy of the app
(they have your old public key embedded and will reject signatures from
a regenerated key).
EOF
    exit 1
fi

# sign_update lives in the Sparkle dev tools tarball. Preferred install
# path is `scripts/install-sparkle-tools.sh` which puts it in
# ~/.local/sparkle-tools/. Fall back to brew cask paths for users who
# managed to keep the deprecated cask alive.
SIGN_TOOL=""
for candidate in \
    "$HOME/.local/sparkle-tools/sign_update" \
    /opt/homebrew/Caskroom/sparkle/*/bin/sign_update \
    /usr/local/Caskroom/sparkle/*/bin/sign_update; do
    if [ -x "$candidate" ]; then
        SIGN_TOOL="$candidate"
        break
    fi
done
if [ -z "$SIGN_TOOL" ]; then
    cat >&2 <<EOF
❌ sign_update binary not found.

Run scripts/install-sparkle-tools.sh first — it pulls the tools straight
from sparkle-project/Sparkle's GitHub release and strips the macOS
quarantine attribute that breaks the deprecated brew cask.
EOF
    exit 1
fi

"$SIGN_TOOL" "$DMG" "$(cat "$PEM")"
