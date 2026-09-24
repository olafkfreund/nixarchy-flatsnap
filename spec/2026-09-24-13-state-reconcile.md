---
status: draft
issue: 13
intent: intent/2026-09-24-13-state-reconcile.md
---

# Spec: declared state that is kept, and reached

## Decisions carried from the intent

| # | Question | Decision |
|---|---|---|
| Q1 | How a classic↔strict change is applied | (b) The reconciler refuses: it leaves the snap untouched, logs one clear line and marks the unit failed. (c) The CLI refuses the same change at `add` time for an installed snap. The panel shows the CLI's error. |
| Q2 | Are C5 and C6 in scope? | C5 is in scope, with a new fixture for a snap that does not publish `stable`. C6 is in scope only if the razer check in D8 shows a refresh on every apply. If it does not, C6 moves to its own issue. |
| Q3 | Remove the `.bak` step? | Yes. This spec records the change, and plan #1 gets a dated note. The approved text of spec #1 and plan #1 is not rewritten. |

Line numbers are for `main` at 64f97b2.

## Design

Every change is in `load_state`, `write_state`, `cmd_add`, `cmd_rm`, the
installed-list helper, `lookup_snap`, `nixstr` and `classify`/`parse_install`
in `bin/nixarchy-flatsnap`, and in `bin/nixarchy-flatsnap-reconcile`. There is
one three-line exception in `cmd_preflight` (D5). Tests go in `tests/cli.sh`
and `tests/fixtures/`.

### D1: one lock around every read-modify-write (C1)

`load_state` takes an exclusive `flock` on `$(file).lock` and keeps it until
the process exits:

```bash
STATE_LOCK=
lock_state() {
  [ -z "$STATE_LOCK" ] || return 0          # cmd_add → cmd_list loads twice; same process, one lock
  local f; f=$(file); mkdir -p "$(dirname "$f")"
  exec {STATE_LOCK}>"$f.lock"
  flock -w 30 "$STATE_LOCK" || die "another nixarchy-flatsnap is changing $f; try again"
}
```

`load_state` calls `lock_state` first. Putting the lock in `load_state`
instead of in `cmd_add` and `cmd_rm` means that every path that reads the
state and then writes it is covered. That includes any future caller: #10 may
regenerate the file from the state before an apply. Read-only callers (`list`)
take the lock too, which costs them at most the length of one `add`.

The guard on `STATE_LOCK` matters. A second `flock` on a new file descriptor
in the same process would deadlock against the process's own first lock.

- `flock` comes from util-linux. It is added to the `runtimeInputs` of
  `packages.cli` (`flake.nix:57`) and to the `nativeBuildInputs` of
  `checks.cli`. The plugin copy of the CLI runs with the system `PATH`, which
  on NixOS always has util-linux.
- The lock file stays next to `flatsnap.nix` in `~/.config/nixarchy/`, as the
  `mktemp "$f.XXXXXX"` temp files already do. `nixarchy-apply` copies
  `flatsnap.nix` by name, so the lock file never reaches the flake.

### D2: `write_state` without `.bak` (C4)

Delete `[ -f "$f" ] && cp -p "$f" "$f.bak"` (`:273`) and
`[ -f "$f.bak" ] && cp -p "$f.bak" "$f"` (`:278`). What remains is
mktemp → render → `nix-instantiate --parse` → `mv`, or `rm` the temp file and
`die`. `$f` is only ever replaced by an atomic `mv` of a file that parsed, so
a failure leaves it exactly as it was. That is the same guarantee as before,
without the case where a stale `.bak` is restored over a deleted file.

The comment above `write_state` changes from "Backup, write, parse-check,
restore" to "Write aside, parse-check, rename". `docs/record.sh:170` stops
naming `$FS_FILE.bak`. An old `flatsnap.nix.bak` already on a user's disk is
left alone, because nothing reads it any more.

Plan #1 gets one dated line under its state-file decision (`:18`):
"2026-09-24 (#13): the backup/restore step was removed; mktemp → parse → mv
gives the same guarantee. See spec/2026-09-24-13-state-reconcile.md D2."

### D3: one installed-list helper (C8), and unknown is not empty (C3)

```bash
# JSON array of installed IDs; `null` if the tool is absent; exit 1 if it is
# present but could not be asked (snapd down, flatpak error).
installed_ids() {
  command -v "$1" >/dev/null || { echo null; return 0; }
  local out
  case $1 in
    flatpak) out=$(flatpak list --app --columns=application 2>/dev/null) || return 1 ;;
    snap)    out=$(snap list 2>/dev/null | awk 'NR > 1 {print $1}') || return 1 ;;
  esac
  jq -Rsc 'split("\n") | map(select(. != ""))' <<<"$out"
}
```

