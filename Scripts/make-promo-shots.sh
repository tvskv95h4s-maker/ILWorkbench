#!/usr/bin/env bash
# Renders the README screenshots from the repository's own sample assembly.
# Nothing from your machine is opened: the sample is built here and copied to a neutral path
# so the assembly-info document does not show a personal home directory.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${CONFIG:-Release}"
APP="${APP:-$ROOT/build/Build/Products/$CONFIG/ILWorkbench.app/Contents/MacOS/ILWorkbench}"
OUT="${1:-$ROOT/docs/screenshots}"
RAW="$ROOT/build/promo-raw"
DEMO_DIR="${DEMO_DIR:-/Users/Shared/ILWorkbench-Sample}"

if [[ ! -x "$APP" ]]; then
  echo "app not built yet: $APP" >&2
  echo "run: xcodebuild -project ILWorkbench.xcodeproj -scheme ILWorkbench -configuration $CONFIG -derivedDataPath build build" >&2
  exit 1
fi

echo "==> building the sample assembly"
dotnet build "$ROOT/Samples/SampleLib/SampleLib.csproj" -c Release -v quiet --nologo

SAMPLE_SRC="$ROOT/Samples/SampleLib/bin/Release/net7.0/SampleLib.dll"
mkdir -p "$DEMO_DIR" "$OUT"
cp "$SAMPLE_SRC" "$DEMO_DIR/SampleLib.dll"
echo "==> sample copied to $DEMO_DIR/SampleLib.dll"

echo "==> rendering windows"
rm -rf "$RAW" && mkdir -p "$RAW"
"$APP" --promoshots "$DEMO_DIR/SampleLib.dll" "$RAW"

# The hero image is optional: it needs Python 3 with Pillow (set PYTHON to pick an interpreter).
PY_BIN="${PYTHON:-python3}"
if "$PY_BIN" -c "import PIL" 2>/dev/null; then
  echo "==> composing images in $OUT"
  "$PY_BIN" "$ROOT/Scripts/compose-promo.py" "$RAW" "$OUT"
else
  echo "==> skipping hero.png ($PY_BIN has no Pillow; set PYTHON=/path/to/python3)"
fi

echo "==> done: $OUT"
