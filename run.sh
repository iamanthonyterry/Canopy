#!/bin/bash
set -euo pipefail

# Build Canopy from the command line (no Xcode GUI) and launch it.
# Usage: ./run.sh          build (incremental) and open the app
#        ./run.sh --clean  wipe the dev build first
# The result is an ad-hoc signed Debug build in build/dev, separate from release.sh output.

cd "$(dirname "$0")"

DERIVED="build/dev"
APP="$DERIVED/Build/Products/Debug/Canopy.app"

if [ "${1:-}" = "--clean" ]; then
  rm -rf "$DERIVED"
fi

xcodebuild build \
  -scheme Canopy \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED" \
  -skipMacroValidation \
  CODE_SIGN_IDENTITY=- \
  CODE_SIGN_STYLE=Manual \
  DEVELOPMENT_TEAM= \
  -quiet

# Quit any running copy so the new build is the one you see.
pkill -x Canopy 2>/dev/null || true

open "$APP"
echo "Launched $APP"
