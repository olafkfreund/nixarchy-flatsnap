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
expect 'snap install code'                                      '.confinements == {"stable":"classic"}'
expect 'https://snapcraft.io/hello-world'                       '(.confinements | keys) == (.channels) and ([.confinements[]] | unique) == ["strict"]'
expect '  org.gnome.Calculator  '                               '.store=="flatpak"'
expect 'hello-world'                                            '.store=="snap" and .id=="hello-world"'
# No channel named: offer the first one the snap publishes, and its
# confinement (fixture: beta strict, edge classic, no stable) (#13 C5).
expect 'https://snapcraft.io/no-stable'                         '.channel=="beta" and .confinement=="strict" and .classic==false'
expect 'snap install no-stable --edge'                          '.channel=="edge" and .classic==true'
expect 'snap install hello-world --channel=beta'                '.channel=="beta"'
# A default track other than latest: snap installs a bare risk from THAT
# track (razer: node --channel=stable -> 24/stable), so describe it (#13 C6).
expect 'https://snapcraft.io/trackdemo'                         '.channels==["stable"] and .channel=="stable" and .confinement=="classic" and .classic==true'
# A channel named but not published is refused up front, not at apply.
out=$(bash "$cli" resolve 'snap install no-stable --channel=stable'); rc=$?
[ $rc -eq 2 ] && jq -e '.error | test("does not publish stable") and test("beta") and test("edge")' <<<"$out" >/dev/null && ok ||
  bad "unpublished channel accepted (rc=$rc): $out"

# ---- hostile and out-of-scope input: refused, never looked up -----------
# The single quotes are the point: these must reach the CLI unexpanded.
# shellcheck disable=SC2016
{
refuse_early '$(id)'
refuse_early '"; rm -rf ~'
# Only the install verb itself, and Flatpak IDs within D-Bus's 255 (#13 C9).
refuse_early 'flatpak installx org.gnome.Calculator'
refuse_early "org.example.$(printf 'A%.0s' $(seq 244))"
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

expect 'calculator' '.store=="ask" and (.candidates | length) == 4 and .candidates[0].id == "org.gnome.Calculator"'

# ---- what the card says about trust (#12) ---------------------------------
# verified: true / false / null (null = could not tell, never "unverified").
expect 'org.gnome.Calculator'   '.verified == true and .verifiedAs == "gnome.org" and (.permissions | type) == "object"'
expect 'com.spotify.Client'     '.verified == false and .verifiedAs == ""'
expect 'org.example.NoMeta'     '.verified == null and (.permissions | type) == "object"'
# A failed summary lookup is unknown permissions, not "none listed".
expect 'org.example.NoSummary'  '.permissions == null and .verified == true'
expect 'hello-world'            '.verified == true'
expect 'calculator-linux'       '.verified == false and .publisher == "Shah Faishal Khan"'
# The CLI owns the sandbox-escape list; every flatpak card carries it.
has_escape() { printf 'any(.sandboxEscapes[]; .section == "%s" and .key == "%s" and (.values | index("%s")) != null)' "$1" "$2" "$3"; }
expect 'org.gnome.Calculator' '(.sandboxEscapes | length) > 0 and all(.sandboxEscapes[]; (.says | length) > 0)'
for e in 'Context filesystems host' 'Context filesystems host-os' 'Context filesystems host-etc' \
         'Context filesystems home' 'Context filesystems ~' 'Context sockets session-bus' \
         'Context sockets system-bus' 'Context sockets ssh-auth' 'Context sockets gpg-agent' \
         'Context devices all' 'Session Bus Policy|org.freedesktop.Flatpak|talk' \
         'Session Bus Policy|org.freedesktop.Flatpak|own' 'System Bus Policy|*|talk' 'System Bus Policy|*|own'; do
  if [[ $e == *'|'* ]]; then IFS='|' read -r s k v <<<"$e"; else read -r s k v <<<"$e"; fi
  expect 'org.gnome.Calculator' "$(has_escape "$s" "$k" "$v")"
done
expect 'org.gnome.Calculator' 'all(.sandboxEscapes[]; .key != "features")'
# The app's own permissions, against the same list (manifestEscapes). Real
# recorded summaries: VS Code escapes five ways, Firefox two; entries in
# manifest order. Firefox's own org.mozilla.firefox.* and :ro paths do not.
expect 'com.visualstudio.code' '[.manifestEscapes[].entry] == ["devices=all", "sockets=ssh-auth",
  "session-bus talk org.freedesktop.Flatpak", "filesystems=host", "system-bus talk org.freedesktop.login1"]
  and all(.manifestEscapes[]; (.says | length) > 0)'
expect 'org.mozilla.firefox'   '[.manifestEscapes[].entry] == ["system-bus talk org.freedesktop.NetworkManager", "devices=all"]'
expect 'org.gnome.Calculator'  '.manifestEscapes == []'
expect 'com.spotify.Client'    '.manifestEscapes == []'
expect 'org.example.NoMeta'    '.manifestEscapes == []'
# Unknown stays unknown: no summary is null, never "no escapes".
expect 'org.example.NoSummary' '.permissions == null and .manifestEscapes == null'
# Shapes: :ro still matches; !host, ~/Games and features=devel do not; a
# wildcard bus name covers org.freedesktop.Flatpak; a non-list value is skipped.
expect 'org.example.Shapes'    '[.manifestEscapes[].entry] == ["filesystems=host:ro", "session-bus talk org.freedesktop.*"]
  and .manifestEscapes[1].says == "running commands outside the sandbox"'

