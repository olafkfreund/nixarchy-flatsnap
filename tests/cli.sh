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
# fixtures/flathub-search.json is search_flathub's default fixture; it matches
# flathub-search-calculator.json (resolve's, by ID) on purpose. Both are used.
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
stub nixarchy-apply '# copies apps services advanced flatsnap
flake="${NIXARCHY_FLAKE:-/srv/their-flake}"
echo "elevation=$NH_ELEVATION_STRATEGY" >"$ELEV_LOG"
printf "\033[1mbuilding\033[0m\\n50%%\\r100%%\\n"; exit ${APPLY_RC:-0}'
stub flatpak 'printf "org.gnome.Calculator\\ncom.byhand.App\\n"'
stub nix 'echo "$3" >"$NIX_LOG"; echo "$NIX_EVAL_ANSWER"'
stub sudo 'exit ${SUDO_RC:-1}'
export NIX_LOG="$work/nix.log" ELEV_LOG="$work/elev.log"
# Hermetic: a developer's own shell may export these (nixarchy sets
# NIXARCHY_FLAKE), and they would silently decide the tests below.
unset NIXARCHY_FLAKE NH_ELEVATION_STRATEGY
pa() { env PATH="$ab:$PATH" bash "$cli" "$@"; }

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

out=$(pa apply); rc=$?
[ $rc -eq 0 ] && [ "$(sed -n 1p <<<"$out")" = building ] && [ "$(sed -n 2p <<<"$out")" = 100% ] &&
  jq -e '.nixarchyFlatsnapApply.ok' <<<"$(tail -1 <<<"$out")" >/dev/null && ok || bad "apply stream: $out"
out=$(APPLY_RC=3 pa apply)
jq -e '.nixarchyFlatsnapApply == {ok:false,exit:3,message:"nixarchy-apply exited 3"}' <<<"$(tail -1 <<<"$out")" >/dev/null && ok || bad "apply failure: $out"

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

printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
