set -euo pipefail

# Official, standalone Node binaries; pin both the version and archive digests.
NODE_VERSION=22.23.3
NODE_CACHE="$DERIVED_FILE_DIR/QueueScopeNode-$NODE_VERSION"
NODE_DEST="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Helpers"
mkdir -p "$NODE_CACHE" "$NODE_DEST"
NODE_INPUTS=()
for BUILD_ARCH in $ARCHS; do
  case "$BUILD_ARCH" in
    arm64) NODE_ARCH=arm64; NODE_SHA=23b25245dcfb9af7262f8ff142e9e2e0af025368117329e7a7458a51e5922f53 ;;
    x86_64) NODE_ARCH=x64; NODE_SHA=8a677b0219178efd6eb0e475457c4afb452b521a92f6e67845a73bd85727f2a8 ;;
    *) echo "error: Unsupported Node architecture: $BUILD_ARCH" >&2; exit 1 ;;
  esac
  NODE_NAME="node-v$NODE_VERSION-darwin-$NODE_ARCH"
  NODE_ARCHIVE="$NODE_CACHE/$NODE_NAME.tar.gz"
  if [ ! -f "$NODE_ARCHIVE" ]; then
    curl --fail --location --retry 3 "https://nodejs.org/dist/v$NODE_VERSION/$NODE_NAME.tar.gz" --output "$NODE_ARCHIVE.download"
    mv "$NODE_ARCHIVE.download" "$NODE_ARCHIVE"
  fi
  echo "$NODE_SHA  $NODE_ARCHIVE" | shasum -a 256 --check --status
  tar -xzf "$NODE_ARCHIVE" -C "$NODE_CACHE" "$NODE_NAME/bin/node" "$NODE_NAME/LICENSE"
  NODE_INPUTS+=("$NODE_CACHE/$NODE_NAME/bin/node")
done
if [ "${#NODE_INPUTS[@]}" -gt 1 ]; then
  lipo -create "${NODE_INPUTS[@]}" -output "$NODE_DEST/node"
else
  cp "${NODE_INPUTS[0]}" "$NODE_DEST/node"
fi
cp "$NODE_CACHE/$NODE_NAME/LICENSE" "$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/Node-LICENSE.txt"
SIGNING_IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:--}"
if [ -z "$SIGNING_IDENTITY" ]; then SIGNING_IDENTITY=-; fi
if [ "$SIGNING_IDENTITY" != "-" ]; then
  codesign --force --sign "$SIGNING_IDENTITY" --timestamp --options runtime --entitlements "$SRCROOT/scripts/node-entitlements.plist" "$NODE_DEST/node"
else
  codesign --force --sign - --entitlements "$SRCROOT/scripts/node-entitlements.plist" "$NODE_DEST/node"
fi
