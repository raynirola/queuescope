#!/bin/bash
set -euo pipefail
umask 077

: "${RELEASE_VERSION:?}" "${RELEASE_COMMIT:?}" "${GH_TOKEN:?}"
REPO=raynirola/queuescope
TAG="v$RELEASE_VERSION"
ZIP="QueueScope-$RELEASE_VERSION-macOS.zip"
DIR="$(pwd)/release-output"
WORK="$(mktemp -d "${RUNNER_TEMP:-/tmp}/queuescope-publish.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
bash scripts/release/check-release-order.sh
python3 scripts/release/metadata.py validate --version "$RELEASE_VERSION" --commit "$RELEASE_COMMIT" --output "$WORK/metadata"
python3 scripts/release/metadata.py finalize --directory "$DIR" --version "$RELEASE_VERSION" --commit "$RELEASE_COMMIT"
swift scripts/release/verify-sparkle.swift BullMQDashboard/Info.plist "$DIR/$ZIP" "$DIR/appcast.xml" "$RELEASE_VERSION"
SHA="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["sha256"])' "$DIR/manifest.json")"
(cd "$DIR" && shasum -a 256 -c SHA256SUMS)
ditto -x -k "$DIR/$ZIP" "$WORK/extracted"
APP="$WORK/extracted/QueueScope.app"
codesign --verify --deep --strict --verbose=2 "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=4 "$APP"

fetch_public() {
  curl --fail --location --retry 6 --retry-all-errors --retry-delay 2 \
    --max-time 180 --proto '=https' --tlsv1.2 "$1" --output "$2"
}
verify_download() {
  fetch_public "$1" "$WORK/download.zip"
  test "$(shasum -a 256 "$WORK/download.zip" | awk '{print $1}')" = "$SHA" || {
    echo '::error::Published ZIP checksum differs from verified artifact'; exit 1;
  }
}

# Fail on observed external feed changes. GitHub has no atomic asset replacement;
# the release environment must be the exclusive writer of this appcast.
gh api "repos/$REPO/releases/tags/appcast" > "$WORK/appcast-release.json"
test "$(jq -r .draft "$WORK/appcast-release.json")" = false
fetch_public "https://github.com/$REPO/releases/download/appcast/appcast.xml" "$WORK/previous-appcast.xml"
BASE_SHA="$(cat "$DIR/appcast-base.sha256")"
LIVE_SHA="$(shasum -a 256 "$WORK/previous-appcast.xml" | awk '{print $1}')"
NEXT_SHA="$(shasum -a 256 "$DIR/appcast.xml" | awk '{print $1}')"
if [ "$LIVE_SHA" != "$BASE_SHA" ] && [ "$LIVE_SHA" != "$NEXT_SHA" ]; then
  echo '::error::The live Sparkle feed changed after this package was built. Rebuild from the current feed.'
  exit 1
fi
python3 - "$WORK/previous-appcast.xml" "$RELEASE_VERSION" <<'PY'
import re, sys, xml.etree.ElementTree as ET
version=tuple(map(int, sys.argv[2].split('.')))
for el in ET.parse(sys.argv[1]).iter('{http://www.andymatuschak.org/xml-namespaces/sparkle}shortVersionString'):
    if el.text and re.fullmatch(r'\d+\.\d+\.\d+', el.text) and tuple(map(int,el.text.split('.'))) > version:
        raise SystemExit('Refusing to replace a newer Sparkle release')
PY

# Release reruns may finish a matching draft or verify matching public assets.
if gh api "repos/$REPO/releases/tags/$TAG" > "$WORK/version-release.json" 2> "$WORK/release-error"; then
  echo "Resuming existing $TAG release"
else
  grep -q 'HTTP 404' "$WORK/release-error" || { cat "$WORK/release-error" >&2; exit 1; }
  gh release create "$TAG" --repo "$REPO" --target "$RELEASE_COMMIT" --draft \
    --title "QueueScope $RELEASE_VERSION" --notes-file "$DIR/release-notes.md"
fi

ensure_asset() {
  local tag="$1" file="$2" name
  name="$(basename "$file")"
  if gh api "repos/$REPO/releases/tags/$tag" --jq '.assets[].name' | grep -Fxq "$name"; then
    mkdir -p "$WORK/existing/$tag"
    gh release download "$tag" --repo "$REPO" --pattern "$name" --dir "$WORK/existing/$tag" --clobber
    cmp "$file" "$WORK/existing/$tag/$name" || { echo "::error::Existing $tag/$name differs; refusing to overwrite"; exit 1; }
  else
    gh release upload "$tag" "$file" --repo "$REPO"
  fi
}
# Reject a pre-existing tag aimed at any other commit before making a draft public.
if gh api "repos/$REPO/git/ref/tags/$TAG" > "$WORK/tag.json" 2> "$WORK/tag-error"; then
  TAG_TYPE="$(jq -r .object.type "$WORK/tag.json")"
  TAG_SHA="$(jq -r .object.sha "$WORK/tag.json")"
  if [ "$TAG_TYPE" = tag ]; then
    TAG_SHA="$(gh api "repos/$REPO/git/tags/$TAG_SHA" --jq .object.sha)"
  fi
  test "$TAG_SHA" = "$RELEASE_COMMIT" || { echo '::error::Release tag points to a different source commit'; exit 1; }
