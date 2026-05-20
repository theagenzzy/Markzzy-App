#!/usr/bin/env bash
# self-test.sh
# End-to-end recording self-test. Builds + signs Markzzy, then launches
# it with --self-test which runs a programmatic 3-second recording and
# verifies the produced MP4 is valid.
#
# Contract: PASS = manual recording works. FAIL = manual recording will
# fail the same way; the message says exactly which component broke.
set -euo pipefail

PROJECT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$HOME/Desktop/Markzzy.app"
RESULT_FILE="/tmp/markzzy-selftest-result.txt"

echo "==> Building + signing Markzzy…"
"$PROJECT/scripts/install-to-desktop.sh" >/tmp/markzzy-build.log 2>&1 || {
    echo "❌ Build failed. Check /tmp/markzzy-build.log"
    tail -30 /tmp/markzzy-build.log
    exit 1
}

[ -d "$APP" ] || { echo "❌ Markzzy.app missing at $APP"; exit 1; }
rm -f "$RESULT_FILE"

echo "==> Running self-test (3s recording with real screen + camera)…"
echo ""
open -W -a "$APP" --args --self-test || true
echo ""
echo "==> Result"
echo ""

if [ -f "$RESULT_FILE" ]; then
    RESULT="$(head -1 "$RESULT_FILE")"
    if [[ "$RESULT" == PASS:* ]]; then
        echo "✅ $RESULT"
        if grep -q "^FILE:" "$RESULT_FILE"; then
            echo "   $(grep '^FILE:' "$RESULT_FILE")"
        fi
        exit 0
    else
        echo "❌ $RESULT"
        exit 1
    fi
fi

echo "❌ self-test produced no result file"
exit 1
