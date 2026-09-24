# shellcheck shell=bash
# Sourced by tests/cli.sh and tests/model.sh before anything that can reach
# `nixarchy-flatsnap apply`. The real nixarchy-apply rebuilds and switches
# the machine the tests run on, so the PATH those tests use holds only a
# stubs directory and links to the store paths of the tools named -- never
# /run/current-system, /run/wrappers or /etc/profiles. A missing stub is then
# "not found", not a real rebuild.

# isolated_path <stubs> <tools-dir> <tool>... : prints the PATH to use.
isolated_path() {
  local stubs=$1 tools=$2 t p
  shift 2
  mkdir -p "$tools"
  for t in "$@"; do
    p=$(command -v "$t") || { echo "isolate: $t not found" >&2; return 1; }
    ln -sf "$(readlink -f "$p")" "$tools/$t"
  done
  printf '%s:%s' "$stubs" "$tools"
}

# assert_isolated <PATH> <stub nixarchy-apply> : exits the calling test file,
# not just the case, unless nixarchy-apply is the stub, no PATH directory is
# a system one, and every link in them points into /nix/store directly.
# /usr/bin and /bin count as system: with envfs, /usr/bin/<anything> exists
# and runs whatever the caller's PATH would -- the real nixarchy-apply too.
assert_isolated() {
  local path=$1 want=$2 got dir f p
  got=$(PATH=$path; command -v nixarchy-apply) || got=""
  [ "$got" = "$want" ] || { echo "ABORT: nixarchy-apply is '$got' on the test PATH, not the stub $want" >&2; exit 1; }
  local IFS=:
  for dir in $path; do
    for p in "$dir" "$(readlink -f "$dir")"; do
      case $p in
        /run/*|/etc/*|/usr/*|/bin|/bin/*|/sbin|/sbin/*|/nix/var/*|*/.nix-profile*|*/.local/state/nix/*)
          echo "ABORT: $dir on the test PATH is a system directory ($p)" >&2; exit 1 ;;
      esac
    done
    for f in "$dir"/*; do
      [ -L "$f" ] || continue
      for p in "$(readlink "$f")" "$(readlink -f "$f")"; do
        case $p in
          /nix/store/*) ;;
          *) echo "ABORT: $f on the test PATH points at $p, not into /nix/store" >&2; exit 1 ;;
        esac
      done
    done
  done
}