# ---- search ---------------------------------------------------------------
run() { bash "$cli" "$@"; }
check() { # check <description> <jq filter> <cmd...>
  local d=$1 f=$2 out; shift 2
  out=$("$@") || { bad "$d: exited $? -> $out"; return; }
  jq -e "$f" <<<"$out" >/dev/null && ok || bad "$d: $f -> $out"
}
# fixtures/flathub-search.json is search_flathub's default fixture; it matches
# flathub-search-calculator.json (resolve's, by ID) on purpose. Both are used.
check "search flathub" '.[0] == {store:"flatpak",id:"org.gnome.Calculator",name:"Calculator",summary:.[0].summary,verified:true,verifiedAs:"gnome.org"}' run search flatpak calculator
check "search snap"    'map(.id) == ["hello","hello-world","hello-pasman"]' run search snap hello
# Every row says verified or not; a Flathub login verification names who.
check "search flathub verified" 'all(has("verified")) and map(.verified) == [true,true,true,false] and .[1].verifiedAs == "teams/flathub (kde)"' run search flatpak calculator
check "search snap verified"    'map(.verified) == [true,true,false]' run search snap hello
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
# A section with spaces (#28): what the panel now passes as one --override.
check "add flatpak with Bus Policy overrides" '.[0].overrides == {"Session Bus Policy":{"org.freedesktop.Flatpak":"talk"},"System Bus Policy":{"org.freedesktop.login1":"own"}}' \
  run add flatpak org.gnome.Calculator --override "Session Bus Policy.org.freedesktop.Flatpak=talk" --override "System Bus Policy.org.freedesktop.login1=own"
parses
check "Bus Policy survives list" '.[0].overrides["Session Bus Policy"]["org.freedesktop.Flatpak"] == "talk"' run list
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

# Concurrent writers: every add that exits 0 is in the file (#13 C1).
rm -f "$NIXARCHY_FLATSNAP_FILE"
for i in $(seq 1 20); do run add flatpak "org.test.App$i" >/dev/null 2>&1 & done
rcs=0; for j in $(jobs -p); do wait "$j" || rcs=$((rcs + 1)); done
check "20 concurrent adds, 20 entries" 'length == 20' run list
[ "$rcs" -eq 0 ] && ok || bad "$rcs concurrent adds failed"
rm -f "$NIXARCHY_FLATSNAP_FILE"

# A hand edit that keeps the shape survives the next write.
run add snap hello-world >/dev/null
sed -i 's|    flatpaks = \[|    flatpaks = [\n      { appId = "org.hand.Edited"; }|' "$NIXARCHY_FLATSNAP_FILE"
check "hand edit kept" 'map(.id) == ["org.hand.Edited","hello-world","code"]' run add snap code
# A backslash in a hand-edited value survives a rewrite as one backslash (#13 C7).
printf '{ programs.nixarchy.flatsnap = { flatpaks = [ { appId = "org.hand.Bs"; overrides = { Environment = { X = "a\\\\b"; }; }; } ]; snaps = [ ]; }; }\n' >"$NIXARCHY_FLATSNAP_FILE"
run add snap code >/dev/null
check "backslash round trip" '(.[] | select(.id=="org.hand.Bs") | .overrides.Environment.X) == "a\\b"' run add snap code
run rm flatpak org.hand.Bs >/dev/null
out=$(run add flatpak "org.example.$(printf 'A%.0s' $(seq 244))"); [ $? -eq 2 ] && ok || bad "256-character Flatpak ID accepted: $out"
check "255-character Flatpak ID" 'length > 0' run add flatpak "org.example.$(printf 'A%.0s' $(seq 243))"
run rm flatpak "org.example.$(printf 'A%.0s' $(seq 243))" >/dev/null

# One that breaks the shape is refused, and the file is not touched.
for foreign in '{ config, ... }: { }' '{ services.foo.enable = true; programs.nixarchy.flatsnap.snaps = [ ]; }'; do
  printf '%s\n' "$foreign" >"$NIXARCHY_FLATSNAP_FILE"
  out=$(run add snap x1); rc=$?
  [ $rc -eq 2 ] && [ "$(cat "$NIXARCHY_FLATSNAP_FILE")" = "$foreign" ] && ok || bad "foreign shape overwritten (rc=$rc): $out"
done

# A generated file that fails to parse leaves the old one in place.
run rm flatpak org.hand.Edited >/dev/null 2>&1; rm -f "$NIXARCHY_FLATSNAP_FILE"
run add snap hello-world >/dev/null; cp "$NIXARCHY_FLATSNAP_FILE" "$work/before"
mkdir "$work/fakebin"; printf '#!/bin/sh\ncase "$1" in --parse) exit 1;; esac\nexec %s "$@"\n' "$(command -v nix-instantiate)" >"$work/fakebin/nix-instantiate"; chmod +x "$work/fakebin/nix-instantiate"
out=$(PATH="$work/fakebin:$PATH" run add snap code); rc=$?
[ $rc -eq 2 ] && cmp -s "$work/before" "$NIXARCHY_FLATSNAP_FILE" && [ -z "$(find "$work" -name 'flatsnap.nix.??????')" ] && ok || bad "parse failure did not restore (rc=$rc): $out"
[ -z "$(find "$work" -name '*.bak')" ] && ok || bad "a .bak was written"
# No stale state comes back: an old .bak beside a deleted file stays unused (#13 C4).
mv "$NIXARCHY_FLATSNAP_FILE" "$NIXARCHY_FLATSNAP_FILE.bak"
out=$(PATH="$work/fakebin:$PATH" run add snap code); rc=$?
[ $rc -eq 2 ] && [ ! -e "$NIXARCHY_FLATSNAP_FILE" ] && ok || bad "stale .bak restored (rc=$rc): $out"
mv "$NIXARCHY_FLATSNAP_FILE.bak" "$NIXARCHY_FLATSNAP_FILE"

