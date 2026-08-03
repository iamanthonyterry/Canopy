#!/bin/bash
set -euo pipefail

# Network Sync release script
# Usage: ./release.sh 0.0.17-alpha
# Github Release push: 
#  gh release create v0.0.17-alpha build/NetworkSync-0.0.17-alpha.zip build/appcast.xml --title "0.0.17-alpha" --notes "Seventeenth alpha release"
# Bumps MARKETING_VERSION, archives, exports, notarizes, staples, zips,
# and generates the Sparkle appcast — ready to upload to a GitHub Release.

# One-time setup before first use:
#   xcrun notarytool store-credentials AC_PASSWORD \
#     --apple-id you@example.com --team-id BPZ4H86MC6 --password <app-specific-password>

if [ $# -ne 1 ]; then
  echo "Usage: ./release.sh <marketing-version, e.g. 1.2>"
  exit 1
fi

VERSION="$1"
BUILD_NUMBER="$(date +%Y%m%d%H%M)"
SCHEME="Network Sync"
PBXPROJ="Network Sync.xcodeproj/project.pbxproj"
BUILD_DIR="build"
ARCHIVE_PATH="$BUILD_DIR/NetworkSync.xcarchive"
EXPORT_PATH="$BUILD_DIR/export"
APP_PATH="$EXPORT_PATH/Network Sync.app"
ZIP_PATH="$BUILD_DIR/NetworkSync-$VERSION.zip"
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

echo "==> Notarizing"
ditto -c -k --keepParent "$APP_PATH" "$BUILD_DIR/NetworkSync-notarize.zip"
xcrun notarytool submit "$BUILD_DIR/NetworkSync-notarize.zip" --keychain-profile "$KEYCHAIN_PROFILE" --wait

echo "==> Stapling notarization ticket"
xcrun stapler staple "$APP_PATH"

echo "==> Zipping stapled app for distribution"
rm -f "$BUILD_DIR/NetworkSync-notarize.zip"
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

echo "==> Generating signed Sparkle appcast"
"$SPARKLE_BIN/generate_appcast" "$BUILD_DIR"

echo ""
echo "Done. Upload these to a new GitHub Release (tag v$VERSION):"
echo "  - $ZIP_PATH"
echo "  - $BUILD_DIR/appcast.xml"
