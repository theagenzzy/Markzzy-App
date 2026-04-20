#!/usr/bin/env bash
# hot-reload.sh — rebuild Markzzy.app + relaunch when a Sources/**.swift file changes.
# Invoked as a Claude Code PostToolUse hook; reads tool_input JSON from stdin.
set -u

INPUT=$(cat)
FILE=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty')

case "$FILE" in
  /Users/crisodevelop/Desktop/markzzy/Sources/*.swift) ;;
  *) exit 0 ;;
esac

LOG=/tmp/markzzy-hot-reload.log
{
  echo "=== $(date) rebuild triggered by $FILE ==="
  pkill -f "Markzzy.app/Contents/MacOS/Markzzy" 2>/dev/null || true
  bash /Users/crisodevelop/Desktop/markzzy/scripts/install-to-desktop.sh && \
    open /Users/crisodevelop/Desktop/Markzzy.app
} >>"$LOG" 2>&1 &
disown
exit 0
