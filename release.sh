#!/bin/bash
set -euo pipefail

# Canopy release script
# Usage: ./release.sh 0.0.40-alpha
# Github Release push:
#  gh release create v0.0.40-alpha build/Canopy-0.0.40-alpha.zip build/appcast.xml --title "0.0.40-alpha" --notes "Fortieth alpha release"
# Bumps MARKETING_VERSION, archives, exports, embeds the Transcriber helper,
# notarizes, staples, zips, and generates the Sparkle appcast — ready to upload
# to a GitHub Release.
#
# The helper is built from ../transcriber (override with TRANSCRIBER_DIR) and
# goes in Canopy.app/Contents/Library/LoginItems, so one download holds both apps.
# STOP_BEFORE_NOTARIZE=1 builds and signs everything but doesn't submit it, for checking the bundle.

# One-time setup before first use:
#   xcrun notarytool store-credentials AC_PASSWORD \
#     --apple-id you@example.com --team-id GAYT638PXY --password <app-specific-password>

if [ $# -ne 1 ]; then
  echo "Usage: ./release.sh <marketing-version, e.g. 1.2>"
  exit 1
fi

VERSION="$1"
BUILD_NUMBER="$(date +%Y%m%d%H%M)"
SCHEME="Canopy"
PBXPROJ="Canopy.xcodeproj/project.pbxproj"
BUILD_DIR="build"
ARCHIVE_PATH="$BUILD_DIR/Canopy.xcarchive"
EXPORT_PATH="$BUILD_DIR/export"
APP_PATH="$EXPORT_PATH/Canopy.app"
ZIP_PATH="$BUILD_DIR/Canopy-$VERSION.zip"
KEYCHAIN_PROFILE="AC_PASSWORD"
SPARKLE_BIN="$(find ~/Library/Developer/Xcode/DerivedData -path '*artifacts/sparkle/Sparkle/bin' -maxdepth 6 2>/dev/null | head -n 1)"

if [ -z "$SPARKLE_BIN" ]; then
  echo "Could not find Sparkle's generate_appcast tool. Build the project at least once after adding the Sparkle package, then re-run this script."
  exit 1
fi

echo "==> Cleaning previous build output"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

echo "==> Bumping version to $VERSION ($BUILD_NUMBER)"
sed -i '' "s/MARKETING_VERSION = [^;]*;/MARKETING_VERSION = $VERSION;/g" "$PBXPROJ"
sed -i '' "s/CURRENT_PROJECT_VERSION = [^;]*;/CURRENT_PROJECT_VERSION = $BUILD_NUMBER;/g" "$PBXPROJ"

echo "==> Archiving"
xcodebuild archive \
  -scheme "$SCHEME" \
  -archivePath "$ARCHIVE_PATH" \
  -configuration Release \
  -destination "generic/platform=macOS" \
  -skipMacroValidation \
  DEVELOPMENT_TEAM=GAYT638PXY \
  CODE_SIGN_IDENTITY="Developer ID Application" \
  CODE_SIGN_STYLE=Manual \
  -allowProvisioningUpdates

echo "==> Exporting (Developer ID)"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_PATH" \
  -exportOptionsPlist exportOptions.plist \
  -allowProvisioningUpdates

echo "==> Building and embedding Transcriber"
TRANSCRIBER_DIR="${TRANSCRIBER_DIR:-../transcriber}"
SIGN_IDENTITY="${SIGN_IDENTITY:-CD882049F8DD5836221DBE167F30CAE12EBB5694}"  # Developer ID Application: Roses as Humans LLC (two certs share the name, so use the hash)
HELPER_DIR="$APP_PATH/Contents/Library/LoginItems"
(cd "$TRANSCRIBER_DIR" && SIGN_IDENTITY="$SIGN_IDENTITY" ./build_app.sh)
rm -rf "$HELPER_DIR/Transcriber.app"
mkdir -p "$HELPER_DIR"
ditto "$TRANSCRIBER_DIR/build/Transcriber.app" "$HELPER_DIR/Transcriber.app"
codesign --verify --deep --strict "$HELPER_DIR/Transcriber.app"

# Adding the helper broke Canopy's seal, so sign Canopy again with the entitlements the export gave it.
# The helper keeps its own signature (no --deep).
codesign -d --entitlements :- "$APP_PATH" > "$BUILD_DIR/canopy.entitlements" 2>/dev/null
codesign -f -s "$SIGN_IDENTITY" -o runtime --timestamp --entitlements "$BUILD_DIR/canopy.entitlements" "$APP_PATH"
codesign --verify --deep --strict "$APP_PATH"

if [ "${STOP_BEFORE_NOTARIZE:-}" = "1" ]; then
  echo "Stopped before notarizing: $APP_PATH"
  exit 0
fi

echo "==> Notarizing"
ditto -c -k --keepParent "$APP_PATH" "$BUILD_DIR/Canopy-notarize.zip"
xcrun notarytool submit "$BUILD_DIR/Canopy-notarize.zip" --keychain-profile "$KEYCHAIN_PROFILE" --wait

echo "==> Stapling notarization ticket"
xcrun stapler staple "$APP_PATH"

echo "==> Zipping stapled app for distribution"
rm -f "$BUILD_DIR/Canopy-notarize.zip"
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

echo "==> Generating signed Sparkle appcast"
"$SPARKLE_BIN/generate_appcast" "$BUILD_DIR"

echo ""
echo "Done. Upload these to a new GitHub Release (tag v$VERSION):"
echo "  - $ZIP_PATH"
echo "  - $BUILD_DIR/appcast.xml"
