#!/usr/bin/env bash
# Compiles every plugin QML file against the installed Omarchy shell's own
# qs.* modules, headless. Catches type errors the node tests can't see, such as
# a function that clashes with a signal of the root type. Needs qs and an
# installed omarchy-shell, so it runs locally, not in CI.
#
# Menu.qml needs a live Wayland shell for its window type
# (PanelWindow). That known error is allowed; any other
# error fails the test.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
shell=$(dirname "$(readlink -f "$(command -v omarchy-shell)")")/../shell
[[ -f $shell/shell.qml ]] || { echo "SKIP: no omarchy shell found"; exit 0; }
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
for d in "$shell"/*/; do ln -s "$d" "$tmp/$(basename "$d")"; done
cat > "$tmp/shell.qml" <<'QML'
import QtQuick
import Quickshell
ShellRoot {
  Timer {
    interval: 100; running: true
    onTriggered: {
      var files = ["FlatsnapModel.qml", "Menu.qml"]
      for (var i = 0; i < files.length; i++) {
        var c = Qt.createComponent("file://" + Quickshell.env("PLUGDIR") + "/" + files[i],
                                   Component.PreferSynchronous)
        console.log("LOAD " + files[i] + " " + (c.status === Component.Ready ? "READY" : "ERROR " + c.errorString()))
      }
      Qt.quit()
    }
  }
}
QML
out=$(cd "$tmp" && PLUGDIR=$here QT_QPA_PLATFORM=offscreen timeout 20 qs -p "$tmp/shell.qml" 2>&1 | grep -o 'LOAD .*' || true)
printf '%s\n' "$out"
fail=0
while IFS= read -r line; do
  case $line in
    *READY) ;;
    "LOAD Menu.qml ERROR"*"No PanelWindow backend loaded"*) ;;
    *) fail=1 ;;
  esac
done <<< "$out"
[[ $(grep -c '^LOAD ' <<< "$out") -eq 2 ]] || fail=1
if (( fail != 0 )); then echo "FAIL: plugin QML does not compile"; exit 1; fi
echo "PASS: plugin QML compiles"
