#!/usr/bin/env bash
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

printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
