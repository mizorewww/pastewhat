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
rm -rf "$APP_DIR/Contents/Resources/engine"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources/engine"
cp "$BIN_DIR/PasteWhat" "$APP_DIR/Contents/MacOS/PasteWhat"
cp "$PROJECT_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$PROJECT_DIR/engine/"*.py "$APP_DIR/Contents/Resources/engine/"
# Bundled so installed users can set up the Laya engine without cloning the repo.
cp "$PROJECT_DIR/scripts/setup-engine.sh" "$APP_DIR/Contents/Resources/setup-engine.sh"
chmod 755 "$APP_DIR/Contents/Resources/setup-engine.sh"
# The workspace key points engine auto-discovery at this checkout; it is only
# meaningful on the machine that built the app, so distribution builds omit it.
if [ "${PASTEWHAT_DIST:-0}" != "1" ]; then
    /usr/libexec/PlistBuddy -c "Add :PasteWhatWorkspace string \"$PROJECT_DIR\"" "$APP_DIR/Contents/Info.plist"
fi
identity="${PASTEWHAT_SIGNING_IDENTITY:-}"
if [ -z "$identity" ]; then
    developer_id="$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' | head -1)"
    if [ -n "$developer_id" ]; then
        identity="$developer_id"
    elif security find-identity -v -p codesigning 2>/dev/null | grep -q '"PasteWhat Development"'; then
        identity="PasteWhat Development"
    else
        identity="-"
        echo "Note: ad-hoc signing; macOS privacy grants (Accessibility, clipboard) reset on every rebuild." >&2
        echo "      Run scripts/create-signing-identity.sh once for a stable local signing identity." >&2
    fi
fi
# A stable identity keeps the designated requirement constant, so macOS privacy
# grants survive rebuilds; ad-hoc (-) changes the cdhash on every build.
if [ "$identity" = "-" ]; then
    codesign --force --options runtime --timestamp=none --sign "$identity" "$APP_DIR"
else
    if ! codesign --force --options runtime --sign "$identity" "$APP_DIR"; then
        echo "Secure timestamp unavailable; retrying without one (notarization needs the timestamp)." >&2
        codesign --force --options runtime --timestamp=none --sign "$identity" "$APP_DIR"
    fi
fi
codesign --verify --strict "$APP_DIR"
echo "Built: $APP_DIR"
echo "Run: open \"$APP_DIR\""
