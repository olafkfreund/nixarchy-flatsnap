#!/usr/bin/env bash
# docs/record.sh -- record the showcase GIF and stills on a nixarchy desktop.
#
# Runs ON the test machine, from outside its session (ssh), and drives the
# real panel with wtype:
#
#   ssh razer 'START_GEN=2942 bash -s -- [--dry-run]' < docs/record.sh
#
# Before it (plan/2026-09-23-5-showcase.md, step 2): a generation that ships
# the plugin is active through `switch-to-configuration test`, its
# programs.nixarchy.flake points at a throwaway clone (so apply never writes
# the machine's real configuration), and the plugin is enabled. START_GEN is
# the generation to go back to; the trap goes back to it however this ends.
#
# Out: $OUT/flatsnap.gif (gated by nixarchy's own verify-frames.sh) and
# $OUT/0N-*.webp stills. Nothing is copied into a repository from here.
set -euo pipefail

DRY=0
[ "${1:-}" = --dry-run ] && DRY=1
: "${START_GEN:?START_GEN: the system generation to return to}"
OUT=${OUT:-/tmp/flatsnap-media}
PANEL=nixarchy.flatsnap
PROFILE=/nix/var/nix/profiles/system
FS_FILE="$HOME/.config/nixarchy/flatsnap.nix"
CLI="$HOME/.config/omarchy/plugins/$PANEL/bin/nixarchy-flatsnap"
# The largest 16:10 region of a 1920x1080 screen: exactly 900x563 and
# 1280x800 when scaled, so nothing is cropped afterwards.
REGION_GRIM="96,0 1728x1080"
REGION_GSR="1728x1080+96+0"

say() { printf '== %s\n' "$*" >&2; }
die() { printf 'record.sh: %s\n' "$*" >&2; exit 1; }
run() { if [ "$DRY" = 1 ]; then printf 'would: %s\n' "$*"; else "$@"; fi; }
hold() { run sleep "$1"; }
keys() { run wtype -d 40 "$@"; }
# Hyprland's Lua dispatch first, the old form second -- the way Omarchy's own
# scripts do it; the old form alone is a parse error on a Lua config.
workspace() { run hyprctl dispatch "hl.dsp.focus({ workspace = \"$1\" })" >/dev/null 2>&1 ||
  run hyprctl dispatch workspace "$1"; }

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

mkdir -p "$OUT"
: >"$OUT/scenes.tsv"
rec_pid=""
t0=0

