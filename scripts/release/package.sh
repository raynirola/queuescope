#!/bin/bash
set -euo pipefail
umask 077

: "${RUNNER_TEMP:?Run on an ephemeral GitHub macOS runner}"
: "${RELEASE_VERSION:?}" "${RELEASE_COMMIT:?}" "${APPLE_TEAM_ID:?}"
ROOT="$(pwd)"
WORK="$(mktemp -d "$RUNNER_TEMP/queuescope-signing.XXXXXX")"
KEYCHAIN="$WORK/release.keychain-db"
KEYCHAIN_PASSWORD="$(openssl rand -base64 32)"
echo "::add-mask::$KEYCHAIN_PASSWORD"
cleanup() {
  security delete-keychain "$KEYCHAIN" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

# Keep credentials out of the workspace, logs and uploaded artifact paths.
printf '%s' "$DEVELOPER_ID_P12_BASE64" | base64 --decode > "$WORK/certificate.p12"
security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security set-keychain-settings -lut 21600 "$KEYCHAIN"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security import "$WORK/certificate.p12" -k "$KEYCHAIN" -P "$DEVELOPER_ID_P12_PASSWORD" -T /usr/bin/codesign -T /usr/bin/security >/dev/null
rm -f "$WORK/certificate.p12"
unset DEVELOPER_ID_P12_BASE64 DEVELOPER_ID_P12_PASSWORD
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null
security list-keychains -d user -s "$KEYCHAIN" "$HOME/Library/Keychains/login.keychain-db"
IDENTITY="$(security find-identity -v -p codesigning "$KEYCHAIN" | sed -n 's/.*\([A-F0-9]\{40\}\) "Developer ID Application:.*$/\1/p')"
test "$(printf '%s\n' "$IDENTITY" | wc -l | tr -d ' ')" = 1
test "${#IDENTITY}" = 40 || { echo '::error::Exactly one valid Developer ID Application identity is required'; exit 1; }
# Remove secret environment variables before xcodebuild can log build-phase environments.
xcrun notarytool store-credentials queuescope-ci --keychain "$KEYCHAIN" \
  --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_SPECIFIC_PASSWORD" >/dev/null
unset APPLE_ID APPLE_APP_SPECIFIC_PASSWORD
printf '%s\n' "$SPARKLE_ED_PRIVATE_KEY" > "$WORK/sparkle-private-key"
unset SPARKLE_ED_PRIVATE_KEY

python3 - "$WORK/export.plist" "$APPLE_TEAM_ID" "$IDENTITY" <<'PY'
import plistlib, sys
with open(sys.argv[1], 'wb') as f:
    plistlib.dump({'method':'developer-id', 'teamID':sys.argv[2], 'signingStyle':'manual', 'signingCertificate':sys.argv[3]}, f)
PY
xcodebuild -project BullMQDashboard.xcodeproj -scheme BullMQDashboard \
  -onlyUsePackageVersionsFromResolvedFile \
  -configuration Release -derivedDataPath "$WORK/DerivedData" \
  -archivePath "$WORK/QueueScope.xcarchive" -destination 'generic/platform=macOS' \
  ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$IDENTITY" DEVELOPMENT_TEAM="$APPLE_TEAM_ID" \
  OTHER_CODE_SIGN_FLAGS="--keychain $KEYCHAIN --timestamp" archive
xcodebuild -exportArchive -archivePath "$WORK/QueueScope.xcarchive" \
  -exportOptionsPlist "$WORK/export.plist" -exportPath "$WORK/export"
APP="$WORK/export/QueueScope.app"
test -d "$APP"
for binary in "$APP/Contents/MacOS/QueueScope" "$APP/Contents/Helpers/node"; do
  lipo -verify_arch arm64 x86_64 "$binary"
done
codesign --verify --deep --strict --verbose=2 "$APP"
check_signature() {
  local signed="$1" require_runtime="$2"
  codesign -dv --verbose=4 "$signed" 2> "$WORK/codesign.txt"
  grep -q '^Authority=Developer ID Application:' "$WORK/codesign.txt"
  grep -q "^TeamIdentifier=$APPLE_TEAM_ID$" "$WORK/codesign.txt"
  if [ "$require_runtime" = true ]; then
    grep -Eq '^CodeDirectory .*flags=.*runtime' "$WORK/codesign.txt"
  fi
  grep -q '^Timestamp=' "$WORK/codesign.txt"
}
check_signature "$APP" true
while IFS= read -r -d '' signed; do
  description="$(file -b "$signed")"
  if printf '%s' "$description" | grep -q 'Mach-O'; then
    runtime=false
    if printf '%s' "$description" | grep -q executable; then runtime=true; fi
    check_signature "$signed" "$runtime"
    lipo -verify_arch arm64 x86_64 "$signed"
  fi
done < <(find "$APP" -type f -print0)
if find "$APP/Contents/Resources/BullMQActionBridge" -name '*.node' -print | grep -q .; then
  echo '::error::Native Node add-ons unexpectedly present in the pure-JS bridge'
  exit 1
fi
python3 - "$APP/Contents/Info.plist" <<'PY'
import os, plistlib, re
with open('BullMQDashboard/Info.plist', 'rb') as f: source=plistlib.load(f)
with open(__import__('sys').argv[1], 'rb') as f: built=plistlib.load(f)
project=open('BullMQDashboard.xcodeproj/project.pbxproj').read()
assert built['CFBundleShortVersionString'] == os.environ['RELEASE_VERSION']
assert str(built['CFBundleVersion']) == re.search(r'CURRENT_PROJECT_VERSION = (\d+);', project).group(1)
assert built['SUPublicEDKey'] == source['SUPublicEDKey']
assert built['SUFeedURL'] == source['SUFeedURL']
PY
ditto -c -k --sequesterRsrc --keepParent "$APP" "$WORK/notarize.zip"
# The profile lives only in the temporary keychain and is deleted by the trap.
xcrun notarytool submit "$WORK/notarize.zip" --keychain "$KEYCHAIN" \
  --keychain-profile queuescope-ci --wait --timeout 30m --output-format json > "$WORK/notarization.json"
python3 - "$WORK/notarization.json" <<'PY'
import json, sys
result=json.load(open(sys.argv[1]))
if result.get('status') != 'Accepted':
    raise SystemExit('Apple notarization did not return Accepted. Submission ID: '+str(result.get('id')))
PY
NOTARY_ID="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["id"])' "$WORK/notarization.json")"
xcrun notarytool log "$NOTARY_ID" --keychain "$KEYCHAIN" \
  --keychain-profile queuescope-ci "$WORK/notarization-log.json"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
spctl --assess --type execute --verbose=4 "$APP"

mkdir -p "$ROOT/release-output" "$WORK/archives"
ZIP="QueueScope-$RELEASE_VERSION-macOS.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$WORK/archives/$ZIP"
# Preserve existing update history. A missing feed is an error, not a new empty feed.
curl --fail --location --retry 3 --proto '=https' --tlsv1.2 \
  https://github.com/raynirola/queuescope/releases/download/appcast/appcast.xml \
  --output "$ROOT/release-output/appcast.xml"
shasum -a 256 "$ROOT/release-output/appcast.xml" | awk '{print $1}' > "$ROOT/release-output/appcast-base.sha256"
cp "$ROOT/release-output/appcast.xml" "$ROOT/release-output/previous-appcast.xml"
SPARKLE_BIN="$(find "$WORK/DerivedData/SourcePackages/artifacts" -type f -path '*/bin/generate_appcast' -print -quit)"
test -x "$SPARKLE_BIN" || { echo '::error::Pinned Sparkle generate_appcast tool was not found'; exit 1; }
cat "$WORK/sparkle-private-key" | "$SPARKLE_BIN" --ed-key-file - \
  --download-url-prefix 'https://github.com/raynirola/queuescope/releases/download/appcast/' \
  --maximum-versions 0 --maximum-deltas 0 -o "$ROOT/release-output/appcast.xml" "$WORK/archives"
cp "$WORK/archives/$ZIP" "$ROOT/release-output/$ZIP"
rm -f "$WORK/sparkle-private-key"
python3 scripts/release/metadata.py finalize --directory release-output --version "$RELEASE_VERSION" --commit "$RELEASE_COMMIT"
swift scripts/release/verify-sparkle.swift BullMQDashboard/Info.plist "release-output/$ZIP" release-output/appcast.xml "$RELEASE_VERSION"
cp "docs/releases/$RELEASE_VERSION.md" release-output/release-notes.md
echo 'Signed, notarized, stapled universal archive and Sparkle signature verified.'
