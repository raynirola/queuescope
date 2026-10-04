#!/bin/bash
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "usage: prepare-bridge.sh SOURCE_BRIDGE_DIR OUTPUT_BRIDGE_DIR" >&2
  exit 1
fi
SOURCE_BRIDGE_DIR="$1"
OUTPUT_BRIDGE_DIR="$2"

# Deliberately ignore TMPDIR: Xcode/CI may point it inside the workspace. A
# fresh system-temp package prevents npm from reading the workspace lock or
# linking sibling packages, even when derived data lives in the repository.
STAGING_DIR="$(mktemp -d /tmp/queuescope-action-bridge.XXXXXX)"
trap 'rm -rf "$STAGING_DIR"' EXIT
cp "$SOURCE_BRIDGE_DIR/bridge.mjs" "$STAGING_DIR/bridge.mjs"
cp "$SOURCE_BRIDGE_DIR/package.json" "$STAGING_DIR/package.json"
cp "$SOURCE_BRIDGE_DIR/package-lock.json" "$STAGING_DIR/package-lock.json"

# BullMQ works with msgpackr's pure-JS fallback. Excluding optional native
# accelerators keeps the bridge architecture-neutral and avoids unsigned .node
# binaries inside a universal notarized app. No dependency install scripts run.
(
  cd "$STAGING_DIR"
  npm ci --omit=dev --omit=optional --ignore-scripts --workspaces=false
)

rm -rf "$OUTPUT_BRIDGE_DIR"
mkdir -p "$OUTPUT_BRIDGE_DIR"
cp -R "$STAGING_DIR/." "$OUTPUT_BRIDGE_DIR/"
