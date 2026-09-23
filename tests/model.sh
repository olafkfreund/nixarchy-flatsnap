#!/usr/bin/env bash
# Runs tests/model.qml against FlatsnapModel.qml, laid out as the installed
# plugin is (model beside the test, bin/ next to it): Quickshell resolves
# imports from the config's own directory, so `import ".."` cannot reach it.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
d=$(mktemp -d); trap 'rm -rf "$d"' EXIT
cp "$here/FlatsnapModel.qml" "$here/tests/model.qml" "$d/"
cp -r "$here/bin" "$d/bin"
# A writer that does get started must not touch the real flatsnap.nix.
export NIXARCHY_FLATSNAP_FILE="$d/flatsnap.nix"
out=$(timeout 30 quickshell -p "$d/model.qml" 2>&1) || true
printf '%s\n' "$out" | grep -E 'FAIL|model:|ERROR' || { printf '%s\n' "$out" >&2; exit 1; }
printf '%s\n' "$out" | grep -q 'model: [0-9]* passed, 0 failed'
