#!/bin/zsh
# Publishes an update that installed copies of the app pick up on their own.
#   1. Raise CFBundleShortVersionString in Info.plist (e.g. 1.0.1), commit, push.
#   2. CODESIGN_IDENTITY="Developer ID Application: …" NOTARY_PROFILE=<name> ./release.sh
# Builds, notarizes, signs the update with the Keychain key (account
# "record-idevice"), and creates GitHub release v<version> with the zip and
# appcast.xml. Apps read https://github.com/…/releases/latest/download/appcast.xml.
set -e
cd "$(dirname "$0")"
[ -n "${NOTARY_PROFILE:-}" ] || { echo "error: set CODESIGN_IDENTITY and NOTARY_PROFILE (see build.sh)" >&2; exit 1; }
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist)
TAG="v$VERSION"
if git ls-remote --exit-code --tags origin "refs/tags/$TAG" >/dev/null; then
  echo "error: $TAG is already released. Raise the version in Info.plist first." >&2; exit 1
fi
[ "$(git rev-parse HEAD)" = "$(git rev-parse @{u})" ] || { echo "error: push this commit before releasing" >&2; exit 1; }

./build.sh

FEED=dist/feed
rm -rf "$FEED" && mkdir -p "$FEED"
cp dist/Record-iDevice.zip "$FEED/Record-iDevice-$VERSION.zip"
.build/artifacts/sparkle/Sparkle/bin/generate_appcast --account record-idevice \
  --download-url-prefix "https://github.com/thiernoyunus/record-idevice/releases/download/$TAG/" "$FEED"

gh release create "$TAG" --target "$(git rev-parse HEAD)" --title "Record iDevice $VERSION" --generate-notes \
  "$FEED/Record-iDevice-$VERSION.zip" "$FEED/appcast.xml"
echo "Released $TAG. Installed apps will offer it within a day, or right away via Check for Updates…"
