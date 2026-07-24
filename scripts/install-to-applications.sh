#!/bin/zsh
set -euo pipefail

# Install the Release Looper.app into /Applications (what Finder "Open With" uses).
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${1:-$ROOT/build/DerivedData/Build/Products/Release/Looper.app}"
DEST="/Applications/Looper.app"

if [[ ! -d "$SRC" ]]; then
  echo "Missing build: $SRC" >&2
  echo "Build Release first, then re-run." >&2
  exit 1
fi

pkill -x Looper 2>/dev/null || true
rm -rf "$DEST"
cp -R "$SRC" "$DEST"
if [[ -f "$ROOT/Looper.icns" ]]; then
  cp "$ROOT/Looper.icns" "$DEST/Contents/Resources/AppIcon.icns"
fi
codesign --force --deep --sign - "$DEST" >/dev/null
# Strip Gatekeeper quarantine so Open With / double-click isn't blocked.
xattr -cr "$DEST" 2>/dev/null || true
/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister -f "$DEST" >/dev/null
echo "Installed $DEST"
