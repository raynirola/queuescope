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

SOURCE_BRIDGE_DIR="$SRCROOT/packages/action-bridge"
BUILD_BRIDGE_DIR="$DERIVED_FILE_DIR/BullMQActionBridge"
BUNDLE_BRIDGE_DIR="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/BullMQActionBridge"

# Prepare outside the monorepo: npm must never hoist workspace or framework
# dependencies into the app. The app's runtime resource path stays unchanged.
/bin/bash "$SRCROOT/scripts/prepare-bridge.sh" "$SOURCE_BRIDGE_DIR" "$BUILD_BRIDGE_DIR"
rm -rf "$BUNDLE_BRIDGE_DIR"
mkdir -p "$BUNDLE_BRIDGE_DIR"
cp -R "$BUILD_BRIDGE_DIR/." "$BUNDLE_BRIDGE_DIR/"

/bin/bash "$SRCROOT/scripts/package-node.sh"
