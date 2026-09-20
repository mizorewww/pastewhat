#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
CONFIGURATION="${1:-release}"
if [[ "$CONFIGURATION" != "release" && "$CONFIGURATION" != "debug" ]]; then
    echo "Usage: ./scripts/build-app.sh [release|debug]" >&2
    exit 2
fi
swift build -c "$CONFIGURATION"
BIN_DIR="$(swift build -c "$CONFIGURATION" --show-bin-path)"
APP_DIR="$PROJECT_DIR/dist/PasteWhat.app"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources/engine"
cp "$BIN_DIR/PasteWhat" "$APP_DIR/Contents/MacOS/PasteWhat"
cp "$PROJECT_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$PROJECT_DIR/engine/"*.py "$APP_DIR/Contents/Resources/engine/"
/usr/libexec/PlistBuddy -c "Add :PasteWhatWorkspace string $PROJECT_DIR" "$APP_DIR/Contents/Info.plist"
codesign --force --sign "${PASTEWHAT_SIGNING_IDENTITY:--}" "$APP_DIR"
codesign --verify --strict "$APP_DIR"
echo "Built: $APP_DIR"
echo "Run: open \"$APP_DIR\""