else
  grep -q 'HTTP 404' "$WORK/tag-error" || { cat "$WORK/tag-error" >&2; exit 1; }
  test "$(gh api "repos/$REPO/releases/tags/$TAG" --jq .target_commitish)" = "$RELEASE_COMMIT"
fi
test "$(gh api "repos/$REPO/releases/tags/$TAG" --jq .prerelease)" = false
ensure_asset "$TAG" "$DIR/$ZIP"
ensure_asset "$TAG" "$DIR/SHA256SUMS"
ensure_asset "$TAG" "$DIR/manifest.json"
ensure_asset "$TAG" "$DIR/appcast.xml"

gh release edit "$TAG" --repo "$REPO" --draft=false --latest=false
TAG_SHA="$(gh api "repos/$REPO/git/ref/tags/$TAG" --jq .object.sha)"
TAG_TYPE="$(gh api "repos/$REPO/git/ref/tags/$TAG" --jq .object.type)"
if [ "$TAG_TYPE" = tag ]; then TAG_SHA="$(gh api "repos/$REPO/git/tags/$TAG_SHA" --jq .object.sha)"; fi
test "$TAG_SHA" = "$RELEASE_COMMIT"
verify_download "https://github.com/$REPO/releases/download/$TAG/$ZIP"

ensure_asset appcast "$DIR/$ZIP"
verify_download "https://github.com/$REPO/releases/download/appcast/$ZIP"

# Recheck immediately before replacement, after BOTH archives are verified.
fetch_public "https://github.com/$REPO/releases/download/appcast/appcast.xml" "$WORK/pre-upload-appcast.xml"
CURRENT_SHA="$(shasum -a 256 "$WORK/pre-upload-appcast.xml" | awk '{print $1}')"
if [ "$CURRENT_SHA" != "$LIVE_SHA" ] && [ "$CURRENT_SHA" != "$NEXT_SHA" ]; then
  echo '::error::Sparkle feed changed during publication; refusing replacement'
  exit 1
fi
if [ "$CURRENT_SHA" != "$NEXT_SHA" ]; then
  if ! gh release upload appcast "$DIR/appcast.xml" --repo "$REPO" --clobber; then
    # A failed request can have succeeded remotely. Never overwrite unknown state.
    STATUS="$(curl --silent --location --proto '=https' --tlsv1.2 --max-time 60 \
      --output "$WORK/after-error.xml" --write-out '%{http_code}' \
      "https://github.com/$REPO/releases/download/appcast/appcast.xml")" || STATUS=000
    if [ "$STATUS" = 200 ]; then
      AFTER_SHA="$(shasum -a 256 "$WORK/after-error.xml" | awk '{print $1}')"
      if [ "$AFTER_SHA" != "$NEXT_SHA" ]; then
        echo '::error::Feed upload failed; existing feed left untouched. Inspect it before retrying.'
        exit 1
      fi
    elif [ "$STATUS" = 404 ]; then
      mkdir -p "$WORK/restore"
      cp "$WORK/previous-appcast.xml" "$WORK/restore/appcast.xml"
      gh release upload appcast "$WORK/restore/appcast.xml" --repo "$REPO" || {
        echo '::error::Feed is missing and restoration failed. Restore previous-appcast.xml from the run artifact immediately.'
        exit 1
      }
      fetch_public "https://github.com/$REPO/releases/download/appcast/appcast.xml" "$WORK/restored.xml"
      cmp "$WORK/previous-appcast.xml" "$WORK/restored.xml"
      echo '::error::New feed upload failed; previous feed restored and verified. Retry the failed job.'
      exit 1
    else
      echo '::error::Feed upload outcome is uncertain; no blind overwrite attempted. Inspect GitHub and the saved previous-appcast.xml artifact.'
      exit 1
    fi
  fi
fi
fetch_public "https://github.com/$REPO/releases/download/appcast/appcast.xml" "$WORK/public-appcast.xml"
cmp "$DIR/appcast.xml" "$WORK/public-appcast.xml"
echo "Verified public release: https://github.com/$REPO/releases/tag/$TAG"