# installed: stub flatpak/snap on PATH.
printf '#!/bin/sh\necho org.gnome.Calculator\n' >"$work/fakebin/flatpak"
printf '#!/bin/sh\nprintf "Name Version\\nhello-world 6.4\\n"\n' >"$work/fakebin/snap"
rm "$work/fakebin/nix-instantiate"; chmod +x "$work/fakebin/"*
run add flatpak org.gnome.Calculator >/dev/null
check "installed flags" 'map({(.id): .installed}) | add == {"hello-world":true,"org.gnome.Calculator":true}' env PATH="$work/fakebin:$PATH" bash "$cli" list
run add snap code >/dev/null
check "not installed" '(.[] | select(.id=="code") | .installed) == false' env PATH="$work/fakebin:$PATH" bash "$cli" list

# ---- pendingRemoval: keeps snapd on until the snap is really gone -------
rm -f "$NIXARCHY_FLATSNAP_FILE"; rm -f "$work/fakebin/"*
run add snap hello-world >/dev/null
run rm snap hello-world >/dev/null
grep -q 'pendingRemoval = \[ "hello-world" \];' "$NIXARCHY_FLATSNAP_FILE" && ok || bad "rm did not queue removal: $(cat "$NIXARCHY_FLATSNAP_FILE")"
parses
run add snap hello-world >/dev/null   # re-declared: no longer pending
grep -q pendingRemoval "$NIXARCHY_FLATSNAP_FILE" && bad "re-add left it pending" || ok
run rm snap hello-world >/dev/null
# snap still lists it: stays pending. snap no longer lists it: pruned.
printf '#!/bin/sh\nprintf "Name Version\\nhello-world 6.4\\n"\n' >"$work/fakebin/snap"; chmod +x "$work/fakebin/snap"
PATH="$work/fakebin:$PATH" run add flatpak org.gnome.Calculator >/dev/null
grep -q pendingRemoval "$NIXARCHY_FLATSNAP_FILE" && ok || bad "pruned while still installed"
printf '#!/bin/sh\nprintf "Name Version\\n"\n' >"$work/fakebin/snap"
PATH="$work/fakebin:$PATH" run rm flatpak org.gnome.Calculator >/dev/null
grep -q pendingRemoval "$NIXARCHY_FLATSNAP_FILE" && bad "not pruned once gone" || ok

# snap present but not answering (snapd down): unknown, not "none installed" (#13 C3, C8).
rm -f "$NIXARCHY_FLATSNAP_FILE"
run add snap hello-world >/dev/null; run rm snap hello-world >/dev/null; run add snap code >/dev/null
printf '#!/bin/sh\necho "error: cannot communicate with server" >&2\nexit 1\n' >"$work/fakebin/snap"
PATH="$work/fakebin:$PATH" run add flatpak org.gnome.Calculator >/dev/null
grep -q 'pendingRemoval = \[ "hello-world" \];' "$NIXARCHY_FLATSNAP_FILE" && ok || bad "pruned on a failing snap: $(cat "$NIXARCHY_FLATSNAP_FILE")"
check "failing snap is unknown" '(.[] | select(.id=="code") | .installed) == null' env PATH="$work/fakebin:$PATH" bash "$cli" list

# ---- the reconciler, against a stub snap with state ----------------------
rec="$here/../bin/nixarchy-flatsnap-reconcile"
db="$work/snapdb"; export db
cat >"$work/fakebin/snap" <<'STUB'
#!/bin/sh
# "name tracking notes" lines in $db (notes: classic or empty); every call logged.
echo "$*" >>"$db.log"
case $1 in
  wait) ;;
  list)
    shift; name=; for a; do case $a in -*) ;; *) name=$a ;; esac; done
    [ -z "$name" ] || grep -q "^$name " "$db" || { echo "error: no matching snaps installed" >&2; exit 1; }
    echo "Name Version Rev Tracking Publisher Notes"
    while read -r n t no; do [ -z "$name" ] || [ "$n" = "$name" ] || continue; echo "$n 1.0 1 $t pub ${no:--}"; done <"$db" ;;
  # snapd ignores --classic for a strict snap; hello-world is strict here.
  install) ch=${3#--channel=}; [ "$2" = broken ] && exit 1
    no=; [ "${4:-}" = --classic ] && [ "$2" != hello-world ] && no=classic
    echo "$2 latest/$ch $no" >>"$db" ;;
  refresh) ch=${3#--channel=}; sed -i "s|^$2 [^ ]*|$2 latest/$ch|" "$db" ;;
  remove) [ "$2" = --purge ] || exit 1; sed -i "/^$3 /d" "$db" ;;
esac
STUB
chmod +x "$work/fakebin/snap"
export STATE_DIRECTORY="$work/state"; mkdir -p "$STATE_DIRECTORY"
reconcile() { printf '%s' "$1" >"$work/plan.json"; : >"$db.log"; PATH="$work/fakebin:$PATH" bash "$rec" "$work/plan.json"; }

echo "byhand latest/stable" >"$db"
reconcile '{"snaps":[{"name":"hello-world","channel":"stable","classic":false},{"name":"code","channel":"stable","classic":true}]}' >/dev/null
grep -qx 'install code --channel=stable --classic' "$db.log" && grep -qx 'install hello-world --channel=stable' "$db.log" && ok || bad "install calls: $(cat "$db.log")"
[ "$(sort "$STATE_DIRECTORY/managed" | tr '\n' ' ')" = "code hello-world " ] && ok || bad "managed: $(cat "$STATE_DIRECTORY/managed")"

reconcile '{"snaps":[{"name":"hello-world","channel":"edge","classic":false},{"name":"code","channel":"stable","classic":true}]}' >/dev/null
grep -qx 'refresh hello-world --channel=edge' "$db.log" && ! grep -q '^install' "$db.log" && ok || bad "refresh calls: $(cat "$db.log")"

# Un-declare everything: ours go, the hand-installed one stays.
reconcile '{"snaps":[]}' >/dev/null
[ "$(cut -d' ' -f1 "$db")" = byhand ] && [ ! -s "$STATE_DIRECTORY/managed" ] && ok || bad "removal: db=$(cat "$db") managed=$(cat "$STATE_DIRECTORY/managed")"