The whole file already runs with `set -o pipefail`, so a failing `snap list`
fails the pipeline, and so the substitution.

Snap prints "No snaps are installed yet" on stderr and exits 0 when nothing
is installed. The helper returns `[]` in that case, which is correct.

The three callers:

| caller | today | after |
|---|---|---|
| `write_state` prune (`:266-268`) | a failure looks like "nothing installed", so every pending removal is dropped | prune only when the helper exits 0 and returns an array. Absent (`null`) or failed means keep everything pending. |
| `installed` (`:283-293`) | `null` when absent. A failure gives `[]`, which shows everything as not installed. | `installed_ids x \|\| echo null`: a failure is unknown, like absent |
| `cmd_preflight` (`:404-407`) | a failure gives `[]`, so "will remove" is understated | `fp=$(installed_ids flatpak) \|\| die "could not list installed Flatpaks, so preflight cannot say what apply would remove"`, then `null` becomes `[]` (no flatpak means nothing to remove) |

### D4: classic/strict mismatch: refuse, do not reinstall (C2, Q1)

**What snap can and cannot do.** A classic snap cannot be installed or kept
strict. `snap install` without `--classic` refuses it. For a strict snap,
snapd ignores `--classic` with a warning and installs it strict. So there is
exactly one mismatch between the file and the machine that snap cannot close
on the same channel:

- **declared `classic = false`, installed classic.** The user asked for the
  sandbox and did not get it. This is the case the reconciler silently
  ignores today.

The opposite case, declared `classic = true` but installed strict, is the
normal steady state for a strict snap that the user marked classic. It is
not a mismatch. Refusing it would fail every apply for that snap. The
intent's C2 wording ("toggling classic … never applied") is therefore true
only in the classic → strict direction. The decision in Q1 applies to that
direction. The snapd behaviour this relies on is checked on razer (D8, step
3).

**Reconciler** (`bin/nixarchy-flatsnap-reconcile`):

- `installed` also keeps the Notes column:
  `awk 'NR > 1 { print $1, $4, $6 }'`.
- A new `is_classic` helper checks that the Notes value contains `classic`
  as a comma-separated item (for example `classic` or `disabled,classic`).
- In the loop, before the channel check, for an installed snap:

  ```bash
  if [ "$classic" = false ] && is_classic "$name"; then
    echo "$name is installed with classic confinement but declared strict; snap cannot switch in place." \
         "Remove it from the menu, apply, then add it again." >&2
    failed=1; continue
  fi
  ```

  The snap is untouched, the other snaps still reconcile, and the unit exits
  1. This applies to hand-installed snaps too. Refusing takes nothing away,
  so the "only managed snaps are removed" rule is kept.

**CLI** (`cmd_add snap`): after arguments are parsed and before `load_state`:

```bash
if [ "$classic" = false ] && [ "$(snap_classic "$name")" = true ]; then
  die "$name is installed with classic confinement; snap cannot make it strict in place. Remove it, apply, then add it again."
fi
```

`snap_classic` runs `snap list --unicode=never --color=never "$name"` and
prints `true`/`false` from the Notes column, or nothing when the snap is not
installed or snap cannot be asked. An unknown result lets the `add` through,
because the reconciler is the backstop. The panel needs no change: `queue()`
already shows `{"error"}` in its message line (`FlatsnapModel.qml`, the
`_writer` handler).

### D5: the first channel shown is one the snap publishes (C5)

In `lookup_snap`, `$ch` is the default `stable` unless the user named a
channel. Today it is echoed back as `channel` even when the snap does not
publish it. After the change:

- **Channel implicit** (plain name, Snapcraft URL, search pick): `channel` is
  the first of `stable`, `candidate`, `beta`, `edge` that appears in
  `channels`. `confinement` and `classic` are read for that channel. If
  `channels` is empty, the value stays `stable`, as today. That is the C6
  case (D8).
- **Channel explicit** (`snap install x --channel=beta`, `--edge`): if the
  snap has published channels and the named one is not among them, `resolve`
  fails with `die "x does not publish <ch>; it has: <list>"`.

`classify`/`parse_install` set `channel_given=true` when they read a channel
flag. `channel` itself keeps its `stable` default, so `CHAN_RE` checks and
`cmd_add` are unchanged. `add snap x` from a terminal without `--channel`
still declares `stable`: `add` does no network lookup, and the panel always
passes the card's channel. `FlatsnapModel.qml:113` already uses
`d.channel || "stable"`, so it picks up the corrected value with no QML
change.

