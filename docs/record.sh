#!/usr/bin/env bash
# docs/record.sh -- record the showcase GIFs and stills on a nixarchy desktop.
#
# Runs ON the test machine, from outside its session (ssh), and drives the
# real panel with wtype:
#
#   ssh razer 'START_GEN=<gen> bash -s -- [--dry-run]' < docs/record.sh
#   ssh razer 'OUT=<a take> bash -s -- --encode-only' < docs/record.sh
#
#   --dry-run      print every step; write, fetch and switch nothing
#   --encode-only  re-encode and re-gate the take in $OUT; needs no session
#   OUT            where the take goes (default: a new mktemp -d, printed)
#   NIXARCHY_SRC   a nixarchy tree with tests/demo (default: NIXARCHY_REV,
#                  fetched)
#
# Before it (plan/2026-09-23-5-showcase.md, step 2): a generation that ships
# the plugin is active through `switch-to-configuration test`, its
# programs.nixarchy.flake points at a throwaway clone (so apply never writes
# the machine's real configuration), and the plugin is enabled. START_GEN is
# the generation to go back to; the trap goes back to it however this ends.
#
# Out: $OUT/flatsnap-{flatpak,snap,apply}.gif (each gated by nixarchy's own
# verify-frames.sh) and $OUT/NN-*.webp stills. Nothing is copied into a
# repository from here.
set -euo pipefail

# nixarchy's encode-gif.sh and verify-frames.sh, pinned: a gate that changes
# under a re-take is a different gate. Bump on purpose.
NIXARCHY_REV=c0ed067ec2c952d8ee94df3e69b0a59900585c69

say() { printf '== %s\n' "$*" >&2; }
die() { printf 'record.sh: %s\n' "$*" >&2; exit 1; }

DRY=0 ENCODE_ONLY=0
case "${1:-}" in
  "") ;;
  --dry-run) DRY=1 ;;
  # Re-encode and re-gate an existing take in $OUT, without recording again.
  --encode-only) ENCODE_ONLY=1 ;;
  # A typo must not start a real take.
  *) die "usage: [START_GEN=<gen>] [OUT=<dir>] record.sh [--dry-run | --encode-only]" ;;
esac
[ "$ENCODE_ONLY" = 1 ] || : "${START_GEN:?START_GEN: the system generation to return to}"
if [ "$ENCODE_ONLY" = 1 ]; then
  [ -n "${OUT:-}" ] || die "--encode-only needs OUT=<the take's directory>"
elif [ "$DRY" = 1 ]; then
  OUT=${OUT:-"<a new mktemp -d>"}
else
  # Private and unpredictable, not a fixed name in the shared /tmp.
  OUT=${OUT:-$(mktemp -d -t flatsnap-media.XXXXXX)}
fi
say "out: $OUT"
PANEL=nixarchy.flatsnap
PROFILE=/nix/var/nix/profiles/system
FS_FILE="$HOME/.config/nixarchy/flatsnap.nix"
CLI="$HOME/.config/omarchy/plugins/$PANEL/bin/nixarchy-flatsnap"
# The largest 16:10 region of a 1920x1080 screen: exactly 900x563 and
# 1280x800 when scaled, so nothing is cropped afterwards.
REGION_GRIM="96,0 1728x1080"
REGION_GSR="1728x1080+96+0"

run() { if [ "$DRY" = 1 ]; then printf 'would: %s\n' "$*"; else "$@"; fi; }
hold() { run sleep "$1"; }
keys() { run wtype -d 40 "$@"; }
# Hyprland's Lua dispatch first, the old form second -- the way Omarchy's own
# scripts do it; the old form alone is a parse error on a Lua config.
workspace() { run hyprctl dispatch "hl.dsp.focus({ workspace = \"$1\" })" >/dev/null 2>&1 ||
  run hyprctl dispatch workspace "$1"; }

