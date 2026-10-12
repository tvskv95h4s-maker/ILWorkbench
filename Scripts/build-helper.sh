#!/bin/bash
# Builds the .NET decompiler/IL-editing helper that the macOS app drives.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIGURATION="${1:-Release}"

echo "==> building helper ($CONFIGURATION)"
dotnet build "$ROOT/Helper/ILWorkbench.Helper.csproj" -c "$CONFIGURATION" --nologo

echo "==> building sample fixture"
dotnet build "$ROOT/Samples/SampleLib/SampleLib.csproj" -c Release --nologo

echo "helper: $ROOT/Helper/bin/$CONFIGURATION/net7.0/ILWorkbench.Helper.dll"
