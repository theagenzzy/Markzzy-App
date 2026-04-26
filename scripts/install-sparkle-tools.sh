#!/usr/bin/env bash
# install-sparkle-tools.sh — fetches `generate_keys` and `sign_update` from
# the latest Sparkle GitHub release and parks them in ~/.local/sparkle-tools/
# with the macOS quarantine attribute stripped.
#
# Why not `brew install --cask sparkle`? The cask was deprecated because
# the dev tools aren't notarized, so Gatekeeper kills them on first run
# and macOS sometimes removes the binary outright. Pulling straight from
# the project's release tarball + `xattr -d` is the supported workaround.
set -euo pipefail

DEST="$HOME/.local/sparkle-tools"
mkdir -p "$DEST"

echo "==> Resolving latest Sparkle release…"
TAR_URL=$(curl -fsSL https://api.github.com/repos/sparkle-project/Sparkle/releases/latest \
    | grep -o 'https://github.com/sparkle-project/Sparkle/releases/download/[^"]*\.tar\.xz' \
    | head -1)

if [ -z "$TAR_URL" ]; then
    echo "❌ Could not locate the .tar.xz asset on the latest release page." >&2
    echo "   Check https://github.com/sparkle-project/Sparkle/releases manually." >&2
    exit 1
fi
echo "    found: $TAR_URL"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo "==> Downloading…"
curl -fsSL "$TAR_URL" -o "$TMP/sparkle.tar.xz"

echo "==> Extracting…"
tar -xf "$TMP/sparkle.tar.xz" -C "$TMP"

# The tarball layout is: bin/generate_keys, bin/sign_update, Sparkle.framework, …
# We only need the two CLI tools.
cp "$TMP/bin/generate_keys" "$DEST/generate_keys"
cp "$TMP/bin/sign_update"   "$DEST/sign_update"

echo "==> Stripping macOS quarantine attribute…"
xattr -d com.apple.quarantine "$DEST/generate_keys" 2>/dev/null || true
xattr -d com.apple.quarantine "$DEST/sign_update"   2>/dev/null || true
chmod +x "$DEST/generate_keys" "$DEST/sign_update"

cat <<EOF

✅ Installed Sparkle tools to $DEST

Generate the EdDSA key pair now:
    $DEST/generate_keys
    $DEST/generate_keys -x ~/.markzzy-sparkle.pem

Optional — add to your PATH so future calls are shorter:
    echo 'export PATH="\$HOME/.local/sparkle-tools:\$PATH"' >> ~/.zshrc
    source ~/.zshrc
EOF
