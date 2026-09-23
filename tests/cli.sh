#!/usr/bin/env bash
# `cond && ok || bad` is safe: ok only increments a counter and never fails.
# Single-quoted $(...) and ${...} are the point: hostile input, unexpanded.
# shellcheck disable=SC2015,SC2016
# Offline tests for bin/nixarchy-flatsnap. No network: every API response is
# a fixture in tests/fixtures. Run: bash tests/cli.sh
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
cli="$here/../bin/nixarchy-flatsnap"
export NIXARCHY_FLATSNAP_OFFLINE="$here/fixtures"

pass=0 fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); printf 'FAIL: %s\n' "$*" >&2; }

# expect <input> <jq filter that must be true>
expect() {
  local out
  out=$(bash "$cli" resolve "$1") || { bad "resolve '$1' exited $? -> $out"; return; }
  jq -e "$2" <<<"$out" >/dev/null || { bad "resolve '$1': $2 -> $out"; return; }
  ok
}

# refuse <input>: exit 2 and an {"error"} object, nothing else.
refuse() {
  local out rc
  out=$(bash "$cli" resolve "$1"); rc=$?
  if [ $rc -eq 2 ] && jq -e '.error | length > 0' <<<"$out" >/dev/null; then ok
  else bad "should refuse '$1' (rc=$rc) -> $out"; fi
}

# refuse_early <input>: refused by validation, before any lookup ran.
export NIXARCHY_FLATSNAP_FETCHLOG
NIXARCHY_FLATSNAP_FETCHLOG=$(mktemp); trap 'rm -f "$NIXARCHY_FLATSNAP_FETCHLOG"' EXIT
refuse_early() {
  : >"$NIXARCHY_FLATSNAP_FETCHLOG"
  refuse "$1"
  [ -s "$NIXARCHY_FLATSNAP_FETCHLOG" ] && bad "'$1' reached a lookup: $(tr '\n' ' ' <"$NIXARCHY_FLATSNAP_FETCHLOG")"
  true
}

# ---- every row of the spec's input table --------------------------------
expect 'https://flathub.org/apps/org.gnome.Calculator'          '.store=="flatpak" and .id=="org.gnome.Calculator" and (.permissions|type=="object")'
expect 'https://flathub.org/apps/details/org.gnome.Calculator/' '.id=="org.gnome.Calculator"'
expect 'https://flathub.org/en/apps/org.gnome.Calculator?x=1'   '.id=="org.gnome.Calculator"'
expect 'https://dl.flathub.org/repo/appstream/org.gnome.Calculator.flatpakref' '.id=="org.gnome.Calculator"'
expect 'https://snapcraft.io/hello-world'                       '.store=="snap" and .id=="hello-world" and .confinement=="strict" and .classic==false'
expect 'flatpak install flathub org.gnome.Calculator'           '.id=="org.gnome.Calculator"'
expect 'flatpak install -y org.gnome.Calculator'                '.id=="org.gnome.Calculator"'
expect 'snap install hello-world --channel=beta'                '.id=="hello-world" and .channel=="beta"'
expect 'snap install hello-world --edge'                        '.channel=="edge"'
expect 'snap install code --classic'                            '.classic==true'
expect 'snap install code'                                      '.classic==true and .confinement=="classic"'
expect '  org.gnome.Calculator  '                               '.store=="flatpak"'
expect 'hello-world'                                            '.store=="snap" and .id=="hello-world"'

# ---- hostile and out-of-scope input: refused, never looked up -----------
# The single quotes are the point: these must reach the CLI unexpanded.
# shellcheck disable=SC2016
{
refuse_early '$(id)'
refuse_early '"; rm -rf ~'
refuse_early '${x}'
refuse_early 'org.gnome.${x}.App'
refuse_early 'http://flathub.org/apps/a.b.c'
refuse_early 'https://evil.example/apps/a.b.c'
refuse_early 'https://flathub.org.evil.example/apps/a.b.c'
refuse_early 'https://example.org/repo/foo.flatpakref'
refuse_early 'https://flathub.org/apps/a.b.c/../../x'
refuse_early 'https://snapcraft.io/Bad_Name'
refuse_early 'flatpak install gnome-nightly org.gnome.Calculator'
refuse_early 'flatpak install --user org.gnome.Calculator'
refuse_early 'snap install hello-world --channel=latest/stable; id'
refuse_early 'snap install hello-world --channel=latest/stable'
refuse_early 'snap install hello-world --devmode'
refuse_early 'snap install a b'
refuse_early "$(printf 'hello-world\nid')"
refuse_early ''
refuse_early "$(printf 'a%.0s' {1..600})"
refuse 'no-such-snap'
refuse 'org.example.DoesNotExist'
}

expect 'calculator' '.store=="ask" and (.candidates | length) == 3 and .candidates[0].id == "org.gnome.Calculator"'

