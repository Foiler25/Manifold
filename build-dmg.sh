#!/usr/bin/env bash
set -euo pipefail

# build-dmg.sh — build Manifold.app (Release, ad-hoc signed) and package as a .dmg
# Usage: ./build-dmg.sh [version]
#   version: optional; defaults to MARKETING_VERSION from the Xcode project.

PROJECT="Manifold.xcodeproj"
SCHEME="Manifold"
APP_NAME="Manifold.app"
SPARKLE_KEYCHAIN_ACCOUNT="manifold"
REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LSREG="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

cd "$REPO_ROOT"

if ! command -v create-dmg >/dev/null 2>&1; then
  echo "error: create-dmg not found. Install with: brew install create-dmg" >&2
  exit 1
fi

if [[ "${1-}" != "" ]]; then
  VERSION="$1"
else
  VERSION="$(awk -F'= ' '/MARKETING_VERSION/ {gsub(/[; ]/, "", $2); print $2; exit}' "$PROJECT/project.pbxproj")"
fi

if [[ -z "$VERSION" ]]; then
  echo "error: could not determine version (pass as \$1 or set MARKETING_VERSION)" >&2
  exit 1
fi

DMG_NAME="Manifold-${VERSION}.dmg"
BUILD_DIR="build"
APP_PATH="$BUILD_DIR/Build/Products/Release/$APP_NAME"
STAGE_DIR="$(mktemp -d -t manifold-dmg-stage)"

# Cleanup on exit (success or failure):
#   1. Remove the staging dir.
#   2. Unregister and remove the build/ derived-data directory so it doesn't
#      linger as a stale LaunchServices entry — Shortcuts.app and Spotlight
#      compete with this copy when it sticks around, picking it over the
#      real /Applications install.
#   3. Sweep stale `/Volumes/dmg.*/Manifold.app` registrations left behind by
#      `create-dmg`'s temporary mounts. Only ones whose mount no longer
#      exists on disk are unregistered.
cleanup() {
  rm -rf "$STAGE_DIR" || true
  if [[ -n "${APP_PATH-}" && -d "$APP_PATH" ]]; then
    "$LSREG" -u "$APP_PATH" >/dev/null 2>&1 || true
  fi
  if [[ -n "${BUILD_DIR-}" && -d "$BUILD_DIR" ]]; then
    rm -rf "$BUILD_DIR" || true
  fi
  # Sweep zombie DMG-mount registrations for our app.
  if [[ -x "$LSREG" ]]; then
    "$LSREG" -dump 2>/dev/null \
      | awk '/^path:[[:space:]]+\/Volumes\/.*\/Manifold\.app[[:space:]]/{print $2}' \
      | while IFS= read -r p; do
          [[ -e "$p" ]] || "$LSREG" -u "$p" >/dev/null 2>&1 || true
        done
  fi
}
trap cleanup EXIT

echo "==> Building $APP_NAME (version $VERSION, Release, unsigned)"
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -derivedDataPath "$BUILD_DIR" \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO \
  clean build

if [[ ! -d "$APP_PATH" ]]; then
  echo "error: expected app at $APP_PATH not found" >&2
  exit 1
fi

echo "==> Removing AppleDouble metadata (non-native filesystem artifacts)"
dot_clean -m "$APP_PATH" || true
find "$APP_PATH" -name '._*' -delete

echo "==> Injecting Sparkle keys into Info.plist"
# Xcode's synthesized Info.plist drops non-whitelisted INFOPLIST_KEY_* entries,
# so we add Sparkle's keys here before codesigning covers them.
PLIST="$APP_PATH/Contents/Info.plist"
SPARKLE_FEED_URL="https://raw.githubusercontent.com/Foiler25/Manifold/main/appcast.xml"
# Sparkle EdDSA public key — paired with `keyfile.txt` (private, gitignored).
# Generated 2026-05-01 by Sparkle 2.9.1 `generate_keys --account manifold`.
# Public key is safe to commit; rotating this key requires a new keyfile.txt
# AND existing users to manually reinstall (the new public key won't validate
# updates signed by the old private key).
SPARKLE_PUBLIC_EDKEY="xHtrtfBbFRxLC+T4BXzw64fpQw1EvpeoKiTRpT48CFk="
/usr/libexec/PlistBuddy -c "Delete :SUFeedURL" "$PLIST" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :SUFeedURL string $SPARKLE_FEED_URL" "$PLIST"
/usr/libexec/PlistBuddy -c "Delete :SUPublicEDKey" "$PLIST" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string $SPARKLE_PUBLIC_EDKEY" "$PLIST"
/usr/libexec/PlistBuddy -c "Delete :SUEnableAutomaticChecks" "$PLIST" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :SUEnableAutomaticChecks bool true" "$PLIST"
/usr/libexec/PlistBuddy -c "Delete :SUScheduledCheckInterval" "$PLIST" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :SUScheduledCheckInterval integer 86400" "$PLIST"
/usr/libexec/PlistBuddy -c "Delete :SUEnableInstallerLauncherService" "$PLIST" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :SUEnableInstallerLauncherService bool false" "$PLIST"
/usr/libexec/PlistBuddy -c "Delete :SUEnableDownloaderService" "$PLIST" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :SUEnableDownloaderService bool false" "$PLIST"

