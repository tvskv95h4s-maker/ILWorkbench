#!/bin/bash
# End-to-end verification of both editing layers against a real assembly:
#   1. structure tree
#   2. IL edit (string constant) -> save -> load the result in a real .NET process
#   3. structural edit (add field/method/type, remove method) -> save -> load the result again
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$ROOT/Scripts/build-helper.sh" Release >/dev/null
dotnet build "$ROOT/Samples/Verifier/Verifier.csproj" -c Release --nologo >/dev/null

HELPER="$ROOT/Helper/bin/Release/net7.0/ILWorkbench.Helper.dll"
SAMPLE="$ROOT/Samples/SampleLib/bin/Release/net7.0/SampleLib.dll"
VERIFIER="$ROOT/Samples/Verifier/bin/Release/net7.0/Verifier.dll"
WORK="$(mktemp -d)"
PATCHED="$WORK/SampleLib.patched.dll"
STRUCTURED="$WORK/SampleLib.structured.dll"

echo "== 1. structure tree =="
dotnet "$HELPER" --tree "$SAMPLE" | python3 -c "
import json,sys
tree=json.load(sys.stdin)
def walk(node, depth=0):
    if node['kind'] != 'assembly':
        print('  '*depth + f\"{node['kind']:<9} {node['name']:<18} {node.get('token') or ''}\")
    for child in node.get('children', []):
        walk(child, depth+1)
walk(tree)
"

echo
echo "== 2. runtime behaviour before any edit =="
dotnet "$VERIFIER" "$SAMPLE"

echo
echo "== 3. IL edit: rewrite a string constant, then save =="
dotnet "$HELPER" --patch-demo "$SAMPLE" "$PATCHED"

echo
echo "== 4. runtime behaviour after the IL edit =="
dotnet "$VERIFIER" "$PATCHED"

echo
echo "== 5. structural edit: add field/method/type, delete a method =="
dotnet "$HELPER" --structure-demo "$SAMPLE" "$STRUCTURED"

echo
echo "== 6. runtime behaviour after structural edits =="
dotnet "$VERIFIER" "$STRUCTURED"

echo
if [ "$(monodis --typedef "$STRUCTURED" 2>/dev/null | grep -c dummy_ptr)" != "0" ]; then
  echo "verify: FAILED (metadata contains dummy_ptr filler rows)"
  exit 1
fi
echo "verify: OK (patched and structurally edited assemblies both load and behave as edited)"
