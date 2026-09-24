---
status: approved
issue: 10
spec: spec/2026-09-24-10-apply-safety.md
---

# Plan: make apply check what it builds, report its errors, and stay visible

## Approved decisions (self-contained)

Line numbers are for `main` at 64f97b2. #11 and #13 merge first and move
some of them (step 0). Every step locates its code by function name, and the
numbers are only a guide.

- **B1: apply builds only the checked, regenerated state.** `cmd_apply` does
  these steps, in this order, before it runs `nixarchy-apply`:
  1. **Refuse a different file.** If `file()` is not
     `${XDG_CONFIG_HOME:-$HOME/.config}/nixarchy/flatsnap.nix`, the file
     nixarchy-apply copies, apply dies with
     `NIXARCHY_FLATSNAP_FILE is not the file nixarchy-apply copies`.
  2. **Shape check.** Call `load_state` in the current shell, never as `$(…)`.
     A mismatch dies with its existing message, exits 2, and leaves the file
     untouched.
  3. **Entry check.** Re-check every entry against `add`'s grammars:
     - `appId` against `FP_RE`;
     - `name` and each `pendingRemoval` name against `SNAP_RE`;
     - `channel` against `CHAN_RE`;
     - `classic` must be a boolean;
     - each override's section, key and value against `OV_RE`'s three parts.

     The first failure dies, with the entry named.
  4. **Regenerate.** If the file exists, write `render(STATE)` back through
     the temp file → `nix-instantiate --parse` → `mv` path, **without**
     `pendingRemoval` pruning. Split `write_state` into `prune_pending` (the
     `snap list` step) and `write_state` (render + parse + mv). `add`/`rm`
     call both, and apply calls only `write_state`. If the file is absent,
     apply creates none.
  5. **Build only the confirmed state.** `apply --expect <hash>` refuses when
     the sha256 of the canonical `STATE` JSON is not `<hash>`, with
     `the declared set changed since you confirmed; press a again`. A bare
     `apply` from a terminal still works.
- **Preview.** Keep `--no-preview`. nixarchy-apply's preview is a VM boot
  asked on stdin, which the panel closes. Instead:
  - `cmd_preflight` runs steps 2-3 first. Its host `nix eval` also returns
    `current = c.config.programs.nixarchy.flatsnap`, the flake's current copy.
  - Preflight's JSON gains `changes`: a list of
    `{op: add|remove|change, store, id, detail}`, from jq, `current` against
    `STATE`.
  - It also gains `stateHash`.
  - The panel **always** arms on a good preflight. The message shows at most
    six `+ id` / `− id` / `~ id (detail)` lines, then `and N more`. The
    `willRemove` line follows, then `a again applies; any other key cancels`.
  - With nothing to show, the message is
    `nothing changed since the last apply — a again rebuilds anyway`.
  - The second `a` runs `apply --expect <stateHash>`.
  - `cmd_apply` prints the full change list as the first log lines.
- **B2.** `pf=$(cmd_preflight) || { printf '%s\n' "$pf"; exit 2; }`. No QML
  change is needed.
- **B3: a running apply blocks edits and stays visible.**
  - `queue()`/`remove()` return while `applying`, with the message
    `a rebuild is running — wait for it to finish`.
  - `reset()` sets `showingLog = applying`.
  - New `showLog()`, bound to the key **`l`** (accepted).
  - The status line adds `   rebuilding… l shows it` when the apply is
    running and its log is hidden.
  - The end of an apply also sets `fs.message` to
    `applied — l shows the log` or `apply failed: <msg> — l shows the log`,
    while the log is hidden.
  - `open()` gives the keyboard to the key handler during an apply.
  - Esc still never stops a build.
  - The README keys table gains `l`.
- **B4.** `apply()` sets `message = "checking…"` after `_run()`.
- **B5.** The `awk` filter prefixes one space to any line that starts with
  `{"nixarchyFlatsnapApply"` or `{"error"`. The panel's prefix test is then
  trustworthy as it is.
