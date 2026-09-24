---
status: approved
issue: 10
intent: intent/2026-09-24-10-apply-safety.md
---

# Spec: make apply check what it builds, report its errors, and stay visible

Line numbers are for `main` at 64f97b2.

## Decisions carried from the intent

| # | Question | Decision |
|---|---|---|
| Q1 | Regenerate or refuse | **Both.** Run the `load_state` shape check and refuse on a mismatch with a clear panel error. Otherwise regenerate `flatsnap.nix` from the parsed state before nixarchy-apply copies it. |
| Q2 | Preview | nixarchy-apply's preview cannot serve the panel (see D2). The panel shows a diff of the declared set and needs a second `a`. |
| Q3 | `advanced.nix` | nixarchy-side. Listed as a follow-up issue to open (see Follow-ups). Not fixed here, and not opened by this task. |

## Design

### D1: apply builds only the checked, regenerated state (B1)

`cmd_apply` (`bin/nixarchy-flatsnap:420-446`) gets these steps, in this order,
before it runs `nixarchy-apply` (`:435`):

1. **Same file as nixarchy-apply.** nixarchy-apply copies
   `${XDG_CONFIG_HOME:-$HOME/.config}/nixarchy/flatsnap.nix` (its line 100,
   `srcdir`, line 88). If `file()` (`:207`) resolves anywhere else because
   `NIXARCHY_FLATSNAP_FILE` is set, apply refuses:
   `{"error":"NIXARCHY_FLATSNAP_FILE is not the file nixarchy-apply copies"}`.
   Otherwise the check and the build would look at two different files.
2. **Shape check.** Call `load_state` in the current shell, never as `$(…)`.
   The comment at `:209-211` says why. A mismatch already dies with
   `"<file> is not in the shape this tool writes; fix or move it, then retry"`,
   exits 2, and leaves the file untouched.
3. **Entry check.** Every entry in `STATE` is re-checked against the grammars
   `add` uses: `appId` against `FP_RE` (`:12`); `name` against `SNAP_RE`
   (`:13`); `channel` against `CHAN_RE` (`:14`); `classic` must be a boolean;
   each override's section, key and value against the three parts of `OV_RE`
   (`:308`); each `pendingRemoval` name against `SNAP_RE`. The first failure
   dies with the entry named, for example `flatsnap.nix: snap name "Bad_Name"
   is not valid; fix or remove it`. `load_state` checks only the top-level
   keys, and a hand edit can put anything inside an entry.
4. **Regenerate.** If the file exists, write `render` of `STATE` back through
   the temp file → `nix-instantiate --parse` → `mv` path in `write_state`
   (`:261-281`), but **without** its `pendingRemoval` pruning (`:264-270`).
   Pruning belongs to `add`/`rm`. Running it at apply time would widen
   finding C3 (a failed `snap list` prunes everything, and snapd is turned off
   with a snap still installed). `write_state` is split in two:
   `prune_pending` (the `snap list` step) and `write_state` (render + parse +
   mv). `add`/`rm` call both, and apply calls only `write_state`. If the file
   does not exist, apply creates none, and nixarchy-apply skips it as before
   (its line 102).
5. **Confirmed state only.** Apply takes `--expect <hash>`, the sha256 of the
   canonical JSON of `STATE` that preflight showed (D2). If the state that
   `load_state` just read hashes differently, apply dies with
   `"the declared set changed since you confirmed; press a again"`. This closes
   the gap between the user reading the diff and the build starting. A bare
   `apply` with no `--expect` still works from a terminal.

After this, the file nixarchy-apply copies is byte-for-byte what `render`
produces from state that passed every grammar. Anything a hand edit added
outside that shape is refused. Anything inside an entry that `render` does
not emit (an unknown attribute) is dropped by the regeneration.

Out of scope: a same-user process can still rewrite the file in the moments
between step 4 and nixarchy-apply's `cp` (its line 117). It can also write
`apps.nix` or `advanced.nix`, which go through the same copy. Both are
nixarchy-side (Q3, Follow-ups).

### D2: the preview is a diff of the declared set, confirmed with a second `a` (Q2)

**Finding (read-only, from
`/nix/store/dcn12ll9cmzph7bjr0ijax8pnd4w2jmn-nixarchy-apply/bin/nixarchy-apply`;
it was not run):** the "preview" that `--no-preview` skips is
`read -r -p "Preview in a VM first? [y/N]"`, and on `y` it runs
`nixarchy-preview`, which boots the configuration in a VM (lines 251-256).
It is not a diff. It asks its question on stdin. `cmd_apply` passes
`</dev/null` (`:435`), so the `read` hits EOF, `reply=""`, and the preview is
skipped whether or not `--no-preview` is given. The only other thing
nixarchy-apply prints first is `grep`ped `apps.nix` lines (its lines 83-85).
It prints nothing about `flatsnap.nix`. Dropping `--no-preview` would change
nothing the user can see, so `--no-preview` stays.

