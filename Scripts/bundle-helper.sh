#!/bin/bash
# Xcode build phase: copy the .NET helper into the app bundle.
# Prefers the self-contained publishes (Helper/publish/osx-*) so the shipped app needs no
# .NET runtime installed at all; falls back to the framework-dependent build for quick dev loops.
set -euo pipefail

ROOT="$SRCROOT"
DESTINATION="${BUILT_PRODUCTS_DIR}/${CONTENTS_FOLDER_PATH}/Resources/helper"
rm -rf "$DESTINATION"
mkdir -p "$DESTINATION"

copied=0
copy_payload() {
  local source="$1" name="$2"
  if [ -x "$source/ILWorkbench.Helper" ]; then
    mkdir -p "$DESTINATION/$name"
    cp -R "$source/." "$DESTINATION/$name/"
    echo "bundled helper ($name): $source"
    copied=1
  fi
}

copy_payload "$ROOT/Helper/publish/osx-arm64" "arm64"
copy_payload "$ROOT/Helper/publish/osx-x64" "x64"

if [ "$copied" = "0" ]; then
  for candidate in "$ROOT/Helper/bin/Release/net7.0" "$ROOT/Helper/bin/Debug/net7.0"; do
    if [ -f "$candidate/ILWorkbench.Helper.dll" ]; then
      mkdir -p "$DESTINATION/flat"
      cp -R "$candidate/." "$DESTINATION/flat/"
      echo "warning: self-contained helper missing, bundled framework-dependent build ($candidate)."
      echo "         Run Scripts/publish-helper.sh for both RIDs before shipping."
      copied=1
      break
    fi
  done
fi

if [ "$copied" = "0" ]; then
  echo "warning: no helper found to bundle; the app will fall back to the project build output."
fi