# Declaring a hand-installed snap does not make it ours to remove later.
reconcile '{"snaps":[{"name":"byhand","channel":"stable","classic":false}]}' >/dev/null
reconcile '{"snaps":[]}' >/dev/null
grep -q '^byhand ' "$db" && ok || bad "removed a hand-installed snap"

# One failure: the rest still happen, and the exit code says so.
reconcile '{"snaps":[{"name":"broken","channel":"stable","classic":false},{"name":"hello-world","channel":"stable","classic":false}]}' >/dev/null; rc=$?
[ $rc -eq 1 ] && grep -q '^hello-world ' "$db" && ok || bad "partial failure: rc=$rc db=$(cat "$db")"

# A snap on a non-latest default track is not refreshed on every run (#13 C6).
printf 'node 24/stable classic\n' >"$db"
reconcile '{"snaps":[{"name":"node","channel":"stable","classic":true}]}' >/dev/null; rc=$?
[ $rc -eq 0 ] && ! grep -q '^refresh' "$db.log" && ok || bad "non-latest track refreshed: rc=$rc log=$(tr '\n' ';' <"$db.log")"
reconcile '{"snaps":[{"name":"node","channel":"edge","classic":true}]}' >/dev/null
grep -qx 'refresh node --channel=edge --classic' "$db.log" && ok || bad "real channel change not refreshed: $(tr '\n' ';' <"$db.log")"

# Declared strict, installed classic: snap cannot switch in place, so the
# reconciler refuses loudly and leaves it alone; the rest still happen (#13 C2).
printf 'code latest/stable classic\n' >"$db"
reconcile '{"snaps":[{"name":"code","channel":"stable","classic":false},{"name":"hello-world","channel":"stable","classic":false}]}' >/dev/null 2>"$work/rec.err"; rc=$?
[ $rc -eq 1 ] && grep -q 'code is installed with classic confinement but declared strict' "$work/rec.err" &&
  ! grep -Eq '^(install|refresh|remove.*) .*code' "$db.log" && grep -q '^hello-world ' "$db" && ok ||
  bad "classic->strict: rc=$rc err=$(cat "$work/rec.err") log=$(tr '\n' ';' <"$db.log")"
# Declared classic on a strict snap is a normal steady state: no refusal, no refresh.
reconcile '{"snaps":[{"name":"code","channel":"stable","classic":true},{"name":"hello-world","channel":"stable","classic":true}]}' >/dev/null 2>"$work/rec.err"; rc=$?
[ $rc -eq 0 ] && ! grep -Eq '^(install|refresh)' "$db.log" && ok || bad "classic on strict: rc=$rc err=$(cat "$work/rec.err") log=$(tr '\n' ';' <"$db.log")"

# The CLI refuses the same change up front, and leaves the file alone.
rm -f "$NIXARCHY_FLATSNAP_FILE"
PATH="$work/fakebin:$PATH" run add snap code --classic >/dev/null; cp "$NIXARCHY_FLATSNAP_FILE" "$work/before"
out=$(PATH="$work/fakebin:$PATH" run add snap code); rc=$?
[ $rc -eq 2 ] && jq -e '.error | test("classic confinement")' <<<"$out" >/dev/null && cmp -s "$work/before" "$NIXARCHY_FLATSNAP_FILE" && ok ||
  bad "add strict over installed classic: rc=$rc $out"
check "strict add of an installed strict snap" 'map(.id) | index("hello-world") != null' env PATH="$work/fakebin:$PATH" bash "$cli" add snap hello-world

