#!/bin/bash
# Optional: publish a self-contained helper (its own .NET runtime) so the app needs no dotnet install.
# The bundled output is ~70 MB; run Scripts/build-helper.sh for the lightweight framework-dependent build.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RID="${1:-osx-arm64}"
OUT="${2:-$ROOT/Helper/publish/$RID}"

# A directory layout (rather than PublishSingleFile) is deliberate: single-file bundles extract
# native libraries into a temp directory on every first run, which is both slower and writes
# outside the app bundle. A plain self-contained folder runs directly and starts instantly.
dotnet publish "$ROOT/Helper/ILWorkbench.Helper.csproj" \
  -c Release -r "$RID" --self-contained true \
  -p:PublishSingleFile=false \
  -o "$OUT" --nologo

echo "self-contained helper: $OUT"