# PlistBuddy can leave AppleDouble (._*) sidecars on non-APFS volumes; strip them
# again before codesigning so `codesign --deep` doesn't trip over them.
dot_clean -m "$APP_PATH" || true
find "$APP_PATH" -name '._*' -delete

echo "==> Ad-hoc signing (required for Apple Silicon launch)"
codesign --force --deep --sign - "$APP_PATH"

echo "==> Staging app for DMG"
cp -R "$APP_PATH" "$STAGE_DIR/"

rm -f "$DMG_NAME"

echo "==> Building $DMG_NAME"
create-dmg \
  --volname "Manifold $VERSION" \
  --window-size 500 300 \
  --icon-size 100 \
  --icon "$APP_NAME" 125 120 \
  --app-drop-link 375 120 \
  --hide-extension "$APP_NAME" \
  "$DMG_NAME" \
  "$STAGE_DIR/"

SHA="$(shasum -a 256 "$DMG_NAME" | awk '{print $1}')"

echo "==> Signing DMG for Sparkle"
SIGN_UPDATE="$(ls -1 "$HOME"/Library/Developer/Xcode/DerivedData/Manifold-*/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update 2>/dev/null | head -1)"
if [[ -z "$SIGN_UPDATE" || ! -x "$SIGN_UPDATE" ]]; then
  echo "error: sign_update not found. Build the project once in Xcode to fetch Sparkle first." >&2
  exit 1
fi

# Prefer keyfile.txt at repo root if present (portable across machines);
# otherwise fall back to the keychain account used at key-generation time.
if [[ -f "$REPO_ROOT/keyfile.txt" ]]; then
  SPARKLE_SIGNATURE_LINE="$("$SIGN_UPDATE" -f "$REPO_ROOT/keyfile.txt" "$DMG_NAME")"
else
  SPARKLE_SIGNATURE_LINE="$("$SIGN_UPDATE" --account "$SPARKLE_KEYCHAIN_ACCOUNT" "$DMG_NAME")"
fi
DMG_SIZE="$(stat -f%z "$DMG_NAME")"

echo "==> Writing .release-metadata for release script"
METADATA_FILE=".release-metadata"
COMMIT_FULL="$(git rev-parse HEAD)"
COMMIT_SHORT="$(git rev-parse --short HEAD)"
BRANCH="$(git rev-parse --abbrev-ref HEAD)"
BUILT_AT="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
PREVIOUS_TAG="$(git describe --tags --abbrev=0 2>/dev/null || true)"

cat >"$METADATA_FILE" <<EOF
# Written by build-dmg.sh — consumed by release-github.sh. Do not edit by hand.
VERSION=$VERSION
DMG=$DMG_NAME
SHA256=$SHA
COMMIT=$COMMIT_FULL
COMMIT_SHORT=$COMMIT_SHORT
BRANCH=$BRANCH
BUILT_AT=$BUILT_AT
PREVIOUS_TAG=$PREVIOUS_TAG
DMG_SIZE=$DMG_SIZE
SPARKLE_SIGNATURE_LINE='$SPARKLE_SIGNATURE_LINE'
EOF

echo ""
echo "Built: $REPO_ROOT/$DMG_NAME"
echo "SHA-256: $SHA"
echo "Commit: $COMMIT_SHORT ($BRANCH)"
echo "Metadata: $REPO_ROOT/$METADATA_FILE"
echo ""
echo "Next: smoke-test the DMG, then run: ./release-github.sh"