**New fixture:** `tests/fixtures/snap-info-no-stable.json`. It is derived
from `snap-info-hello-world.json`, with the channel map filtered to `beta`
and `edge`, and `name`/`title` set to `no-stable`. It is synthetic, and the
commit that adds it says so. `no-stable` matches `SNAP_RE`.

### D6: `nixstr` writes a backslash once (C7)

`gsub("\\\\"; "\\\\\\\\")` becomes `gsub("\\\\"; "\\\\")`. In a jq
replacement string, `"\\\\"` is two backslash characters, which is one
escaped backslash in the Nix string. Today's version writes four, so one
`\` in the state comes back as two after a round trip.

The ID grammars forbid `\`, but a hand-edited override value can hold one.
`load_state` accepts any string under `overrides`, so the bug does reach
disk today. `${` escaping is already correct and does not change.

### D7: tighter input checks (C9)

- **Length cap on Flatpak IDs.** A Flatpak app ID is a D-Bus name, so it has
  at most 255 characters. `[[ $x =~ $FP_RE ]]` becomes a small
  `fp_id_ok() { [ ${#1} -le 255 ] && [[ $1 =~ $FP_RE ]]; }`, used at every
  place `FP_RE` is checked today (`classify`, `cmd_add`). `SNAP_RE` already
  caps at 40.
- **Exact `install` verb.** `classify` matches `"flatpak install "*` and
  `"snap install "*`, with the trailing space, and `parse_install` checks
  `${w[1]} == install`. `flatpak installx foo` then goes to the regular
  "not an app ID" refusal.

### D8: C6, the razer check, and the decision rule

The check runs on razer only. The user runs it, because it installs a snap.

1. **Read only.** Find a snap whose default track is not `latest`:
   `curl -s -H 'Snap-Device-Series: 16' 'https://api.snapcraft.io/v2/snaps/info/<name>?fields=channel-map' | jq '[."channel-map"[].channel.track] | unique'`,
   using a few candidates such as `lxd`, `microk8s` and `node`. Record one
   that has no `latest` track, or whose tracks show a non-`latest` default.
   Also note what `nixarchy-flatsnap resolve <name>` shows for its channels.
2. On razer, run `nixarchy-flatsnap add snap <name>`, apply, and run
   `snap list <name>`. Record the Tracking column. Apply again (no changes),
   then run `journalctl -u nixarchy-flatsnap-snaps -b | grep "refresh <name>"`.
3. On the same run, run `snap install --classic hello-world` by hand, then
   `snap list hello-world`. Expect a warning and no `classic` in Notes. This
   confirms the assumption in D4. Afterwards run `snap remove --purge
   hello-world`.

**Decision rule.** If step 2 logs a refresh on the second apply, C6 is in
this task. The fix has two parts. The reconciler compares only the risk
(`${tracking##*/}` against `$channel`), because the tool only ever chooses
a risk on the default track. `lookup_snap` uses the snap's default track
from the channel map when `latest` is absent, not an empty list. If step 2
logs no refresh, C6 is split into its own issue with the evidence, and this
spec is not amended.

If step 3 contradicts D4, D4 goes back for review before it is implemented.

## Alternatives rejected

- **Reinstall to switch confinement (Q1 option a).** This deletes the snap's
  data (`--purge` is required on NixOS) with no explicit request from the
  user. It was rejected at intent approval.
- **Lock in `cmd_add`/`cmd_rm` only.** This covers today's two writers, but
  every new caller would have to remember the lock. Taking it in `load_state`
  covers them all.
- **Lock on `$XDG_RUNTIME_DIR`.** The tests and the record script point
  `NIXARCHY_FLATSNAP_FILE` at other paths. A lock beside the file always
  serialises writers of that file and nothing else.
- **`flock` on the config directory itself.** This avoids the lock file, but
  it would also serialise against any other tool that locks
  `~/.config/nixarchy`.
- **Keep `.bak` but fix the stale-restore case.** That is more code for a
  step that cannot help: `$f` is never modified before the parse check passes.
- **A length check in `module.nix` too.** The CLI is the trust boundary.
  `module.nix` only sees what the CLI wrote or what the user typed into their
  own file.
- **Refuse declared-classic on a strict install.** snapd ignores `--classic`
  for a strict snap, so this would fail every apply for a harmless setting.
- **A QML change to show the confinement conflict.** The CLI error already
  reaches the panel's message line.

## Risks

- **Shared file with #10 and #11.** Both edit `bin/nixarchy-flatsnap`: #10
  changes `cmd_apply`, and #11 changes `flake()` and `cmd_preflight`. This
  change stays in `load_state`, `write_state`, `cmd_add`, `cmd_rm`, the
  installed-list helpers, `lookup_snap`, `nixstr` and
  `classify`/`parse_install`. The one overlap is the three lines at
  `cmd_preflight:404-407` (the table in D3). Whichever PR lands second rebases
  those three lines. If #10 has `cmd_apply` call `load_state`, it inherits the
  lock with no extra work.
- **`flake.nix` overlap.** E3 (Group E) also edits the `runtimeInputs` of
  `packages.cli` (it adds `nix` and `gnused`). Adding `util-linux` there is a
  one-word merge.
- **Lock waits.** A `list` from the panel waits behind a running `add`
  (seconds: one `nix-instantiate` for the load and one for the parse). After
  30 seconds it gives up with an `{"error"}` rather than hanging the panel.
- **A stale lock is impossible.** `flock` locks are released when the file
  descriptor closes, which happens when the process exits, including on a
  crash.
- **D4 depends on snapd behaviour** (strict snaps ignore `--classic`). D8
  step 3 checks this on razer before implementation. A wrong assumption fails
  safe: the reconciler refuses, it never removes.
- **Notes column format.** If snapd changes the column layout, `is_classic`
  returns false. The reconciler then behaves as it does today (no refusal).
  It never removes or reinstalls.
- **A stricter `resolve` for explicit channels (D5)** turns a paste that used
  to queue an unpublished channel, and fail at apply, into an immediate
  error. That is intended.
- **Hosts.** The reconciler runs as root on every host that has snaps
  declared. Live checks run on razer only, never on p620.

## Verification

Everything below runs offline in `tests/cli.sh` (so in `nix flake check`),
except D8.

- **C1:** start 20 background `add flatpak org.test.App$i` runs. Then `wait`,
  and check that every one exited 0 and that `list` has exactly 20 entries.
  This fails on `main` today (1 entry).
- **C1:** `add` after `load_state` in the same process (`cmd_add` →
  `cmd_list`) does not deadlock. The existing `add` tests cover this, and
  they would hang.
- **C4:** with a stale `$f.bak` present, `$f` deleted and `nix-instantiate
  --parse` stubbed to fail, `add` exits 2 and `$f` still does not exist. The
  existing "parse failure did not restore" test still passes, and no
  `flatsnap.nix.bak` is ever created.
- **C3:** with a `snap` stub that exits 1, `add flatpak …` leaves
  `pendingRemoval` intact. The existing "pruned while still installed" and
  "not pruned once gone" tests still pass.
- **C8:** `list` with a failing `snap` stub reports `installed: null`, not
  `false`. `preflight` with a failing `flatpak` stub exits 2 with
  `{"error"}` on stdout.
- **C2, reconciler:** the snap stub records confinement per snap, and `list`
  prints a Notes column. The state is `code latest/stable classic`, and the
  plan declares `code` with `classic: false`. Expected result: the exit code
  is 1, the log line is on stderr, `code` got no `install`, `refresh` or
  `remove`, and another declared snap is still installed in the same run.
  Declared `classic: true` on a strict install causes no refusal and no
  refresh.
- **C2, CLI:** with a `snap` stub that lists `code` as classic, `add snap
  code` (no `--classic`) exits 2 with an error and leaves the file unchanged.
  `add snap code --classic` succeeds.
- **C5:** `resolve no-stable` gives `channel == "beta"` and a `classic`
  that matches beta's confinement. `resolve 'snap install no-stable
  --channel=stable'` exits 2 with an error that lists `beta` and `edge`.
  `snap install hello-world --channel=beta` still resolves to `beta`.
- **C7:** a hand-edited override value with one backslash
  (`Environment.X = "a\\b";`) survives an unrelated `add`. Read back through
  `list`, it is still `a\b`, one backslash.
- **C9:** a 256-character ID that otherwise matches `FP_RE` is refused by
  both `resolve` and `add`, and a 255-character one is accepted. `flatpak
  installx org.gnome.Calculator` is refused.
- **Whole suite:** `nix flake check -L` passes. That covers `shellcheck`,
  `cli` and the `module` VM test, which must stay green unchanged. The
  plugin QML tests (`tests/model.sh`) also still pass.
- **D8 on razer** decides C6 and confirms D4. The result is recorded on #13.