# ---- preflight / apply, with nix, nixarchy-apply and flatpak stubbed ------
ab="$work/applybin"; mkdir -p "$ab"
stub() { printf '#!/bin/sh\n%s\n' "$2" >"$ab/$1"; chmod +x "$ab/$1"; }
# Like the real one: copies flatsnap.nix from where it reads it (line 117).
stub nixarchy-apply '# copies apps services advanced flatsnap
flake="${NIXARCHY_FLAKE:-/srv/their-flake}"
echo invoked >>"$APPLY_LOG"
f="$XDG_CONFIG_HOME/nixarchy/flatsnap.nix"; [ ! -f "$f" ] || cp "$f" "$COPIED"
echo "elevation=$NH_ELEVATION_STRATEGY" >"$ELEV_LOG"
printf "\033[1mbuilding\033[0m\\n50%%\\r100%%\\n"; exit ${APPLY_RC:-0}'
stub flatpak 'printf "org.gnome.Calculator\\ncom.byhand.App\\n"'
stub nix 'echo "$3" >"$NIX_LOG"; echo "$NIX_EVAL_ANSWER"'
stub sudo 'exit ${SUDO_RC:-1}'
# The unit apply starts: never the real systemd tools (tests/isolate.sh).
# systemd-run runs the unit's command at once, as the unit would, with its
# --setenv values and an INVOCATION_ID. Its output is the unit's journal and
# its exit code the unit's ExecMainStatus. Through bash, not exec: the
# sandbox has no /usr/bin/env for the CLI's shebang.
sdrun='echo "$*" >>"$SDRUN_LOG"
[ "${SDRUN_RC:-0}" -eq 0 ] || { echo "Failed to start transient service unit" >&2; exit "$SDRUN_RC"; }
envs=""; while [ "$1" != -- ]; do case $1 in --setenv=*) envs="$envs ${1#--setenv=}" ;; esac; shift; done; shift
[ -z "${SNEAK:-}" ] || printf "%s\n" "$SNEAK" >"$XDG_CONFIG_HOME/nixarchy/flatsnap.nix"
env INVOCATION_ID=0123456789abcdef0123456789abcdef $envs bash "$@" >"$JOURNAL" 2>&1; echo $? >"$UNIT_RC"'
stub systemd-run "$sdrun"
# systemctl show answers from $UNIT_FIXTURE (KEY=VALUE lines); stop and
# reset-failed are only logged.
stub systemctl 'echo "$*" >>"$SYSTEMCTL_LOG"
[ "$2" = show ] || exit 0
props=""; value=""
while [ $# -gt 0 ]; do case $1 in -p) props=$2; shift ;; --value) value=1 ;; esac; shift; done
for k in $(echo "$props" | tr , " "); do
  v=$(grep "^$k=" "$UNIT_FIXTURE" | cut -d= -f2-)
  if [ -n "$value" ]; then echo "$v"; else echo "$k=$v"; fi
done'
stub journalctl 'echo "$*" >>"$JOURNALCTL_LOG"; cat "$JOURNAL_FIXTURE"'
export NIX_LOG="$work/nix.log" ELEV_LOG="$work/elev.log" APPLY_LOG="$work/apply.log" COPIED="$work/copied.nix"
export SDRUN_LOG="$work/sdrun.log" SYSTEMCTL_LOG="$work/systemctl.log" JOURNALCTL_LOG="$work/journalctl.log"
export JOURNAL="$work/journal" UNIT_RC="$work/unit.rc" UNIT_FIXTURE="$work/unit" JOURNAL_FIXTURE="$work/journal.fixture"
export XDG_STATE_HOME="$work/state"
# unit <SubState> <Result> <ExecMainStatus> <InvocationID>: what systemctl show says.
unit() { printf 'SubState=%s\nResult=%s\nExecMainStatus=%s\nInvocationID=%s\n' "$@" >"$UNIT_FIXTURE"; }
unit dead success 0 ""
: >"$JOURNAL_FIXTURE"
# Hermetic: a developer's own shell may export these (nixarchy sets
# NIXARCHY_FLAKE), and they would silently decide the tests below.
unset NIXARCHY_FLAKE NH_ELEVATION_STRATEGY INVOCATION_ID
# The file nixarchy-apply copies, with no override: the CLI and the stub agree.
export XDG_CONFIG_HOME="$work/config"; unset NIXARCHY_FLATSNAP_FILE
# Nothing below may reach the real nixarchy-apply: only the stubs and these
# tools are on PATH, and the file stops here if that is not so.
# shellcheck source=tests/isolate.sh disable=SC1091
. "$here/isolate.sh"
P=$(isolated_path "$ab" "$work/tools" bash jq nix-instantiate awk sed grep sha256sum cut \
  mktemp cat cp mv rm mkdir dirname uname tr head flock sort readlink env) || { echo "ABORT: could not build the test PATH" >&2; exit 1; }
assert_isolated "$P" "$ab"
pa() { env PATH="$P" bash "$cli" "$@"; }

export NIX_EVAL_ANSWER='{"hasModule":true,"uninstallUnmanaged":false,"declared":["org.gnome.Calculator"]}'
check "preflight ready" '.ok and .willRemove == []' pa preflight
# The flake preflight evaluates is the one nixarchy-apply falls back to, not /etc/nixos.
grep -q '^/srv/their-flake#' "$NIX_LOG" && ok || bad "preflight evaluated $(cat "$NIX_LOG"), not nixarchy-apply's flake"
NIXARCHY_FLAKE=/tmp/override pa preflight >/dev/null
grep -q '^/tmp/override#' "$NIX_LOG" && ok || bad "NIXARCHY_FLAKE not honoured: $(cat "$NIX_LOG")"
# Elevation: pkexec unless sudo needs no password; an explicit choice wins.
pa apply >/dev/null; grep -qx 'elevation=pkexec' "$ELEV_LOG" && ok || bad "default elevation: $(cat "$ELEV_LOG")"
SUDO_RC=0 pa apply >/dev/null; grep -qx 'elevation=passwordless' "$ELEV_LOG" && ok || bad "NOPASSWD sudo: $(cat "$ELEV_LOG")"
SUDO_RC=0 NH_ELEVATION_STRATEGY=run0 pa apply >/dev/null; grep -qx 'elevation=run0' "$ELEV_LOG" && ok || bad "explicit elevation: $(cat "$ELEV_LOG")"
NIX_EVAL_ANSWER='{"hasModule":true,"uninstallUnmanaged":true,"declared":["org.gnome.Calculator"]}' \
  check "preflight lists what uninstallUnmanaged removes" '.willRemove == ["com.byhand.App"]' pa preflight
out=$(NIX_EVAL_ANSWER='{"hasModule":false,"uninstallUnmanaged":false,"declared":[]}' pa apply); rc=$?
[ $rc -eq 2 ] && jq -e '.error | test("nixosModules.default")' <<<"$out" >/dev/null && ok || bad "apply without module: rc=$rc $out"

# The build runs in the unit (#23): its log is the unit's journal, and the
# launcher's last line says which invocation to follow.
out=$(pa apply); rc=$?
[ $rc -eq 0 ] && [ "$(sed -n 1p "$JOURNAL")" = building ] && [ "$(sed -n 2p "$JOURNAL")" = 100% ] &&
  jq -e '.nixarchyFlatsnapApply.ok' <<<"$(tail -1 "$JOURNAL")" >/dev/null &&
  jq -e '.nixarchyFlatsnapStarted.invocationId == ""' <<<"$(tail -1 <<<"$out")" >/dev/null &&
  ok || bad "apply stream: rc=$rc out=$out journal=$(cat "$JOURNAL")"
APPLY_RC=3 pa apply >/dev/null
jq -e '.nixarchyFlatsnapApply == {ok:false,exit:3,message:"nixarchy-apply exited 3"}' <<<"$(tail -1 "$JOURNAL")" >/dev/null &&
  [ "$(cat "$UNIT_RC")" = 3 ] && ok || bad "apply failure: rc=$(cat "$UNIT_RC") $(cat "$JOURNAL")"

# A nixarchy-apply with no flake= line: fall back to /etc/nixos, and say so on
# stderr only, so the panel still gets clean JSON on stdout.
stub nixarchy-apply 'exit 0'
out=$(pa preflight 2>"$work/err"); rc=$?
[ $rc -eq 0 ] && jq -e '.ok' <<<"$out" >/dev/null && grep -q 'could not read the flake path' "$work/err" &&
  grep -q '^/etc/nixos#' "$NIX_LOG" && ok || bad "flake fallback: rc=$rc out=$out err=$(cat "$work/err") nix=$(cat "$NIX_LOG")"

# A flatpak that fails: preflight cannot say what apply would remove, so it
# refuses rather than report nothing (#13 C8).
stub flatpak 'exit 1'
out=$(pa preflight); rc=$?
[ $rc -eq 2 ] && jq -e '.error | test("could not list installed Flatpaks")' <<<"$out" >/dev/null && ok || bad "preflight on failing flatpak: rc=$rc $out"

# ---- #10: apply builds only the checked state ----------------------------
stub flatpak 'printf "org.gnome.Calculator\\ncom.byhand.App\\n"'
stub nixarchy-apply '# copies apps services advanced flatsnap
echo invoked >>"$APPLY_LOG"
f="$XDG_CONFIG_HOME/nixarchy/flatsnap.nix"; [ ! -f "$f" ] || cp "$f" "$COPIED"
printf "building\\n"; exit ${APPLY_RC:-0}'
fsn="$XDG_CONFIG_HOME/nixarchy/flatsnap.nix"
export NIX_EVAL_ANSWER='{"hasModule":true,"uninstallUnmanaged":false,"declared":[],"current":{"flatpaks":[{"appId":"org.old.App","overrides":{}}],"snaps":[{"name":"code","channel":"stable","classic":false}]}}'

# 8: preflight says what changes since the flake's copy, and hashes the state.
rm -f "$fsn"; pa add flatpak org.new.App >/dev/null; pa add snap code --channel edge >/dev/null
check "preflight changes" '.changes == [
    {op:"add",store:"flatpak",id:"org.new.App",detail:""},
    {op:"remove",store:"flatpak",id:"org.old.App",detail:""},
    {op:"change",store:"snap",id:"code",detail:"channel stable → edge"}]
  and (.stateHash | test("^[0-9a-f]{64}$"))' pa preflight

