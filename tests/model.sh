#!/usr/bin/env bash
# Stub bodies are single-quoted on purpose: they expand when the stub runs.
# shellcheck disable=SC2016
# Runs tests/model.qml against FlatsnapModel.qml, laid out as the installed
# plugin is (model beside the test, bin/ next to it): Quickshell resolves
# imports from the config's own directory, so `import ".."` cannot reach it.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
d=$(mktemp -d); trap 'rm -rf "$d"' EXIT
cp "$here/FlatsnapModel.qml" "$here/tests/model.qml" "$d/"
cp -r "$here/bin" "$d/bin"
# A writer that does get started must not touch the real flatsnap.nix.
export XDG_CONFIG_HOME="$d/config" XDG_STATE_HOME="$d/state"
unset NIXARCHY_FLATSNAP_FILE NIXARCHY_FLAKE NH_ELEVATION_STRATEGY INVOCATION_ID

# The model starts the real CLI, and an apply test would reach nixarchy-apply:
# only stubs and store-resolved tools are on its PATH (tests/isolate.sh).
qs=$(readlink -f "$(command -v quickshell)")
s="$d/stubs"; mkdir -p "$s"
stub() { printf '#!/bin/sh\n%s\n' "$2" >"$s/$1"; chmod +x "$s/$1"; }
stub nixarchy-apply 'echo invoked >>"$APPLY_LOG"; echo building; exit 0'
stub nix 'echo "$NIX_EVAL_ANSWER"'
stub flatpak 'exit 0'
stub sudo 'exit 1'
# The unit apply starts: never the real systemd tools (tests/isolate.sh).
stub systemd-run 'exit 1'
stub systemctl 'exit 0'
stub journalctl 'exit 0'
export APPLY_LOG="$d/apply.log"
export NIX_EVAL_ANSWER='{"hasModule":true,"uninstallUnmanaged":false,"declared":[],"current":{"flatpaks":[],"snaps":[]}}'
# shellcheck source=tests/isolate.sh disable=SC1091
. "$here/tests/isolate.sh"
P=$(isolated_path "$s" "$d/tools" bash jq nix-instantiate awk sed grep sha256sum cut \
  mktemp cat cp mv rm mkdir dirname uname tr head flock sort readlink) || { echo "ABORT: could not build the test PATH" >&2; exit 1; }
assert_isolated "$P" "$s"

out=$(timeout 30 env PATH="$P" "$qs" -p "$d/model.qml" 2>&1) || true
printf '%s\n' "$out" | grep -E 'FAIL|model:|ERROR' || { printf '%s\n' "$out" >&2; exit 1; }
printf '%s\n' "$out" | grep -q 'model: [0-9]* passed, 0 failed'
