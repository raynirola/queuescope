set -euo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
if ! command -v npm >/dev/null 2>&1; then
  for npm_candidate in "$HOME"/.nvm/versions/node/*/bin/npm; do
    if [ -x "$npm_candidate" ]; then
      export PATH="$(dirname "$npm_candidate"):$PATH"
      break
    fi
  done
fi
if ! command -v npm >/dev/null 2>&1; then
  echo "error: npm is required to package the BullMQ action bridge. Install Node.js/npm or make npm available via Homebrew, /usr/local/bin, or nvm." >&2
  exit 1
fi

SOURCE_BRIDGE_DIR="$SRCROOT/BullMQActionBridge"
BUILD_BRIDGE_DIR="$DERIVED_FILE_DIR/BullMQActionBridge"
BUNDLE_BRIDGE_DIR="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/BullMQActionBridge"

rm -rf "$BUILD_BRIDGE_DIR" "$BUNDLE_BRIDGE_DIR"
mkdir -p "$BUILD_BRIDGE_DIR" "$BUNDLE_BRIDGE_DIR"

cp "$SOURCE_BRIDGE_DIR/bridge.mjs" "$BUILD_BRIDGE_DIR/bridge.mjs"
cp "$SOURCE_BRIDGE_DIR/package.json" "$BUILD_BRIDGE_DIR/package.json"
cp "$SOURCE_BRIDGE_DIR/package-lock.json" "$BUILD_BRIDGE_DIR/package-lock.json"

npm ci --omit=dev --prefix "$BUILD_BRIDGE_DIR"

cp -R "$BUILD_BRIDGE_DIR/." "$BUNDLE_BRIDGE_DIR/"

/bin/bash "$SRCROOT/scripts/package-node.sh"
