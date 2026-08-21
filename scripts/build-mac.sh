#!/bin/bash
# Looper release build — Xcode + shared RazorBackRoar DMG contract.
# Artifacts: build/Release/Looper.dmg only (no .app left in the repo).
# Leaves ~/Desktop/Looper.dmg mounted for the user; never installs to /Applications.
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

echo "Building $APP_NAME release..."
cd "$PROJECT_DIR"

ICON_PYTHON="${LOOPER_ICON_PYTHON:-}"
if [[ -z "$ICON_PYTHON" ]] && command -v uv >/dev/null 2>&1; then
  echo "Generating Looper.icns with uv + Pillow..."
  uv run --with pillow python "$SCRIPT_DIR/generate-icon.py"
elif [[ -n "$ICON_PYTHON" ]]; then
  "$ICON_PYTHON" "$SCRIPT_DIR/generate-icon.py"
elif [[ -f "$PROJECT_DIR/Looper.icns" ]]; then
  echo "Pillow not found; using existing Looper.icns"
else
  echo "Need Pillow (or LOOPER_ICON_PYTHON) to generate Looper.icns" >&2
  exit 1
fi

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

VOLUME_NAME="$APP_NAME"
"$RAZORCORE_DIR/package-dmg.sh" \
  --app "$APP_PATH" \
  --dmg "$DMG_PATH" \
  --app-name "$APP_NAME" \
  --volname "$VOLUME_NAME"

if [[ -n "$SIGN_IDENTITY" ]]; then
  codesign --force --sign "$SIGN_IDENTITY" "$DMG_PATH"
fi

# Replace the Desktop DMG copy so the latest release is always one double-click away.
rm -f "$HOME/Desktop/$APP_NAME.dmg"
cp -f "$DMG_PATH" "$HOME/Desktop/$APP_NAME.dmg"
echo "✓ Desktop handoff: $HOME/Desktop/$APP_NAME.dmg"

# Mount the DMG on the Desktop so the user can drag the new .app to /Applications.
echo "Mounting Desktop DMG..."
if ! hdiutil attach "$HOME/Desktop/$APP_NAME.dmg"; then
  echo "Warning: $HOME/Desktop/$APP_NAME.dmg may already be mounted; continuing." >&2
fi

# Back up the currently installed app before the user replaces it.
if [[ -d "/Applications/$APP_NAME.app" ]]; then
  BACKUP_ZIP="$HOME/Desktop/$APP_NAME backup.zip"
  rm -f "$BACKUP_ZIP"
  echo "Backing up /Applications/$APP_NAME.app to $BACKUP_ZIP"
  zip -r -y -q "$BACKUP_ZIP" "/Applications/$APP_NAME.app"
fi

rm -rf "$APP_PATH"
rm -rf "$DERIVED"
echo "Build complete: $DMG_PATH"