- **Accepted at spec approval:**
  - Hand-edit comments and formatting in `flatsnap.nix` are lost on
    regenerate.
  - Unknown attributes inside entries are dropped. They already failed
    evaluation: `types.submodule` with no `freeformType`, `module.nix:38,53`.
- **Test isolation:** no test may reach the real nixarchy-apply. `tests/cli.sh`
  and `tests/model.sh` run apply code only under a PATH of stubs plus
  store-resolved tools. They assert first that `nixarchy-apply` resolves to
  the stub, and that no PATH entry is or resolves under `/run/current-system`,
  `/run/wrappers` or `/etc/profiles`. A failed assertion aborts the test file.
- **Live checks on razer only**, never p620. The plugin is staged outside
  `plugins/` and moved in.
- **Not in this issue:**
  - `advanced.nix`/`apps.nix` in nixarchy;
  - `nixarchy-apply --detach`;
  - locking terminal `add`/`rm` during an apply (#13's C1, beyond using its
    lock helper in step 3).

## Steps

0. **Rebase.** After #11 and #13 merge to `main`:
   `git fetch origin && git rebase origin/main` on `fix/10-apply-safety`,
   then run `bash tests/cli.sh`.
   → verify by: the rebase is clean, and cli.sh prints `N passed, 0 failed`.

   Build on their versions:
   - **#11** changes `cmd_preflight`'s start (flake lookup, the dead `grep`
     feature detection, E4) and the shellcheck derivation, which may now
     cover `tests/model.sh` (E10).
   - **#13** changes `cmd_preflight` around the installed-list (lines
     ~404-407, the shared installed-list helper, C8), `write_state` (the `.bak`
     dance removed, C4; pruning only when `snap list` succeeded, C3), and
     wraps `add`/`rm` in a lock (C1).

   Re-read `cmd_preflight`, `write_state` and `cmd_apply` after the rebase,
   before step 1.

1. **`tests/cli.sh`: hermetic PATH for the apply section.** This comes before
   any apply test changes. Replace `pa() { env PATH="$ab:$PATH" …; }` with a
   PATH of exactly `$ab` and `$work/tools`. `$work/tools` holds symlinks to
   `readlink -f "$(command -v X)"` for:
   `bash jq nix-instantiate awk sed grep sha256sum mktemp cat cp mv rm mkdir dirname uname tr head`,
   plus anything #11/#13 added to the CLI's needs.

   Add a guard that runs once, before the first apply test:
   - `env PATH=… command -v nixarchy-apply` must equal `$ab/nixarchy-apply`;
   - no PATH entry is, or `readlink -f`s under, `/run/current-system`,
     `/run/wrappers` or `/etc/profiles`;
   - on failure: `printf 'ABORT: …'` and `exit 1`, not `bad`.

   Also:
   - Export `XDG_CONFIG_HOME=$work/config` and unset `NIXARCHY_FLATSNAP_FILE`
     for this section.
   - Extend the stub `nixarchy-apply` to append `invoked` to `$APPLY_LOG` and
     copy `$XDG_CONFIG_HOME/nixarchy/flatsnap.nix` (if present) to
     `$work/copied.nix`.

   → verify by: `bash tests/cli.sh` still reports 0 failed (existing apply
   cases unchanged). Then temporarily add `/run/current-system/sw/bin` to the
   tools PATH in a scratch copy of the test: the file aborts before any apply
   case runs. Do not commit that copy.

   *As implemented:*
   - **Shared helper.** The PATH builder and the guard are
     `tests/isolate.sh` (`isolated_path`, `assert_isolated`). `tests/cli.sh`
     sources it now, and `tests/model.sh` does in step 2. It is added to
     `checks.shellcheck`. The tools list also has `cut flock sort`: #13's lock
     needs `flock`.
   - **Stricter than planned.** The guard denies more than `/run/current-system`,
     `/run/wrappers` and `/etc/profiles`: any PATH directory under `/run`,
     `/etc`, `/usr`, `/bin`, `/sbin`, `/nix/var` or a nix profile. Every link
     in a PATH directory must point into `/nix/store`, both directly and when
     resolved. Found while checking: with envfs, `/usr/bin/nixarchy-apply`
     "exists" on NixOS even though `/usr/bin` lists empty, so a PATH of just
     `/usr/bin` would still reach the real rebuild.
   - **How the guard was checked.** The scratch-copy check was done as a unit
     check of `assert_isolated`, which runs only `command -v` and `readlink`,
     so nothing real can run even if the guard were wrong. These PATHs abort:
     - `/run/current-system/sw/bin` alone, and after the stub;
     - `/run/wrappers/bin`;
     - a directory with a link to `/run/current-system/sw/bin/jq`;
     - `/usr/bin`.

     The built PATH passes. `checks.cli`: 110 passed, 0 failed.