# ---- search ---------------------------------------------------------------
run() { bash "$cli" "$@"; }
check() { # check <description> <jq filter> <cmd...>
  local d=$1 f=$2 out; shift 2
  out=$("$@") || { bad "$d: exited $? -> $out"; return; }
  jq -e "$f" <<<"$out" >/dev/null && ok || bad "$d: $f -> $out"
}
check "search flathub" '.[0] == {store:"flatpak",id:"org.gnome.Calculator",name:"Calculator",summary:.[0].summary}' run search flatpak calculator
check "search snap"    'map(.id) == ["hello","hello-world","hello-pasman"]' run search snap hello
out=$(run search snap "$(printf 'a\nb')"); [ $? -eq 2 ] && ok || bad "multi-line search accepted: $out"
out=$(run search apt hello); [ $? -eq 2 ] && ok || bad "unknown store accepted: $out"

# ---- add / rm / list, round-tripping through Nix -------------------------
work=$(mktemp -d); trap 'rm -rf "$work" "$NIXARCHY_FLATSNAP_FETCHLOG"' EXIT
export NIXARCHY_FLATSNAP_FILE="$work/flatsnap.nix"
# No flatpak or snap on PATH: installed must be null ("unknown"), not false.
parses() { nix-instantiate --parse "$NIXARCHY_FLATSNAP_FILE" >/dev/null 2>&1 && ok || bad "file does not parse: $(cat "$NIXARCHY_FLATSNAP_FILE")"; }

check "list empty" '. == []' run list
check "add flatpak" '. == [{store:"flatpak",id:"org.gnome.Calculator",overrides:{},installed:null}]' run add flatpak org.gnome.Calculator
parses
check "add flatpak with overrides" '.[0].overrides == {"Context":{"filesystems":["xdg-pictures:ro","~/Games"]},"Environment":{"LC_ALL":"C.UTF-8"}}' \
  run add flatpak org.gnome.Calculator --override Context.filesystems=xdg-pictures:ro --override Context.filesystems=~/Games --override Environment.LC_ALL=C.UTF-8
parses
check "add snap" '.[1] == {store:"snap",id:"code",channel:"edge",classic:true,installed:null}' run add snap code --channel edge --classic
parses
check "re-add replaces, no duplicate" '(map(select(.id=="code")) | length) == 1 and .[1].channel == "stable"' run add snap code
check "rm flatpak" 'map(.id) == ["code"]' run rm flatpak org.gnome.Calculator
parses
check "rm snap" '. == []' run rm snap code
parses
out=$(run rm snap code); [ $? -eq 2 ] && ok || bad "rm of undeclared entry accepted: $out"
for a in 'flatpak org.x.${y}' 'snap Bad_Name' 'snap ok --channel latest/stable' 'flatpak org.a.B --override Context.filesystems=$(id)' 'flatpak org.a.B --override bad'; do
  # shellcheck disable=SC2086 # word-splitting the case into argv is the point
  out=$(run add $a); [ $? -eq 2 ] && ok || bad "add $a accepted: $out"
done

# A hand edit that keeps the shape survives the next write.
run add snap hello-world >/dev/null
sed -i 's|    flatpaks = \[|    flatpaks = [\n      { appId = "org.hand.Edited"; }|' "$NIXARCHY_FLATSNAP_FILE"
check "hand edit kept" 'map(.id) == ["org.hand.Edited","hello-world","code"]' run add snap code
# One that breaks the shape is refused, and the file is not touched.
for foreign in '{ config, ... }: { }' '{ services.foo.enable = true; programs.nixarchy.flatsnap.snaps = [ ]; }'; do
  printf '%s\n' "$foreign" >"$NIXARCHY_FLATSNAP_FILE"
  out=$(run add snap x1); rc=$?
  [ $rc -eq 2 ] && [ "$(cat "$NIXARCHY_FLATSNAP_FILE")" = "$foreign" ] && ok || bad "foreign shape overwritten (rc=$rc): $out"
done

# A generated file that fails to parse restores the backup.
run rm flatpak org.hand.Edited >/dev/null 2>&1; rm -f "$NIXARCHY_FLATSNAP_FILE"
run add snap hello-world >/dev/null; cp "$NIXARCHY_FLATSNAP_FILE" "$work/before"
mkdir "$work/fakebin"; printf '#!/bin/sh\ncase "$1" in --parse) exit 1;; esac\nexec %s "$@"\n' "$(command -v nix-instantiate)" >"$work/fakebin/nix-instantiate"; chmod +x "$work/fakebin/nix-instantiate"
out=$(PATH="$work/fakebin:$PATH" run add snap code); rc=$?
[ $rc -eq 2 ] && cmp -s "$work/before" "$NIXARCHY_FLATSNAP_FILE" && [ -z "$(find "$work" -name 'flatsnap.nix.??????')" ] && ok || bad "parse failure did not restore (rc=$rc): $out"

# installed: stub flatpak/snap on PATH.
printf '#!/bin/sh\necho org.gnome.Calculator\n' >"$work/fakebin/flatpak"
printf '#!/bin/sh\nprintf "Name Version\\nhello-world 6.4\\n"\n' >"$work/fakebin/snap"
rm "$work/fakebin/nix-instantiate"; chmod +x "$work/fakebin/"*
run add flatpak org.gnome.Calculator >/dev/null
check "installed flags" 'map({(.id): .installed}) | add == {"hello-world":true,"org.gnome.Calculator":true}' env PATH="$work/fakebin:$PATH" bash "$cli" list
run add snap code >/dev/null
check "not installed" '(.[] | select(.id=="code") | .installed) == false' env PATH="$work/fakebin:$PATH" bash "$cli" list

printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
