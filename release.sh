#!/bin/bash
set -euo pipefail

# Canopy release script
# Usage: ./release.sh 0.0.40-alpha
# Github Release push:
#  gh release create v0.0.40-alpha build/Canopy-0.0.40-alpha.zip build/appcast.xml --title "0.0.40-alpha" --notes "Fortieth alpha release"
# Bumps MARKETING_VERSION, archives, exports, notarizes, staples, zips, and
# generates the Sparkle appcasts — ready to upload to GitHub Releases.
#
# Canopy is one app now (it took over Transcriber's bundle id and update feed), so
# there is nothing to embed. Two appcasts come out, for the same zip:
#   build/appcast-transcriber/  for iamanthonyterry/transcriber, the feed every installed copy now follows
#   build/appcast-Canopy/       for iamanthonyterry/Canopy, the feed the old separate Canopy still follows,
#                               so those installs update straight into this app (the zip holds Canopy.app)
# Publish the first for every release. Publish the second once, for the release that retires the old Canopy.
# CURRENT_PROJECT_VERSION is the date, so it is always newer than any earlier Transcriber or Canopy build.
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

# Planning Center OAuth credentials (what Transcriber's build_app.sh did): without them the Planning Center
# schedule would silently stop working for everyone who updates. The file isn't committed.
PCO_ENV="${PCO_ENV:-../transcriber/Support/pco.env}"
PCO_ARGS=()
if [ -f "$PCO_ENV" ]; then
  set -a; . "$PCO_ENV"; set +a
  PCO_ARGS=("PCO_CLIENT_ID=${PCO_CLIENT_ID:-}" "PCO_CLIENT_SECRET=${PCO_CLIENT_SECRET:-}")
else
  echo "warning: $PCO_ENV not found, so this build has no Planning Center credentials" >&2
fi

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
  ${PCO_ARGS[@]+"${PCO_ARGS[@]}"} \
  -allowProvisioningUpdates

echo "==> Exporting (Developer ID)"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_PATH" \
  -exportOptionsPlist exportOptions.plist \
  -allowProvisioningUpdates

SIGN_IDENTITY="${SIGN_IDENTITY:-CD882049F8DD5836221DBE167F30CAE12EBB5694}"  # Developer ID Application: Roses as Humans LLC (two certs share the name, so use the hash)
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

echo "==> Generating signed Sparkle appcasts"
for REPO_NAME in transcriber Canopy; do
  DIR="$BUILD_DIR/appcast-$REPO_NAME"
  rm -rf "$DIR"; mkdir -p "$DIR"
  cp "$ZIP_PATH" "$DIR/"
  "$SPARKLE_BIN/generate_appcast" --download-url-prefix "https://github.com/iamanthonyterry/$REPO_NAME/releases/download/v$VERSION/" "$DIR"
done

echo ""
echo "Done. Create the GitHub release (tag v$VERSION) in each repo you are updating:"
echo "  gh release create v$VERSION $ZIP_PATH $BUILD_DIR/appcast-transcriber/appcast.xml --repo iamanthonyterry/transcriber --title \"$VERSION\""
echo "  gh release create v$VERSION $ZIP_PATH $BUILD_DIR/appcast-Canopy/appcast.xml --repo iamanthonyterry/Canopy --title \"$VERSION\"   # once, to move old Canopy installs over"
