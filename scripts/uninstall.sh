#!/bin/bash
# Removes Pookify: strips its hooks from the Claude Code config (your
# *.bak-pookify backups are left untouched), quits the app, and deletes it from /Applications.
set -euo pipefail

APP_DST="/Applications/Pookify.app"
LOCAL_APP="$(cd "$(dirname "$0")/.." && pwd)/build/Pookify.app"

echo "▸ Removing hooks…"
if [[ -x "$APP_DST/Contents/MacOS/Pookify" ]]; then
  "$APP_DST/Contents/MacOS/Pookify" --uninstall || true
elif [[ -x "$LOCAL_APP/Contents/MacOS/Pookify" ]]; then
  "$LOCAL_APP/Contents/MacOS/Pookify" --uninstall || true
fi

echo "▸ Quitting app…"
pkill -x Pookify 2>/dev/null || true

echo "▸ Removing app…"
rm -rf "$APP_DST"

echo "✓ Uninstalled. Your config backups (*.bak-pookify) were left in place."