# refused <description> <jq test on .error> [env...] -- apply refuses: exit 2,
# exactly one {"error"} line, and the stub nixarchy-apply never ran.
refused() {
  local d=$1 t=$2 out rc; shift 2
  : >"$APPLY_LOG"
  out=$(env "$@" PATH="$P" bash "$cli" apply "${APPLY_ARGS[@]}"); rc=$?
  [ $rc -eq 2 ] && [ "$(wc -l <<<"$out")" -eq 1 ] && jq -e ".error | $t" <<<"$out" >/dev/null && [ ! -s "$APPLY_LOG" ] &&
    ok || bad "$d: rc=$rc apply.log=$(cat "$APPLY_LOG") -> $out"
}
APPLY_ARGS=()

# 1: a file outside the shape is refused, untouched, before nixarchy-apply.
for foreign in '{ config, ... }: { }' '{ services.foo.enable = true; programs.nixarchy.flatsnap.snaps = [ ]; }'; do
  printf '%s\n' "$foreign" >"$fsn"
  refused "foreign shape" 'test("not in the shape")'
  [ "$(cat "$fsn")" = "$foreign" ] && ok || bad "foreign shape rewritten by apply: $(cat "$fsn")"
done
# 2: inside the shape, an entry outside add's grammar is refused, and named.
printf '{ programs.nixarchy.flatsnap = { snaps = [ { name = "Bad_Name"; } ]; }; }\n' >"$fsn"
refused "bad entry" 'test("Bad_Name")'
# 3: what nixarchy-apply copies is the regenerated file, not the hand edit.
printf '{ programs.nixarchy.flatsnap = { flatpaks = [ { appId = "org.a.B"; extra = "x"; } ]; }; }\n' >"$fsn"
rm -f "$COPIED"; out=$(pa apply); rc=$?
[ $rc -eq 0 ] && cmp -s "$COPIED" "$fsn" && grep -q 'appId = "org.a.B"' "$COPIED" && ! grep -q extra "$COPIED" &&
  ok || bad "regenerate before copy: rc=$rc copied=$(cat "$COPIED" 2>&1) -> $out journal=$(cat "$JOURNAL")"