# ---- encode and gate ------------------------------------------------------
# Everything here reads /dev/null, not stdin: this script arrives on stdin
# (`bash -s`), and ffmpeg reading it swallowed the rest of the script once
# ("bash" arrived as "ash").
encode_and_gate() {
  if [ "$DRY" = 1 ]; then
    say "would fetch github:olafkfreund/nixarchy/$NIXARCHY_REV, encode the scene GIFs and stills, and gate them"
    return
  fi
  NIXARCHY_SRC=${NIXARCHY_SRC:-$(nix flake prefetch --json "github:olafkfreund/nixarchy/$NIXARCHY_REV" | jq -r .storePath)}
  [ -f "$NIXARCHY_SRC/tests/demo/encode-gif.sh" ] || die "no encode-gif.sh under $NIXARCHY_SRC"

  # Stills first: a gate that fails still leaves them to look at.
  local f name
  for f in "$OUT"/raw-*.png; do
    [ -e "$f" ] || continue
    name=$(basename "$f" .png)
    run magick "$f" -resize 1280x800 -quality 85 "$OUT/${name#raw-}.webp"
  done

  # One take, three scene GIFs. nixarchy's gate caps a GIF at 1 MB and says
  # to cut the scene rather than degrade the encoding; the whole take came to
  # 4.1 MB. Each range comes from scenes.tsv; the build logs keep their first
  # 3 s and last ~2 s (the captions say "build log shortened").
  s_of() { awk -F'\t' -v s="$1" '$2 == s { printf "%.2f", $1 / 1000; exit }' "$OUT/scenes.tsv"; }
  local open snap apply applied calc d_apply
  open=$(s_of open); snap=$(s_of snap-search); apply=$(s_of apply)
  applied=$(s_of applied); calc=$(s_of calculator)
  d_apply=$(awk -v a="$apply" -v b="$applied" 'BEGIN { printf "%.2f", b - a - 2 }')

  scene_gif() { # name from to [cut_from cut_to] -- times in seconds
    local n=$1 from=$2 to=$3 vf
    vf="trim=$from:$to,setpts=PTS-STARTPTS"
    [ $# -gt 3 ] && vf+=",select='not(between(t,$4,$5))',setpts=N/FRAME_RATE/TB"
    run rm -rf "$OUT/frames-$n" "$OUT/flatsnap-$n.gif"
    run mkdir -p "$OUT/frames-$n"
    run ffmpeg -nostdin -hide_banner -loglevel error -i "$OUT/raw.mp4" \
      -vf "$vf,fps=4,mpdecimate" -fps_mode vfr "$OUT/frames-$n/%04d.png"
    run bash "$NIXARCHY_SRC/tests/demo/encode-gif.sh" "$OUT/frames-$n" "$OUT/flatsnap-$n.gif"
  }
  scene_gif flatpak "$open" "$snap"
  scene_gif snap "$snap" "$apply"
  # Ends half a second before the panel closes for the Calculator: that
  # frame repaints the whole desktop and costs more than it shows.
  local calc_end
  calc_end=$(awk -v c="$calc" 'BEGIN { printf "%.2f", c - 0.5 }')
  scene_gif apply "$apply" "$calc_end" 3 "$d_apply"
  # Removal is stills (10, 11), not a GIF: it changes a line of text at a
  # time, and verify-frames rightly calls that a static recording.
  say "cut: apply log 3s-${d_apply}s"

  gate() { # gif, then --expect/--forbid pairs
    local g=$1; shift
    run bash "$NIXARCHY_SRC/tests/demo/verify-frames.sh" "$OUT/flatsnap-$g.gif" "$@" \
      --forbid 'error|failed|refused' --max-bytes 1000000 --dump "$OUT/verify-$g"
  }
  gate flatpak --expect Calculator --expect Flatpak
  gate snap --expect hello --expect confinement
  gate apply --expect installed
  say "done: $OUT/flatsnap-{flatpak,snap,apply}.gif and stills; look at every one before committing"
}

# Encoding needs ffmpeg and nixarchy's scripts, not the desktop.
if [ "$ENCODE_ONLY" = 1 ]; then
  [ -s "$OUT/raw.mp4" ] && [ -s "$OUT/scenes.tsv" ] || die "no take in $OUT to encode"
  encode_and_gate </dev/null
  exit
fi

# ---- the session's handles ------------------------------------------------
# ssh has none of them; the running shell does.
qs=$(pgrep -f quickshell-wrapped_ | head -1) || die "no omarchy-shell running"
while IFS= read -r kv; do export "${kv?}"; done < <(tr '\0' '\n' <"/proc/$qs/environ" |
  grep -E '^(WAYLAND_DISPLAY|HYPRLAND_INSTANCE_SIGNATURE|XDG_RUNTIME_DIR|OMARCHY_PATH|DBUS_SESSION_BUS_ADDRESS)=')

# ---- refuse anything but the clean starting state ------------------------
[ "$(readlink "$PROFILE")" = "system-$START_GEN-link" ] ||
  die "the system profile is $(readlink "$PROFILE"), not generation $START_GEN"
[ ! -e "$FS_FILE" ] || die "$FS_FILE exists: something is already declared"
nixarchy-plugin --enabled "$PANEL" || die "$PANEL is not enabled"
[ -x "$CLI" ] || die "$CLI missing: the plugin is not installed by this generation"
[ "$(omarchy-shell shell isOpen "$PANEL")" = false ] || die "the panel is open"

theme0=$(omarchy-theme-current)
bg0=$(readlink -f "$HOME/.local/state/omarchy/current/background")
dnd0=$(omarchy-shell notifications isDnd)
ws0=$(hyprctl activeworkspace -j | jq -r .id)
# An empty workspace: nothing translucent over the wallpaper, nothing private.
ws=$(hyprctl workspaces -j | jq -r '[.[] | select(.windows == 0) | .id] | max // empty')
[ -n "$ws" ] || die "no empty workspace to record on"
say "start: gen $START_GEN, theme '$theme0', bg $bg0, dnd $dnd0, workspace $ws0 -> $ws"

if [ "$DRY" = 0 ]; then
  mkdir -p "$OUT"
  : >"$OUT/scenes.tsv"
fi
rec_pid=""
# The generations this take created; the trap deletes these and no others.
made=()
gen_no() { readlink "$PROFILE" | sed -n 's/^system-\([0-9]*\)-link$/\1/p'; }
t0=0

cleanup() {
  local rc=$?
  set +e
  say "clean-up"
  [ -n "$rec_pid" ] && kill -INT "$rec_pid" 2>/dev/null && wait "$rec_pid" 2>/dev/null
  [ "$(omarchy-shell shell isOpen "$PANEL")" = true ] && run omarchy-shell shell toggle "$PANEL" '{}'
  run pkill -f gnome-calculator
  # Anything this run declared is un-declared and applied away, while the
  # generation that can do so is still the running one.
  if [ -e "$FS_FILE" ]; then
    for id in $("$CLI" list | jq -r '.[] | "\(.store):\(.id)"'); do
      run "$CLI" rm "${id%%:*}" "${id#*:}" >/dev/null
    done
    local before
    before=$(readlink "$PROFILE")
    run "$CLI" apply >/dev/null
    [ "$(readlink "$PROFILE")" = "$before" ] || made+=("$(gen_no)")
  fi
  run omarchy-theme-set "$theme0"
  run omarchy-theme-bg-set "$bg0"
  [ "$(omarchy-shell notifications isDnd)" = "$dnd0" ] || run omarchy-shell notifications toggleDnd
  workspace "$ws0"
  # Back to the generation this started on; drop only the ones this take
  # made. Someone else's generation from during the take is theirs to keep.
  local -a newer kept=()
  local g
  mapfile -t newer < <(find /nix/var/nix/profiles -maxdepth 1 -name 'system-*-link' -printf '%f\n' |
    sed -n 's/^system-\([0-9]*\)-link$/\1/p' | awk -v s="$START_GEN" '$1 > s')
  for g in "${newer[@]}"; do [[ " ${made[*]} " == *" $g "* ]] || kept+=("$g"); done
  run sudo nix-env -p "$PROFILE" --switch-generation "$START_GEN"
  run sudo "$PROFILE/bin/switch-to-configuration" switch
  [ ${#made[@]} -eq 0 ] || run sudo nix-env -p "$PROFILE" --delete-generations "${made[@]}"
  [ ${#kept[@]} -eq 0 ] || say "newer generations not made by this take were kept: ${kept[*]}"
  run sudo "$PROFILE/bin/switch-to-configuration" boot
  run rm -f "$FS_FILE" "$FS_FILE.bak" "$HOME/.local/state/nixarchy/enabled-once/$PANEL"
  say "left on $(readlink "$PROFILE")"
  # The trap's own last command must not decide the exit code: a take that
  # died reports that it died.
  exit "$rc"
}
trap cleanup EXIT

# ---- the desktop for the take --------------------------------------------
# Do Not Disturb first, or the theme change's own toast lands in the frame.
[ "$dnd0" = on ] || run omarchy-shell notifications toggleDnd
run omarchy-theme-set "Tokyo Night"
run omarchy-theme-bg-set "$OMARCHY_PATH/themes/tokyo-night/backgrounds/0-winding-road.jpg"
workspace "$ws"
hold 3

scene() {
  local ms=0
  if [ "$DRY" = 0 ]; then
    ms=$(($(date +%s%3N) - t0))
    printf '%s\t%s\n' "$ms" "$1" >>"$OUT/scenes.tsv"
  fi
  say "scene $1 @ ${ms}ms"
}
still() { run grim -g "$REGION_GRIM" "$OUT/raw-$1.png"; }
# The panel runs apply itself. Done means: a new system generation exists and
# no apply is left running. Watching for the process alone misses a cached
# build that finishes before the first look.
wait_apply() {
  [ "$DRY" = 1 ] && { say "would wait for apply"; return; }
  local before=$1
  for _ in $(seq 1 600); do
    if [ "$(readlink "$PROFILE")" != "$before" ] && ! pgrep -f 'nixarchy-flatsnap apply' >/dev/null; then
      made+=("$(gen_no)")
      return
    fi
    sleep 1
  done
  die "no new generation after 10 minutes (preflight refused? look at the panel)"
}

# ---- record -----------------------------------------------------------------
if [ "$DRY" = 1 ]; then
  say "would record: gpu-screen-recorder -w region -region $REGION_GSR -f 30 -cursor no -o $OUT/raw.mp4"
else
  gpu-screen-recorder -w region -region "$REGION_GSR" -f 30 -cursor no -o "$OUT/raw.mp4" &
  rec_pid=$!
  t0=$(date +%s%3N)
  sleep 2
fi

scene open
run omarchy-shell shell toggle "$PANEL" '{}'
hold 2; still 01-empty

scene flathub
keys 'https://flathub.org/apps/org.gnome.Calculator'
hold 1; keys -k Return
hold 5; still 02-flatpak-card
keys -k Return           # queue it
hold 2

scene snap-search
keys -k Escape           # clear the field; it keeps the keyboard
keys 'hello'
keys -M ctrl -k s -m ctrl
hold 5; keys j
hold 1; still 03-snap-search

scene snap-card
keys -k Return           # look hello-world up
hold 5; keys c           # the next channel it publishes
hold 2; still 04-snap-card
keys x                   # arm classic: the warning turns red
hold 2; still 05-classic-confirm
# One key per wtype call: `wtype c c` types "c c", and the space between
# is a key too -- the panel's "any other key disarms" rule sees it.
keys c; keys c; keys c   # disarms; back round to stable
hold 1; keys -k Return   # queue it
hold 2

scene declared
keys -k Tab
hold 2; still 06-declared

scene apply
gen_before=$(readlink "$PROFILE")
keys a
hold 4; still 07-apply-log
wait_apply "$gen_before"
scene applied
# nix-flatpak installs in its own unit, which can still be running after the
# switch returns: launch only once Flatpak has the app.
if [ "$DRY" = 0 ]; then
  for _ in $(seq 1 180); do flatpak info org.gnome.Calculator >/dev/null 2>&1 && break; sleep 1; done
  flatpak info org.gnome.Calculator >/dev/null 2>&1 || die "Calculator never installed; see flatpak-managed-install.service"
fi
# The switch reloads Hyprland, which closes open panels (a nixarchy rebuild
# does this for every panel). Reopen on Declared: both apps say installed.
[ "$(omarchy-shell shell isOpen "$PANEL")" = true ] || run omarchy-shell shell toggle "$PANEL" '{}'
hold 2; keys -k Tab
hold 3; still 08-installed
hold 2

scene calculator
run omarchy-shell shell toggle "$PANEL" '{}'
run setsid -f flatpak run org.gnome.Calculator
hold 6; still 09-calculator
run pkill -f gnome-calculator
hold 1

scene remove
run omarchy-shell shell toggle "$PANEL" '{}'
hold 2; keys -k Tab
hold 1; keys d
hold 2; still 10-remove-confirm   # "y removes ... at the next apply", in red
keys y
hold 2; keys d; keys y
gen_before=$(readlink "$PROFILE")
hold 2; keys a
wait_apply "$gen_before"
scene removed
[ "$(omarchy-shell shell isOpen "$PANEL")" = true ] || run omarchy-shell shell toggle "$PANEL" '{}'
hold 2; keys -k Tab
hold 3; still 11-removed          # "Nothing declared yet."
run omarchy-shell shell toggle "$PANEL" '{}'
hold 1

if [ "$DRY" = 0 ]; then
  kill -INT "$rec_pid"
  wait "$rec_pid" || true
  rec_pid=""
fi

encode_and_gate </dev/null
