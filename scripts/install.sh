#!/bin/bash
#
# install.sh — build NetWatch in release mode, repack the .app bundle,
# ad-hoc codesign, and install into /Applications.
#
# Usage:
#   ./scripts/install.sh
#
# Re-run any time after editing Sources/. Idempotent — replaces existing
# /Applications/NetWatch.app.

set -euo pipefail

cd "$(dirname "$0")/.."
REPO_ROOT="$(pwd)"

echo "==> Building release binary..."
swift build -c release

echo "==> Repacking .app bundle..."
mkdir -p build/NetWatch.app/Contents/MacOS
cp -f .build/release/NetWatch build/NetWatch.app/Contents/MacOS/NetWatch
chmod +x build/NetWatch.app/Contents/MacOS/NetWatch

# Info.plist is checked in to git, so it stays put. We only refresh the binary.
if [ ! -f build/NetWatch.app/Contents/Info.plist ]; then
    echo "ERROR: Info.plist missing from build/NetWatch.app/Contents/" >&2
    exit 1
fi

echo "==> Ad-hoc codesigning..."
codesign --force --deep --sign - build/NetWatch.app

echo "==> Stopping any running NetWatch instances..."
pkill -TERM NetWatch 2>/dev/null || true
sleep 1

echo "==> Installing to /Applications/NetWatch.app..."
rm -rf /Applications/NetWatch.app
cp -R build/NetWatch.app /Applications/

echo "==> Launching..."
open /Applications/NetWatch.app

echo ""
echo "✓ Installed. Look for the network icon in your menubar."
echo ""
echo "Tip: System Settings → General → Login Items → '+' → NetWatch.app"
echo "     to auto-start on boot."