cleanup() {
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
    run "$CLI" apply >/dev/null
  fi
  run omarchy-theme-set "$theme0"
  run omarchy-theme-bg-set "$bg0"
  [ "$(omarchy-shell notifications isDnd)" = "$dnd0" ] || run omarchy-shell notifications toggleDnd
  workspace "$ws0"
  # Back to the generation this started on; drop every one made since.
  local -a newer
  mapfile -t newer < <(find /nix/var/nix/profiles -maxdepth 1 -name 'system-*-link' -printf '%f\n' |
    sed -n 's/^system-\([0-9]*\)-link$/\1/p' | awk -v s="$START_GEN" '$1 > s')
  run sudo nix-env -p "$PROFILE" --switch-generation "$START_GEN"
  run sudo "$PROFILE/bin/switch-to-configuration" switch
  [ ${#newer[@]} -eq 0 ] || run sudo nix-env -p "$PROFILE" --delete-generations "${newer[@]}"
  run sudo "$PROFILE/bin/switch-to-configuration" boot
  run rm -f "$FS_FILE" "$FS_FILE.bak" "$HOME/.local/state/nixarchy/enabled-once/$PANEL"
  say "left on $(readlink "$PROFILE")"
}
trap cleanup EXIT

# ---- the desktop for the take --------------------------------------------
run omarchy-theme-set "Tokyo Night"
run omarchy-theme-bg-set "$OMARCHY_PATH/themes/tokyo-night/backgrounds/0-winding-road.jpg"
[ "$dnd0" = on ] || run omarchy-shell notifications toggleDnd
workspace "$ws"
hold 3

scene() {
  local ms=0
  [ "$DRY" = 1 ] || ms=$(($(date +%s%3N) - t0))
  printf '%s\t%s\n' "$ms" "$1" >>"$OUT/scenes.tsv"
  say "scene $1 @ ${ms}ms"
}
still() { run grim -g "$REGION_GRIM" "$OUT/raw-$1.png"; }
# The panel runs apply itself; this waits for it to finish, not for a key.
wait_apply() {
  [ "$DRY" = 1 ] && { say "would wait for apply"; return; }
  # Preflight (a nix eval) runs first, so apply may not have started yet:
  # wait for it to appear, then for it to finish.
  local i
  for i in $(seq 1 90); do pgrep -f 'nixarchy-flatsnap apply' >/dev/null && break; sleep 1; done
  [ "$i" -lt 90 ] || die "apply never started (preflight refused? look at the panel)"
  while pgrep -f 'nixarchy-flatsnap apply' >/dev/null; do sleep 1; done
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
keys c c c               # disarms; back round to stable
hold 1; keys -k Return   # queue it
hold 2

scene declared
keys -k Tab
hold 2; still 06-declared

scene apply
keys a
hold 10; still 07-apply-log
wait_apply
scene applied
hold 4

scene calculator
run omarchy-shell shell toggle "$PANEL" '{}'
run setsid -f flatpak run org.gnome.Calculator
hold 6; still 08-calculator
run pkill -f gnome-calculator
hold 1

scene remove
run omarchy-shell shell toggle "$PANEL" '{}'
hold 2; keys -k Tab
hold 1; keys d y
hold 2; keys d y
hold 2; keys a
wait_apply
scene removed
hold 4
run omarchy-shell shell toggle "$PANEL" '{}'
hold 1

if [ "$DRY" = 0 ]; then
  kill -INT "$rec_pid"
  wait "$rec_pid" || true
  rec_pid=""
fi

# ---- encode and gate ------------------------------------------------------
NIXARCHY_SRC=${NIXARCHY_SRC:-$(nix flake prefetch --json github:olafkfreund/nixarchy | jq -r .storePath)}
[ -f "$NIXARCHY_SRC/tests/demo/encode-gif.sh" ] || die "no encode-gif.sh under $NIXARCHY_SRC"

# The build log, cut to its first and last 3 s: the rebuild in between is
# nixos-rebuild, not this plugin, and the caption says it was shortened.
ms_of() { awk -F'\t' -v s="$1" '$2 == s { print $1; exit }' "$OUT/scenes.tsv"; }
cut_from=$(( ($(ms_of apply) + 3000) / 1000 ))
cut_to=$(( ($(ms_of applied) - 3000) / 1000 ))
cut2_from=$(( ($(ms_of remove) + 8000) / 1000 ))
cut2_to=$(( ($(ms_of removed) - 3000) / 1000 ))
say "cutting ${cut_from}s-${cut_to}s and ${cut2_from}s-${cut2_to}s"

run rm -rf "$OUT/frames"
run mkdir -p "$OUT/frames"
run ffmpeg -hide_banner -loglevel error -i "$OUT/raw.mp4" \
  -vf "select='not(between(t,$cut_from,$cut_to)+between(t,$cut2_from,$cut2_to))',setpts=N/FRAME_RATE/TB,fps=4,mpdecimate" \
  -fps_mode vfr "$OUT/frames/%04d.png"
run bash "$NIXARCHY_SRC/tests/demo/encode-gif.sh" "$OUT/frames" "$OUT/flatsnap.gif"
run bash "$NIXARCHY_SRC/tests/demo/verify-frames.sh" "$OUT/flatsnap.gif" \
  --expect Calculator --expect Flatpak --expect applied \
  --forbid 'error|failed|refused' --max-bytes 1000000 --dump "$OUT/verify"

for f in "$OUT"/raw-*.png; do
  [ -e "$f" ] || continue
  name=$(basename "$f" .png)
  run magick "$f" -resize 1280x800 -quality 85 "$OUT/${name#raw-}.webp"
done
say "done: $OUT/flatsnap.gif and stills; look at every one before committing"