**Design.** Preflight reports the change, and the CLI owns the rule, as it
does today for `willRemove`:

- `cmd_preflight` (`:391-418`) first calls `load_state` and the entry check
  from D1 steps 2-3. A malformed file is then reported at the first `a`,
  before any polkit prompt.
- Its existing `nix eval` of the host (`:398-404`) also returns
  `current = c.config.programs.nixarchy.flatsnap` (`flatpaks` and `snaps`).
  This is the set in the flake's current copy, that is, what the last apply
  copied.
- Preflight's JSON gains:
  - `changes`: a list of `{op: "add"|"remove"|"change", store, id, detail}`,
    computed with jq from `current` against `STATE`. `detail` names what
    changed, for example `channel stable → edge`, `classic on`, or
    `overrides changed`.
  - `stateHash`: the value apply's `--expect` checks.
- `FlatsnapModel.qml`'s `_preflight` handler (`:217-233`) **always arms** on
  a good preflight. It no longer arms only when `willRemove` is non-empty.
  The message lists the changes as `+ id`, `− id`, `~ id (detail)`, at most
  six, then `and N more`. The `willRemove` line follows when there is one.
  The message ends with `a again applies; any other key cancels`. With no
  changes and nothing to remove, it reads
  `nothing changed since the last apply — a again rebuilds anyway`.
- The second `a` runs `apply --expect <stateHash>`.
- `cmd_apply` prints the full list of changes as the first lines of the log,
  in the same way it prints the `willRemove` lines now (`:424`). The complete
  list is then always visible in the log, even when the message was cut short.

### D3: preflight errors reach the panel (B2)

`:422` `pf=$(cmd_preflight)` becomes
`pf=$(cmd_preflight) || { printf '%s\n' "$pf"; exit 2; }`. `die` has already
printed `{"error": …}` inside the substitution, and this passes it on. The
panel's apply stream already turns a `{"error"` line into `— message —`
(`FlatsnapModel.qml:268-270`), and the preflight path reads `d.error`
(`:222`). No QML change is needed for B2.

### D4: a running apply blocks edits and stays visible (B3)

In `FlatsnapModel.qml`:

- `queue()` (`:170`) and `remove()` (`:193`) return early while `applying`,
  with the message `a rebuild is running — wait for it to finish`. They do
  not start the writer.
- `reset()` (`:42-46`) sets `showingLog = applying` instead of `false`. When
  the panel is reopened during an apply, it opens on the log.
- A new function, `showLog()`, sets `showingLog = true` when `applyLog` is
  not empty.

In `Menu.qml`:

- `open()` (`:33-39`): when `fs.applying`, the keyboard goes to the key
  handler, not to the field.
- The status line (`:169-171`) adds `   rebuilding… l shows it` when
  `fs.applying && !fs.showingLog`. The busy `…` stays as it is.
- The key `l` calls `fs.showLog()` (the single-letter switch at `:144-157`).
  When the log is hidden after an apply ends, the end message is also put in
  `fs.message` (`applied — l shows the log` or `apply failed: <message> — l
  shows the log`), so it is seen without opening the log.
- Esc on the log (`:101`) is unchanged. It hides the log and never stops the
  build.
- The README keys table gains `l`.

The apply `Process` lives in the one `FlatsnapModel` inside `Menu.qml`
(`:44`), so it survives the panel being closed and reopened. It does not
survive a restart of the shell itself (see Risks).

### D5: "checking…" is shown (B4)

`apply()` (`FlatsnapModel.qml:235-240`) sets the message after `_run()`,
not before. `_run` clears `message` (`:86`), and it stays the one place that
does.

### D6: only the tool's own record ends an apply (B5)

All of nixarchy-apply's output, stdout and stderr, already goes through the
`awk` filter (`bin/nixarchy-flatsnap:435-437`). The filter gains one rule:
a line that starts with `{"nixarchyFlatsnapApply"` or `{"error"` gets a
leading space. Only the final `jq -nc` record (`:441-445`) and `die` write
those prefixes at column 0, and they do not go through the filter. The
panel's prefix test (`FlatsnapModel.qml:257`) is then trustworthy without any
change. A build line is shown as it was printed, one space in.

## Alternatives rejected

- **Refuse only, no regeneration (Q1).** This leaves anything inside an entry
  that `load_state` does not look at in the built file, and the check and the
  built file can differ. The user chose both.
