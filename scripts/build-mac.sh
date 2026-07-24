#!/bin/bash
# Looper release build — Xcode + shared RazorBackRoar DMG contract.
# Artifacts: build/Release/Looper.dmg only (no .app left in the repo).
# Always installs one copy to /Applications/Looper.app.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR/.."
APP_NAME="Looper"
SCHEME="Looper"
PROJECT="$PROJECT_DIR/Looper.xcodeproj"

RELEASE_DIR="$PROJECT_DIR/build/Release"
DERIVED="$PROJECT_DIR/build/DerivedData"
APP_BUILD="$DERIVED/Build/Products/Release/Looper.app"
APP_PATH="$RELEASE_DIR/Looper.app"
DMG_PATH="$RELEASE_DIR/Looper.dmg"
RAZORCORE_DIR="$(cd "$SCRIPT_DIR/../../.razorcore" && pwd)"

# Prevent stale artifacts from previous builds.
rm -rf "$RELEASE_DIR"/*.app "$RELEASE_DIR"/*.dmg "$PROJECT_DIR/Looper.app"

SIGN_IDENTITY="${LOOPER_SIGN_IDENTITY:-}"

VERSION="$(
  /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
    "$PROJECT_DIR/Looper/Info.plist" 2>/dev/null || echo "1.0"
)"

echo "Building $APP_NAME release..."
cd "$PROJECT_DIR"

ICON_PYTHON="${LOOPER_ICON_PYTHON:-$HOME/.local/bin/python3.14}"
"$ICON_PYTHON" "$SCRIPT_DIR/generate-icon.py"

rm -rf "$DERIVED"
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -derivedDataPath "$DERIVED" \
  -arch arm64 \
  ONLY_ACTIVE_ARCH=NO \
  build

mkdir -p "$RELEASE_DIR"
rm -rf "$APP_PATH"
cp -R "$APP_BUILD" "$APP_PATH"

if [[ -f "$PROJECT_DIR/Looper.icns" ]]; then
  cp "$PROJECT_DIR/Looper.icns" "$APP_PATH/Contents/Resources/AppIcon.icns"
fi

"$RAZORCORE_DIR/patch-app-branding.sh" "$APP_PATH"

if [[ -n "$SIGN_IDENTITY" ]]; then
  echo "Signing $APP_NAME.app with Developer ID ($SIGN_IDENTITY)..."
  codesign --force --deep --options runtime --sign "$SIGN_IDENTITY" "$APP_PATH"
  codesign --verify --verbose=2 "$APP_PATH"
else
  echo "Ad-hoc signing $APP_NAME.app (set LOOPER_SIGN_IDENTITY for Developer ID)..."
  codesign --force --deep --sign - "$APP_PATH"
fi

"$SCRIPT_DIR/install-to-applications.sh" "$APP_PATH"

VOLUME_NAME="$APP_NAME $VERSION"
"$RAZORCORE_DIR/package-dmg.sh" \
  --app "$APP_PATH" \
  --dmg "$DMG_PATH" \
  --app-name "$APP_NAME" \
  --volname "$VOLUME_NAME"

if [[ -n "$SIGN_IDENTITY" ]]; then
  codesign --force --sign "$SIGN_IDENTITY" "$DMG_PATH"
fi

rm -rf "$APP_PATH"
rm -rf "$DERIVED"
echo "Build complete: $DMG_PATH"
echo "Installed /Applications/Looper.app"