# 4: apply does not prune pendingRemoval, even when snap lists nothing.
printf '{ programs.nixarchy.flatsnap = { pendingRemoval = [ "x" ]; }; }\n' >"$fsn"
stub snap 'printf "Name Version\\n"'
rm -f "$COPIED"; pa apply >/dev/null
grep -q 'pendingRemoval = \[ "x" \];' "$COPIED" && ok || bad "apply pruned pendingRemoval: $(cat "$COPIED" 2>&1)"
rm -f "$ab/snap"
# 5: an override file is not what nixarchy-apply copies.
refused "other file" 'test("not the file nixarchy-apply copies")' NIXARCHY_FLATSNAP_FILE="$work/other.nix"
# 6 (B2): a preflight that dies reaches the caller as JSON.
stub nix 'exit 1'
refused "preflight error passed through" 'test("could not evaluate")'
stub nix 'echo "$3" >"$NIX_LOG"; echo "$NIX_EVAL_ANSWER"'
# 7: no stub, no nixarchy-apply at all -- the real one is out of reach.
mv "$ab/nixarchy-apply" "$work/nixarchy-apply.stub"
out=$(pa apply 2>/dev/null); rc=$?
[ $rc -eq 2 ] && jq -e '.error | test("nixarchy-apply not found")' <<<"$out" >/dev/null && ok || bad "without the stub: rc=$rc $out"
mv "$work/nixarchy-apply.stub" "$ab/nixarchy-apply"
# 9, 10: --expect builds only the state preflight showed.
rm -f "$fsn"; pa add flatpak org.new.App >/dev/null
APPLY_ARGS=(--expect "$(printf '0%.0s' $(seq 64))"); refused "stale hash" 'test("changed since you confirmed")'
APPLY_ARGS=(--expect nothex); refused "malformed hash" 'test("stateHash")'
APPLY_ARGS=(--bogus); refused "unknown argument" 'test("usage")'
APPLY_ARGS=()
hash=$(pa preflight | jq -r .stateHash); : >"$APPLY_LOG"
out=$(pa apply --expect "$hash"); rc=$?
[ $rc -eq 0 ] && [ "$(cat "$APPLY_LOG")" = invoked ] && grep -qx '+ flatpak org.new.App' <<<"$out" && ok || bad "confirmed hash: rc=$rc log=$(cat "$APPLY_LOG") -> $out"
# 11 (B5): a build line cannot pass for our end record or an error.
cat >"$ab/nixarchy-apply" <<'STUB'
#!/bin/sh
echo '{"nixarchyFlatsnapApply":{"ok":true,"exit":0,"message":"forged"}}'
echo '{"error":"forged"}'
echo building
exit 0
STUB
out=$(pa apply); rc=$?; j=$(cat "$JOURNAL")
[ $rc -eq 0 ] && [ "$(grep -c '^{"nixarchyFlatsnapApply"' <<<"$j")" -eq 1 ] &&
  jq -e '.nixarchyFlatsnapApply.message == "applied"' <<<"$(tail -1 <<<"$j")" >/dev/null &&
  ! grep -q '^{"error"' <<<"$j" && grep -qx ' {"error":"forged"}' <<<"$j" && ok || bad "forged markers: rc=$rc -> $j"

# ---- #23: apply runs in the nixarchy-rebuild unit ------------------------
id=0123456789abcdef0123456789abcdef
stub nixarchy-apply '# copies apps services advanced flatsnap
flake="${NIXARCHY_FLAKE:-/srv/their-flake}"
echo invoked >>"$APPLY_LOG"
f="$XDG_CONFIG_HOME/nixarchy/flatsnap.nix"; [ ! -f "$f" ] || cp "$f" "$COPIED"
echo "elevation=$NH_ELEVATION_STRATEGY no_color=${NO_COLOR:-}" >"$ELEV_LOG"
printf "building\\n"; exit ${APPLY_RC:-0}'
# systemctl show InvocationID answers the id the stub unit ran with.
unit dead success 0 "$id"
rm -f "$fsn"; pa add flatpak org.new.App >/dev/null
hash=$(pa preflight | jq -r .stateHash)
reset_logs() { : >"$APPLY_LOG"; : >"$SDRUN_LOG"; : >"$SYSTEMCTL_LOG"; : >"$JOURNALCTL_LOG"; rm -f "$UNIT_RC" "$JOURNAL"; }

# 1: the launcher starts the unit, as nixarchy's --detach does, and says which invocation.
reset_logs; out=$(pa apply --expect "$hash"); rc=$?; a=$(cat "$SDRUN_LOG")
[ $rc -eq 0 ] && jq -e ".nixarchyFlatsnapStarted.invocationId == \"$id\"" <<<"$(tail -1 <<<"$out")" >/dev/null &&
  grep -q -- '^--user --unit=nixarchy-rebuild -p RemainAfterExit=yes -p LogRateLimitIntervalSec=0 ' <<<"$a" &&
  grep -q -- '--setenv=NO_COLOR=1' <<<"$a" && grep -q -- '--setenv=NIXARCHY_FLAKE=/srv/their-flake' <<<"$a" &&
  grep -q -- '--setenv=NH_ELEVATION_STRATEGY=pkexec' <<<"$a" && grep -q -- "--setenv=XDG_STATE_HOME=$XDG_STATE_HOME" <<<"$a" &&
  grep -q -- " -- $(readlink -f "$cli") apply --in-unit --expect $hash\$" <<<"$a" &&
  [ "$(cat "$APPLY_LOG")" = invoked ] && [ "$(cat "$UNIT_RC")" = 0 ] &&
  grep -qx 'elevation=pkexec no_color=1' "$ELEV_LOG" && ok || bad "unit start: rc=$rc out=$out sdrun=$a elev=$(cat "$ELEV_LOG")"
# 9: the run writes its own marker.
[ "$(cat "$XDG_STATE_HOME/nixarchy-flatsnap/apply" 2>&1)" = "$id new" ] && ok || bad "marker: $(cat "$XDG_STATE_HOME/nixarchy-flatsnap/apply" 2>&1)"
# A terminal apply with no --expect is pinned to the state it just checked.
reset_logs; pa apply >/dev/null 2>&1
grep -q -- "apply --in-unit --expect $hash\$" "$SDRUN_LOG" && ok || bad "terminal pin: $(cat "$SDRUN_LOG")"

# 2: a rebuild already running: exit 3, one {"error"} line, nothing started.
for sub in running start-pre; do
  unit "$sub" success 0 "$id"; reset_logs
  out=$(pa apply --expect "$hash"); rc=$?
  [ $rc -eq 3 ] && [ "$(wc -l <<<"$out")" -eq 1 ] && jq -e '.error | test("already running")' <<<"$out" >/dev/null &&
    [ ! -s "$SDRUN_LOG" ] && [ ! -s "$APPLY_LOG" ] && ok || bad "already running ($sub): rc=$rc $out"
done
# 3: a finished unit is stopped and reset before the new start.
for sub in failed exited; do
  unit "$sub" exit-code 1 "$id"; reset_logs; pa apply --expect "$hash" >/dev/null
  [ "$(grep -E '^--user (stop|reset-failed) ' "$SYSTEMCTL_LOG" | tr '\n' ';')" = "--user stop nixarchy-rebuild;--user reset-failed nixarchy-rebuild;" ] &&
    [ -s "$SDRUN_LOG" ] && ok || bad "reset finished ($sub): $(cat "$SYSTEMCTL_LOG")"