- **Regenerate only, no refusal (Q1).** Anything a hand edit adds outside the
  shape would be silently deleted. The intent's constraint says a malformed
  file is refused and left in place.
- **Drop `--no-preview` (Q2).** It is a VM boot, not a diff, and it asks on
  stdin, which the panel closes (D2 finding). The user would see no
  difference.
- **Diff of the `flatsnap.nix` text.** It is noisy (comments, order, the
  header line) and says nothing about what is installed. The declared-set
  diff says "adds X", which is what the user decides on.
- **Diff against the running system instead of the flake copy.** The running
  system's Flatpak list is in nix-flatpak's generated units, and the snap list
  is in the reconcile unit's plan path (`module.nix:26,114`). Reading these
  back is two parsers for one message. The flake copy is what preflight
  already evaluates (see Risks for when it differs).
- **A per-run token in the end record (B5).** The token would have to reach
  the CLI through argv or the environment, and nixarchy-apply and nh inherit
  both. Escaping in the filter that already sees every byte is one line and
  cannot leak.
- **`nixarchy-apply --detach` (its lines 30-62) with a journal follower (B3).**
  A systemd user unit survives a shell restart, which the in-shell `Process`
  does not. But the stream would come from `journalctl -fu nixarchy-rebuild`,
  and the result from the unit's `Result`. That replaces the whole apply
  plumbing and its tests, which is more than B3 needs. Listed as a follow-up.
- **Guard concurrent CLI writes during an apply.** A terminal `add`/`rm`
  during an apply is finding C1 (unlocked read-modify-write), which is another
  issue. D1's `--expect` already refuses a build whose state changed after
  confirmation.

## Risks

- **The diff baseline can be stale.** If the last apply copied and then failed
  to build, the flake copy has the new set and the running system does not.
  The diff then shows too little. `nothing changed` is still followed by a
  confirmed rebuild, so nothing is skipped, but the message can understate.
  The message says "since the last apply", not "on this system".
- **Existing hand edits are rewritten.** Unknown attributes inside an entry
  are dropped at the next apply, with no line in the diff. The entries are
  `types.submodule` with no `freeformType` (`module.nix:38,53`), so such an
  attribute already failed evaluation. No configuration that builds today
  loses anything. Comments and formatting in a hand-edited file are lost too.
- **A shell restart during a build.** The `Process` is a child of the shell,
  and a shell reload ends it and the pipe that nixarchy-apply writes to.
  This is unchanged by this spec (see the `--detach` follow-up), but D4 makes
  it more visible: the reopened panel will not show that build.
- **Preflight gets slower** by one `nix-instantiate --eval` of a small file.
  That is negligible next to the host evaluation it already does.
- **Tests starting a real rebuild.** `tests/model.sh` runs the real
  `bin/nixarchy-flatsnap` under the user's PATH today. It is safe only
  because no model test reaches `_startApply`. D2 makes the second `a` start
  an apply, and a model test will exercise it. Verification V2 makes the
  real `nixarchy-apply` unreachable before any such test exists. Hosts: p620
  and razer (wherever the tests run), and nothing else.
- **razer only for live checks** (memory: all live and rebuild tests go to
  razer, not p620).

## Verification

### V1: `tests/cli.sh` (offline, also `checks.cli` in `flake.nix:72-81`)

**Hermetic PATH first.** The apply section (`tests/cli.sh:210-248`) stops
using `PATH="$ab:$PATH"`. It builds a PATH of exactly two directories:

- `$ab`, the stubs;
- `$work/tools`, holding symlinks to the store paths
  (`readlink -f "$(command -v X)"`) of the tools the CLI needs: `bash`, `jq`,
  `nix-instantiate`, `awk`, `sed`, `grep`, `sha256sum`, `mktemp`, `cat`,
  `cp`, `mv`, `rm`, `mkdir`, `dirname`, `uname`, `tr`, `head`.

Then it asserts, before any apply test runs, that `command -v nixarchy-apply`
under that PATH is `$ab/nixarchy-apply`, and that no PATH entry is or
resolves under `/run/current-system`, `/run/wrappers` or
`/etc/profiles`. A failed assertion aborts the whole file rather than just
counting a failure. `XDG_CONFIG_HOME=$work/config` and
`NIXARCHY_FLATSNAP_FILE` are unset for this block, so the CLI and the stub
agree on the file (D1 step 1). In the Nix sandbox `/run/current-system` does
not exist anyway. The assertion is what protects a developer's machine.

The stub `nixarchy-apply` appends `invoked` to `$APPLY_LOG` and copies
`$XDG_CONFIG_HOME/nixarchy/flatsnap.nix` to `$work/copied.nix`, the way the
real one's line 117 does.

