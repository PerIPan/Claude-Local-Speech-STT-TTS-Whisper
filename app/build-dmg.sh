#!/bin/bash
# Build Open Whisperer .app bundle and package as .dmg
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$SCRIPT_DIR/.build"
APP_NAME="OpenWhisperer"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
DMG_NAME="OpenWhisperer-1.3.2"

echo "=== Building Open Whisperer ==="

# Step 1: Build Swift binary
echo "Compiling Swift..."
cd "$SCRIPT_DIR"
swift build -c release 2>&1

BINARY="$SCRIPT_DIR/.build/release/OpenWhisperer"
if [ ! -f "$BINARY" ]; then
    echo "Error: Build failed — binary not found"
    exit 1
fi

# Step 2: Create .app bundle structure
echo "Creating app bundle..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources/hooks"
mkdir -p "$APP_BUNDLE/Contents/Resources/servers"
mkdir -p "$APP_BUNDLE/Contents/Resources/scripts"

# Copy binary
cp "$BINARY" "$APP_BUNDLE/Contents/MacOS/OpenWhisperer"

# Copy Info.plist, icon, and fonts
cp "$SCRIPT_DIR/Resources/Info.plist" "$APP_BUNDLE/Contents/"
cp "$SCRIPT_DIR/Resources/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/"
cp "$SCRIPT_DIR/Resources/Outfit-VariableFont_wght.ttf" "$APP_BUNDLE/Contents/Resources/" 2>/dev/null || true

# Step 3: Bundle project scripts
cp "$PROJECT_DIR/hooks/tts-hook.sh" "$APP_BUNDLE/Contents/Resources/hooks/"
cp "$PROJECT_DIR/hooks/codex-tts-hook.sh" "$APP_BUNDLE/Contents/Resources/hooks/"
cp "$PROJECT_DIR/servers/unified_server.py" "$APP_BUNDLE/Contents/Resources/servers/"
cp "$PROJECT_DIR/scripts/speak.sh" "$APP_BUNDLE/Contents/Resources/scripts/"

# Make scripts executable
chmod +x "$APP_BUNDLE/Contents/Resources/hooks/tts-hook.sh"
chmod +x "$APP_BUNDLE/Contents/Resources/hooks/codex-tts-hook.sh"
chmod +x "$APP_BUNDLE/Contents/Resources/scripts/speak.sh"

# Step 4: Bundle uv binary (detect architecture)
echo "Bundling uv..."
ARCH=$(uname -m)
UV_PATH=$(which uv 2>/dev/null || echo "")
if [ -n "$UV_PATH" ]; then
    # Verify local uv matches build architecture
    UV_ARCH=$(file "$UV_PATH" | grep -o 'arm64\|x86_64' | head -1)
    if [ "$ARCH" = "arm64" ] && [ "$UV_ARCH" = "arm64" ]; then
        cp "$UV_PATH" "$APP_BUNDLE/Contents/Resources/uv"
    elif [ "$ARCH" = "x86_64" ] && [ "$UV_ARCH" = "x86_64" ]; then
        cp "$UV_PATH" "$APP_BUNDLE/Contents/Resources/uv"
    else
        echo "Local uv ($UV_ARCH) doesn't match build arch ($ARCH) — downloading..."
        UV_PATH=""
    fi
fi
if [ -z "$UV_PATH" ]; then
    if [ "$ARCH" = "arm64" ]; then
        UV_URL="https://github.com/astral-sh/uv/releases/latest/download/uv-aarch64-apple-darwin.tar.gz"
    else
        UV_URL="https://github.com/astral-sh/uv/releases/latest/download/uv-x86_64-apple-darwin.tar.gz"
    fi
    echo "Downloading uv for $ARCH..."
    UV_TMP=$(mktemp -d)
    curl -LsS "$UV_URL" -o "$UV_TMP/uv.tar.gz"
    tar xzf "$UV_TMP/uv.tar.gz" -C "$UV_TMP"
    UV_EXTRACTED=$(find "$UV_TMP" -name "uv" -type f | head -1)
    if [ -z "$UV_EXTRACTED" ]; then
        echo "Error: Could not extract uv binary"
        exit 1
    fi
    cp "$UV_EXTRACTED" "$APP_BUNDLE/Contents/Resources/uv"
    rm -rf "$UV_TMP"
fi
chmod +x "$APP_BUNDLE/Contents/Resources/uv"

# Step 5: Bundle jq binary (detect architecture)
echo "Bundling jq..."
JQ_PATH=$(which jq 2>/dev/null || echo "")
if [ -z "$JQ_PATH" ]; then
    if [ "$ARCH" = "arm64" ]; then
        JQ_URL="https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-macos-arm64"
    else
        JQ_URL="https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-macos-amd64"
    fi
    echo "Downloading jq for $ARCH..."
    curl -LsS "$JQ_URL" -o "$APP_BUNDLE/Contents/Resources/jq"
else
    cp "$JQ_PATH" "$APP_BUNDLE/Contents/Resources/jq"
fi
chmod +x "$APP_BUNDLE/Contents/Resources/jq"

# Step 6: Ad-hoc code sign
echo "Code signing..."
codesign --force --deep --sign - "$APP_BUNDLE"

echo ""
echo "App bundle created: $APP_BUNDLE"

# Step 7: Create DMG
echo "Creating DMG..."
DMG_TMP="$BUILD_DIR/dmg-staging"
DMG_OUTPUT="$BUILD_DIR/$DMG_NAME.dmg"
rm -rf "$DMG_TMP" "$DMG_OUTPUT"
mkdir -p "$DMG_TMP"

cp -R "$APP_BUNDLE" "$DMG_TMP/"

# Add Applications symlink for drag-to-install
ln -s /Applications "$DMG_TMP/Applications"

hdiutil create -volname "$APP_NAME" \
    -srcfolder "$DMG_TMP" \
    -ov -format UDZO \
    "$DMG_OUTPUT"

rm -rf "$DMG_TMP"

echo ""
echo "=== Done ==="
echo "DMG: $DMG_OUTPUT"
echo "App: $APP_BUNDLE"
echo ""
echo "To install: open the DMG and drag OpenWhisperer to Applications"