2. **`tests/model.sh`: the same isolation.** Before quickshell starts:
   - Resolve `quickshell` to its store path.
   - Create `$d/stubs`:
     - `nixarchy-apply`: logs `invoked` to `$d/apply.log`, exits 0;
     - `nix`: prints `$NIX_EVAL_ANSWER`, a canned
       `{"hasModule":true,"uninstallUnmanaged":false,"declared":[],"current":{"flatpaks":[],"snaps":[]}}`;
     - `flatpak`: prints nothing.
   - Symlink the store-resolved tools into `$d/tools`, and run with
     `PATH=$d/stubs:$d/tools`.
   - Run the same guard as step 1 (abort on failure), and export
     `XDG_CONFIG_HOME=$d/config`.

   → verify by: `bash tests/model.sh` prints `model: N passed, 0 failed` with
   the existing cases, and the guard aborts when a `/run/current-system` entry
   is injected in a scratch copy.

3. **`bin/nixarchy-flatsnap`: split `write_state`.** Move the pendingRemoval
   pruning into `prune_pending`, which reads JSON on stdin and writes it to
   stdout. Keep #13's success-only condition. `write_state` becomes render +
   parse + mv, under #13's lock if it provides one. `cmd_add`/`cmd_rm` pipe
   through `prune_pending | write_state`.
   → verify by: `bash tests/cli.sh`, where every pendingRemoval case still
   passes. shellcheck is clean.