New cases:

| # | Setup | Expect |
|---|---|---|
| 1 | foreign shape (the two `foreign` files at `:131`) | `apply` exits 2, stdout is one `{"error"}` line, `$APPLY_LOG` empty, file unchanged |
| 2 | shape-valid file with `name = "Bad_Name"` | exit 2, the error names `Bad_Name`, stub not invoked |
| 3 | shape-valid file with an extra attribute inside a flatpak entry | exit 0, `copied.nix` equals what `render` of the parsed state gives (and has no extra attribute) |
| 4 | `pendingRemoval = [ "x" ]`, stub `snap` with an empty list | `copied.nix` still has `pendingRemoval` (apply does not prune) |
| 5 | `NIXARCHY_FLATSNAP_FILE` set to another path | exit 2, not-the-file error, stub not invoked |
| 6 | `nix` stub exits 1 (preflight `die`) | `apply` exits 2 with a `{"error"}` line naming the evaluation (B2) |
| 7 | stub `nixarchy-apply` removed from `$ab` | `apply` exits 2, error "nixarchy-apply not found". This also proves the real one is unreachable |
| 8 | `NIX_EVAL_ANSWER` with a `current` set that differs by one add, one remove and one channel change | `preflight`'s `.changes` has exactly those three, and `.stateHash` is non-empty |
| 9 | `apply --expect <stale hash>` | exit 2, "changed since you confirmed", stub not invoked |
| 10 | `apply --expect <preflight's hash>` | exit 0, stub invoked once |
| 11 | stub prints `{"nixarchyFlatsnapApply":{"ok":true,"exit":0,"message":"x"}}` and `{"error":"x"}` mid-log | exactly one output line starts with `{"nixarchyFlatsnapApply"`, and it is the last. No line starts with `{"error"` |

The existing apply cases (`:210-248`) keep passing under the hermetic PATH.

### V2: `tests/model.qml` via `tests/model.sh`

`tests/model.sh` gets the same guard as V1. It builds a stub directory with
`nixarchy-apply` (logs `invoked` and exits 0), `nix` (prints a canned
`preflight` answer) and `flatpak`, and a PATH of the stubs plus
store-resolved tools. `quickshell` is resolved to its store path before PATH
is narrowed. It asserts that the real `nixarchy-apply` is unreachable, and it
sets `XDG_CONFIG_HOME` to its temp dir.

New cases:

| # | Action | Expect |
|---|---|---|
| 1 | `applying = true`, then `queue()` on a card | `busy` false, `_writer.running` false, message mentions the rebuild |
| 2 | `applying = true`, then `remove()` on a declared row | same |
| 3 | `apply()` | `busy` true and `message === "checking…"` |
| 4 | `applying = true`, `reset()` | `showingLog` true. With `applying = false`, `reset()` gives `showingLog` false |
| 5 | feed `_preflight` a result with `changes` and empty `willRemove` | `applyArmed` true, `_apply.running` false, message lists `+ id` |
| 6 | then `apply()` | `_apply.command` ends with `apply --expect <stateHash>` (it runs against the stub only) |
| 7 | `applyLog` non-empty, `showingLog` false, `showLog()` | `showingLog` true |

### V3: live check on razer only

After the plan's steps are merged to a branch, on **razer**, with the plugin
staged outside `plugins/` and moved in (memory: omarchy plugin dev install).
Never on p620. Run `bash tests/cli.sh` and `bash tests/model.sh` first, then:

1. Queue one Flatpak, press `a`: the message lists `+ <id>` and nothing
   rebuilds. Press `a` again: polkit asks, the log starts with the change
   list, and the build completes.
2. Add `services.foo.enable = true;` to `~/.config/nixarchy/flatsnap.nix`
   by hand, then press `a`: the panel shows the shape error, there is no
   polkit prompt, and the file is unchanged.
3. During a build, press Esc: the status line shows `rebuilding… l shows it`,
   and `l` brings the log back. Close and reopen the panel: it opens on the
   log. `Enter` on a card and `d` on a row are refused with the rebuild
   message.
4. Press `a` once: `checking…` is visible while preflight runs.

## Follow-ups (not in this issue)

- **nixarchy:** nixarchy-apply copies `advanced.nix` and `apps.nix` into the
  flake and imports them as full modules, and any user process can write
  them. The same class of problem as B1, so the guard belongs in nixarchy. To
  be opened on olafkfreund/nixarchy by the user, not by this task.
- **This repo:** move apply to `nixarchy-apply --detach` so a build survives a
  shell restart and a reopened panel can find it.