done
unit dead success 0 "$id"
# 4: systemd-run failing (lost a race): exit 3, the error last.
reset_logs; out=$(SDRUN_RC=1 pa apply --expect "$hash"); rc=$?
[ $rc -eq 3 ] && jq -e '.error | test("could not start")' <<<"$(tail -1 <<<"$out")" >/dev/null &&
  [ ! -s "$APPLY_LOG" ] && ok || bad "systemd-run failed: rc=$rc $out"

# in_unit <args...>: the unit's own run, as systemd starts it.
in_unit() { env PATH="$P" INVOCATION_ID="$id" NO_COLOR=1 bash "$cli" apply --in-unit "$@"; }
# 5: a stale hash in the unit: exit 2, nothing copied or built.
reset_logs; rm -f "$COPIED"; out=$(in_unit --expect "$(printf '0%.0s' $(seq 64))" 2>&1); rc=$?
[ $rc -eq 2 ] && grep -q 'changed since you confirmed' <<<"$out" && [ ! -s "$APPLY_LOG" ] && [ ! -e "$COPIED" ] &&
  ok || bad "in-unit stale hash: rc=$rc $out"
# 6: an edit between the launcher and the unit is refused in the unit.
reset_logs; rm -f "$COPIED"
SNEAK='{ programs.nixarchy.flatsnap = { flatpaks = [ { appId = "org.sneaked.In"; } ]; }; }' pa apply --expect "$hash" >/dev/null
[ "$(cat "$UNIT_RC")" = 2 ] && grep -q 'changed since you confirmed' "$JOURNAL" && [ ! -s "$APPLY_LOG" ] && [ ! -e "$COPIED" ] &&
  ok || bad "gap edit: rc=$(cat "$UNIT_RC") $(cat "$JOURNAL")"
rm -f "$fsn"; pa add flatpak org.new.App >/dev/null
# 7: the unit's exit code is nixarchy-apply's.
reset_logs; APPLY_RC=4 in_unit --expect "$hash" >/dev/null 2>&1; rc=$?
[ $rc -eq 4 ] && ok || bad "in-unit exit: $rc"
# 8: --in-unit needs --expect and a unit's INVOCATION_ID.
reset_logs; env PATH="$P" bash "$cli" apply --in-unit --expect "$hash" >/dev/null 2>&1; rc=$?
[ $rc -eq 2 ] && [ ! -s "$APPLY_LOG" ] && ok || bad "in-unit without INVOCATION_ID: $rc"
reset_logs; in_unit >/dev/null 2>&1; rc=$?
[ $rc -eq 2 ] && [ ! -s "$APPLY_LOG" ] && ok || bad "in-unit without --expect: $rc"

# 10, 11: apply-status reads the unit, never Result alone.
st() { pa apply-status "$@"; }
mkdir -p "$XDG_STATE_HOME/nixarchy-flatsnap"; printf '%s\n' "$id new" >"$XDG_STATE_HOME/nixarchy-flatsnap/apply"
unit dead success 0 "";               check "status dead" '.state == "none"' st
unit "" success 0 "";                 check "status no unit" '.state == "none"' st
unit exited success 0 "";             check "status no invocation" '.state == "none"' st
unit running success 0 "$id";         check "status running" '.state == "running" and .invocationId == "'"$id"'" and .ours and (.shown | not)' st
unit start-pre success 0 "$id";       check "status starting" '.state == "running"' st
unit exited success 0 "$id";          check "status succeeded" '.state == "succeeded" and .exit == 0 and .ours' st
unit failed exit-code 4 "$id";        check "status failed" '.state == "failed" and .exit == 4 and .result == "exit-code"' st
unit exited exit-code 1 "$id";        check "status exited, not success" '.state == "failed"' st
unit exited success 0 fedcba9876543210fedcba9876543210
check "status of a run not ours" '.ours | not' st
# 12: --ack marks our run shown, and only ours.
unit exited success 0 "$id"
st --ack fedcba9876543210fedcba9876543210 >/dev/null
[ "$(cat "$XDG_STATE_HOME/nixarchy-flatsnap/apply")" = "$id new" ] && ok || bad "ack of another id changed the marker"
st --ack "$id" >/dev/null; check "status shown" '.shown and .ours' st
out=$(st --ack xyz); rc=$?
[ $rc -eq 2 ] && jq -e '.error' <<<"$out" >/dev/null && ok || bad "ack garbage: rc=$rc $out"
rm -f "$XDG_STATE_HOME/nixarchy-flatsnap/apply"; check "status without a marker" '(.ours | not) and (.shown | not)' st

# 13, 14: apply-log reads this invocation's lines only.
printf 'line 1\nline 2\n' >"$JOURNAL_FIXTURE"; : >"$JOURNALCTL_LOG"
out=$(pa apply-log "$id" --follow)
[ "$out" = "$(printf 'line 1\nline 2')" ] &&
  grep -qx -- "--user -u nixarchy-rebuild --invocation=$id -o cat --no-pager -n 2000 -f" "$JOURNALCTL_LOG" && ok ||
  bad "apply-log --follow: $out $(cat "$JOURNALCTL_LOG")"
: >"$JOURNALCTL_LOG"; pa apply-log >/dev/null
grep -qx -- "--user -u nixarchy-rebuild --invocation=$id -o cat --no-pager -n 2000" "$JOURNALCTL_LOG" && ok ||
  bad "apply-log defaults to the unit's invocation: $(cat "$JOURNALCTL_LOG")"
: >"$JOURNALCTL_LOG"; out=$(pa apply-log ../x); rc=$?
[ $rc -eq 2 ] && [ ! -s "$JOURNALCTL_LOG" ] && ok || bad "apply-log ../x: rc=$rc $out"

printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
