#!/bin/bash
# Builds a universal Release app and packages it as a drag-to-Applications DMG.
#
# Optional distribution signing (needed to avoid the "unidentified developer" prompt):
#   export ILWORKBENCH_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
#   export ILWORKBENCH_NOTARY_PROFILE="ilworkbench"     # created with:
#       xcrun notarytool store-credentials ilworkbench --apple-id you@example.com \
#             --team-id TEAMID --password <app-specific-password>
# Without those, the app is ad-hoc signed: users must right-click -> Open the first time.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
  "$ROOT/build/Build/Products/Release/ILWorkbench.app/Contents/Info.plist" 2>/dev/null || echo 0.2.0)"
APP="$ROOT/build/Build/Products/Release/ILWorkbench.app"
DMG="$ROOT/dist/ILWorkbench-$VERSION.dmg"

if [ ! -x "$ROOT/Helper/publish/osx-arm64/ILWorkbench.Helper" ]; then
  echo "==> publishing self-contained helpers"
  "$ROOT/Scripts/publish-helper.sh" osx-arm64
  "$ROOT/Scripts/publish-helper.sh" osx-x64
fi

echo "==> building universal Release app"
xcodebuild -project "$ROOT/ILWorkbench.xcodeproj" -scheme ILWorkbench -configuration Release \
  -derivedDataPath "$ROOT/build" ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO build \
  | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED" || true

if [ -n "${ILWORKBENCH_SIGN_IDENTITY:-}" ]; then
  echo "==> signing with $ILWORKBENCH_SIGN_IDENTITY"
  codesign --force --deep --options runtime --timestamp \
    --sign "$ILWORKBENCH_SIGN_IDENTITY" "$APP"
  codesign --verify --deep --strict --verbose=2 "$APP"
else
  echo "==> ad-hoc signing (no ILWORKBENCH_SIGN_IDENTITY set)"
  codesign --force --deep --sign - "$APP"
fi

if [ -n "${ILWORKBENCH_NOTARY_PROFILE:-}" ]; then
  echo "==> notarizing (this can take a few minutes)"
  ZIP="$(mktemp -d)/ILWorkbench.zip"
  ditto -c -k --keepParent "$APP" "$ZIP"
  xcrun notarytool submit "$ZIP" --keychain-profile "$ILWORKBENCH_NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
fi

echo "==> packaging $DMG"
mkdir -p "$ROOT/dist"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "ILWorkbench" -srcfolder "$STAGE" -ov -format UDZO -quiet "$DMG"
rm -rf "$STAGE"
echo "DMG: $DMG ($(du -h "$DMG" | cut -f1))"