4. **`bin/nixarchy-flatsnap`: `check_entries`.** A function over `$STATE`
   that applies the step-3 grammars from the decisions above, and dies naming
   the first bad entry. The override section, key and value come from
   splitting `OV_RE` into three anchored regexes, which `cmd_add` then uses
   too, so the two cannot drift.
   → verify by: the new cli.sh case 2 (step 9) fails before this step and
   passes after it. The existing add-refusal cases still pass.

   *As implemented:*
   - **Grammars.** `OV_RE` is now built from `OV_SEC`/`OV_KEY`/`OV_VAL`, next
     to the other grammars at the top of the script.
   - **Non-string values.** jq also refuses:
     - a value that is not a string;
     - a list that is not a list, and an entry that is not an attribute set;
     - any control character (newline, tab), so every checked value is one
       line.

     If jq itself fails, that is an error, never a pass.
   - **Render defaults.** `render` falls back to the module's defaults
     (`channel` `stable`, `classic` false) for a hand-written
     `{ name = "x"; }`. The module accepts that entry, but render emitted
     `null` for it, so regenerating it would have failed.
   - **When it runs.** `check_entries` is only defined here. Steps 5-6 call
     it, so case 2 is proven there. Before that, a unit check of the function
     (eval'd without `main`) accepted a full valid state and the empty one.
     It refused, each with the entry named: a bad snap name, Flatpak ID,
     channel, `classic`, override value and pendingRemoval; a newline, a
     tab, a trailing newline, a number, a non-list and a non-set.
     `checks.cli`: 110 passed.

5. **`bin/nixarchy-flatsnap`: `cmd_preflight`.**
   - Call `load_state` and `check_entries` first, before the host `nix eval`.
   - Add `current` to the eval's `--apply` expression.
   - Compute `changes` and `stateHash` with jq. The hash is
     `jq -cS . <<<"$STATE" | sha256sum | cut -c1-64`.
   - Emit both alongside `ok`, `message` and `willRemove`.

   → verify by: cli.sh case 8. `preflight ready` and the `willRemove` case
   still pass, with `current` added to their `NIX_EVAL_ANSWER`.

   *As implemented:*
   - **Missing `current`.** Preflight treats a missing `current` as empty, so
     the existing cases' `NIX_EVAL_ANSWER` is left as it was.
   - **Case 8 lands here.** It is added to `tests/cli.sh` in this step, not
     in step 9, because it is this step's verification.
   - **`state_hash()`** is a helper, so preflight and apply hash the same way.
   - **The `--apply` expression** was evaluated against two fake
     configurations, one without the module and one with it, before use.
   - `checks.cli`: 111 passed.

6. **`bin/nixarchy-flatsnap`: `cmd_apply`.** In order:
   1. parse `--expect <hash>` (refuse any other argument, exit 2);
   2. the file-identity check;
   3. `pf=$(cmd_preflight) || { printf '%s\n' "$pf"; exit 2; }` (B2);
   4. the `ok` test as now;
   5. `load_state` + `check_entries`, again, in this shell;
   6. the `--expect` comparison;
   7. `write_state <<<"$STATE"` if the file exists;
   8. print the change lines, then the `willRemove` lines;
   9. the elevation choice and `nixarchy-apply --yes --no-preview` as now.

   The `awk` filter gains
   `if (index($0, "{\"nixarchyFlatsnapApply\"") == 1 || index($0, "{\"error\"") == 1) $0 = " " $0`
   before `print`.
   → verify by: cli.sh cases 1-7 and 9-11, plus the existing apply-stream
   and elevation cases.

7. **`FlatsnapModel.qml`.**
   - `queue()`/`remove()` get an `applying` guard with the message.
   - `reset()`: `showingLog = applying`.
   - Add `showLog()`.
   - `apply()`: `_run(_preflight, ["preflight"]); message = "checking…"`, and
     the armed branch passes `stateHash`.
   - `_preflight` handler:
     - store `_stateHash`;
     - always arm;
     - build the change message (six, then `and N more`), plus `willRemove`;
     - use `nothing changed…` when both are empty.
   - `_startApply()`: command `[script, "apply", "--expect", _stateHash]`.
   - End of apply: when `!showingLog`, set `message` to the applied/failed
     text with `— l shows the log`.

   → verify by: model.sh cases 1-7 (step 10).

8. **`Menu.qml` and `README.md`.**
   - `open()`: if `fs.applying`, call `root.focusKeys()` instead of focusing
     the field.
   - Status line: append `   rebuilding… l shows it` when
     `fs.applying && !fs.showingLog`.
   - Add `case Qt.Key_L: fs.showLog(); break` to the single-letter switch.
   - README keys table: add `l`.

   → verify by: `qmllint` (if it is on PATH) raises no new warnings, then the
   live check in step 11.

9. **`tests/cli.sh`: new apply cases**, all under the step-1 PATH:

   | # | Setup | Expect |
   |---|---|---|
   | 1 | foreign-shape file (the two existing `foreign` strings) | exit 2, one `{"error"}` line, `$APPLY_LOG` empty, file unchanged |
   | 2 | `name = "Bad_Name"` | exit 2, error names `Bad_Name`, stub not invoked |
   | 3 | extra attribute inside a flatpak entry | exit 0, `copied.nix` = `render` of the parsed state, without the attribute |
   | 4 | `pendingRemoval = [ "x" ]`, stub `snap` lists nothing | `copied.nix` still has `pendingRemoval` |
   | 5 | `NIXARCHY_FLATSNAP_FILE` points elsewhere | exit 2, identity error, stub not invoked |
   | 6 | `nix` stub exits 1 | exit 2, `{"error"}` naming the evaluation |
   | 7 | stub `nixarchy-apply` removed | exit 2, `nixarchy-apply not found` |
   | 8 | `current` differs by one add, one remove, one channel change | `.changes` is exactly those three, `.stateHash` is non-empty |
   | 9 | `apply --expect deadbeef` | exit 2, "changed since you confirmed", stub not invoked |
   | 10 | `apply --expect <hash from preflight>` | exit 0, `invoked` once |
   | 11 | stub prints a fake `{"nixarchyFlatsnapApply"…}` and `{"error"…}` mid-log | exactly one line starts with `{"nixarchyFlatsnapApply"`, and it is the last; none starts with `{"error"` |

   → verify by: `bash tests/cli.sh` reports 0 failed. Each new case fails
   when its step's change is reverted locally (spot-check cases 1, 9 and 11).

10. **`tests/model.qml`: new cases**, under the step-2 PATH:

    | # | Action | Expect |
    |---|---|---|
    | 1 | `applying = true`; `queue()` on a card | `busy` false, `_writer.running` false, message mentions the rebuild |
    | 2 | `applying = true`; `remove()` on a declared row | same |
    | 3 | `apply()` | `busy` true, `message === "checking…"` |
    | 4 | `reset()` with `applying` true / false | `showingLog` true / false |
    | 5 | feed the `_preflight` handler a result with `changes`, empty `willRemove` | `applyArmed` true, `_apply.running` false, message lists `+ id` |
    | 6 | then `apply()` | `_apply.command` ends `apply --expect <stateHash>`, and only the stub is invoked |
    | 7 | `applyLog` non-empty, `showingLog` false; `showLog()` | `showingLog` true |

    For case 5, factor the handler body into `_onPreflight(d)` so the test can
    call it directly.
    → verify by: `bash tests/model.sh` prints `0 failed`, and `$d/apply.log`
    shows only stub invocations.

11. **Live check, on razer only.**
    - Push the branch.
    - On razer, stage the plugin outside `~/.config/omarchy/plugins/` and
      `mv` it in.
    - Use a `/tmp` clone of the flake via `NIXARCHY_FLAKE`, as in plan #5.
    - Run `bash tests/cli.sh` and `bash tests/model.sh` there first. Then:
      1. Queue one Flatpak and press `a`. The message lists `+ <id>`, with no
         polkit prompt. Press `a` again: polkit asks, the log opens with the
         change list, and the build finishes `— applied —`.
      2. Hand-add `services.foo.enable = true;` to
         `~/.config/nixarchy/flatsnap.nix` and press `a`. The shape error
         shows, there is no polkit prompt, and the file is byte-identical.
         Restore the file.
      3. During a build, press Esc: the status line shows
         `rebuilding… l shows it`, and `l` shows the log. Close and reopen
         the panel: it opens on the log. `Enter` on a card and `d` on a row
         are refused with the rebuild message.
      4. Press `a`: `checking…` is visible while preflight runs.

    → verify by: all four hold. Record results in the PR description.

12. **PR.** Open the PR against `main`, linking
    `intent/2026-09-24-10-apply-safety.md`,
    `spec/2026-09-24-10-apply-safety.md` and this plan, with `Closes #10`.
    Any deviation from these steps is written into this plan in the same
    commit as the code.
    → verify by: CI (`nix flake check -L`, from #11) is green on the PR.

### Post-merge

13. **nixarchy follow-up (the user opens it).** On olafkfreund/nixarchy: its
    `nixarchy-apply` copies `apps.nix` and `advanced.nix` into the flake and
    imports them as full modules, and any user process can write them. This
    is the same class of problem as #10's B1. This task does not open the
    issue.
14. **This repo:** open an issue for moving apply to
    `nixarchy-apply --detach`, so a build survives a shell restart and a
    reopened panel can find it.

## Tests

Nothing here invokes the real `nixarchy-apply`, `nixos-rebuild` or `nh`, and
the guard from steps 1-2 enforces that.

```
bash tests/cli.sh            # "N passed, 0 failed"; aborts if nixarchy-apply is reachable
bash tests/model.sh          # "model: N passed, 0 failed" (needs a Wayland session)
nix flake check -L           # shellcheck + checks.cli in the sandbox
```

The live check (step 11) runs on razer only.

## Rollback

- **Before merge:** drop the branch. Nothing outside the repo changed.
- **After merge:** `git revert` the merge commit. `flatsnap.nix` stays in the
  same format this tool has always written, so no user file needs migrating.
- **On razer:** remove the staged plugin directory and restore the previous
  plugin build. The `/tmp` flake clone is discarded.
