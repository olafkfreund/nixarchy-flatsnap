---
status: draft
issue: 23
spec: spec/2026-09-24-23-detach-apply.md
---

# Plan: a running apply survives a shell restart and is found again

Line numbers are for `main` at 7d2ff26. Step 1 rebases onto #15, and any
line that moves is corrected here in the same commit. `nixarchy-apply:N`
means `/nix/store/dcn12ll9cmzph7bjr0ijax8pnd4w2jmn-nixarchy-apply/bin/nixarchy-apply`.

## Approved decisions (self-contained)

1. **The whole checked apply runs inside a user unit.** flatsnap does not
   call `nixarchy-apply --detach`. That flag copies `flatsnap.nix` in a new
   process after its caller has returned (`nixarchy-apply:58-61, 100-120`),
   and no flatsnap lock or check can cover that process. Instead,
   `nixarchy-flatsnap apply` becomes a **launcher**. It starts a transient
   user unit that runs `nixarchy-flatsnap apply --in-unit --expect <hash>`.
   That in-unit run takes the state lock, re-checks the state against the
   hash, regenerates, and runs `nixarchy-apply --yes --no-preview` in the
   foreground. Check, copy and build are one process under one lock, and
   that process outlives the shell.
2. **The unit is the same one `--detach` uses.** Name `nixarchy-rebuild`,
   with `-p RemainAfterExit=yes -p LogRateLimitIntervalSec=0`, no
   `--collect`, and no `NoNewPrivileges` (`nixarchy-apply:49-54`). A
   terminal `nixarchy-apply --detach` and a panel apply exclude each other,
   and systemd refuses a second start of an active unit. The unit name
   lives in one variable, with a `ponytail:` comment naming the nixarchy
   follow-up (decision 9).
3. **Launcher, in order.**
   1. Parse `--expect <64 hex>` and `--in-unit`. Anything else exits 2.
   2. The file check and preflight run as today. Every failure is one
      `{"error":…}` line, exit 2.
   3. `load_state`, `check_entries`, the `--expect` compare, the
      regenerate and the change lines run as today.
   4. Read the unit's `SubState`:
      - `running` or `start*`: print
        `{"error":"a rebuild is already running — l shows it"}`, exit 3;
      - `""` or `dead`: go on;
      - anything else: `systemctl --user stop` and `reset-failed`.
   5. `hash=$(state_hash)`, so a terminal apply with no `--expect` is
      pinned too.
   6. Close the lock fd, then run
      `systemd-run --user --unit=nixarchy-rebuild -p RemainAfterExit=yes -p LogRateLimitIntervalSec=0 --setenv=PATH="$PATH" --setenv=XDG_CONFIG_HOME=… --setenv=XDG_STATE_HOME=… --setenv=NIXARCHY_FLAKE="$(flake)" --setenv=NH_ELEVATION_STRATEGY="$elev" --setenv=NO_COLOR=1 -- "$(readlink -f "$0")" apply --in-unit --expect "$hash"`.
      `$elev` is chosen as today: pkexec, or `passwordless` when
      `sudo -n true` succeeds. A `systemd-run` failure prints
      `{"error":"could not start the rebuild: …"}` and exits 3.
   7. Print `{"nixarchyFlatsnapStarted":{"invocationId":"<32 hex>"}}` (from
      `systemctl --user show -p InvocationID --value`), plus a terminal
      hint: `Rebuilding in the background. Follow it with: nixarchy-flatsnap apply-log --follow`.
      Exit 0.
4. **In-unit run.**
   1. It requires `--expect` and `$INVOCATION_ID`. Without them it exits 2.
   2. It writes the marker `$XDG_STATE_HOME/nixarchy-flatsnap/apply`,
      containing `<INVOCATION_ID> new`, through a temp file and `mv`.
   3. `load_state`, which holds the lock until exit, then `check_entries`
      and the hash compare. On a mismatch it prints
      "the declared set changed since you confirmed; press a again" and
      exits 2, before any copy.
   4. Regenerate. Run nixarchy-apply through the existing filter, which
      keeps its forged-record escaping. Print the existing
      `{"nixarchyFlatsnapApply":…}` record, then **exit with
      nixarchy-apply's rc**, or the filter's rc if that is non-zero.
5. **`apply-status [--ack <id>]`** reads
   `systemctl --user show -p SubState,Result,ExecMainStatus,InvocationID nixarchy-rebuild`
   and prints
   `{"state":"none|running|succeeded|failed","result","exit","invocationId","ours","shown"}`.
   - `none` means `SubState` is `dead` or empty, or `InvocationID` is
     empty. It is never decided from `Result`: a dead unit reads
     `Result=success ExecMainStatus=0`.
   - `running` means `running` or `start*`. `succeeded` means `exited`
     with `Result=success`. `failed` means `failed`, or `exited` with any
     other `Result`.
   - `ours` means the marker's ID equals `InvocationID`. `shown` means the
     marker says `shown`.
   - `--ack <32 hex>` rewrites the marker to `<id> shown`, only if it names
     that ID. This is the one write, and it goes to
     `$XDG_STATE_HOME/nixarchy-flatsnap/` only.
6. **`apply-log [<id>] [--follow]`** runs
   `journalctl --user -u nixarchy-rebuild --invocation=<id> -o cat --no-pager -n 2000`,
   plus `-f` with `--follow`. The ID defaults to the unit's current
   `InvocationID` and must be 32 hex characters, or the verb exits 2.
7. **Panel (`FlatsnapModel.qml`).**
   - **`_apply`** now ends at one of two records:
     - `{"error"}` sets `applying = false` and calls `_ended(error)`;
     - `{"nixarchyFlatsnapStarted"}` sets `_invocation` and starts
       `_follow` and `_poll`.
     - Other lines are logged. `onExited` with neither record keeps
       "the apply ended without a result".
     - The `{"nixarchyFlatsnapApply"}` branch is removed. No text line
       ends an apply any more.
   - **`_follow`**, a new Process, runs `apply-log <id> --follow` into
     `_log`.
   - **`_poll`**, a new 2 s Timer, runs while `applying`. When the watched
     ID leaves `running`:
     1. stop `_follow`;
     2. reload the whole log with `apply-log <id>`;
     3. `applying = false`;
     4. `_ended("applied" | "apply failed (exit N)" | "apply failed (killed)")`;
     5. `--ack <id>` if `ours`;
     6. `list()`.
   - **On `reset()`**, run `apply-status` once:
     - `running` (**any** rebuild, terminal-started too): `applying`,
       `showingLog` and `_follow`, and queue and remove are refused. If not
       `ours`, the first log line is "a rebuild started outside the panel".
     - Finished, `ours` and not `shown`: open the log, show the result
       once, then `--ack`.
     - Anything else (`none`, a terminal run's result, already shown):
       nothing.
   - **`Menu.qml`** `open()` focuses the keys when `applying` turns true
     from that async reply, through a signal from the model.
   - **Unchanged:** Esc hides the log and never stops the build; `l`;
     `rebuilding…`; `a a` with `--expect`; "checking…".
8. **Unchanged guarantees from #10.**
   - Only the checked, `--expect`-pinned state is built.
   - Preflight and apply errors reach the panel as `{"error"}` JSON.
   - The end of an apply comes only from `apply-status`, which reads unit
     state, so a build cannot forge it.
   - No new elevation path.
   - Tests never reach the real nixarchy-apply, `systemd-run`, `systemctl`
     or `journalctl`.
9. **nixarchy follow-up (D6), opened after merge.** It asks for:
   - `nixarchy-apply --status [--json]`;
   - `--log [--follow] [--invocation ID]`;
   - a pinned input for `--detach` (`--expect-sha256 <part>=<sha>`,
     checked in the unit before the copy);
   - the unit name and its SubState protocol as a stated interface.
10. **The live check runs on razer only, reserved by the user.** It
    includes #22's remaining checks. The PR says `Closes #22` only if every
    one of them passes.

## Steps

Each step names the check that must pass before the next one starts. The
PARR PLAN phase cites the step number.

1. **Rebase onto `main` after #15 merges.** The merge order is
   #21 → #15 → #23. #15 changes the log view and the scroll keys in
   `Menu.qml` and `FlatsnapModel.qml`, and this work builds on that.
   `git fetch origin && git rebase origin/main`, then re-read
   `FlatsnapModel.qml` (`reset`, `showLog`, `_startApply`, `_ended`,
   `_apply`, `_log`), `Menu.qml` (`open`, the key handler) and
   `bin/nixarchy-flatsnap` (`cmd_apply`, `lock_state`, `flake`). Fix any
   line reference in this plan that moved, in its own commit.
   → verify by: `bash tests/cli.sh` and `bash tests/model.sh` are green on
   the rebased base before any edit.

2. **`tests/isolate.sh`: guard the three new tools.**
   `assert_isolated <PATH> <stubdir>` checks that `nixarchy-apply`,
   `systemd-run`, `systemctl` and `journalctl` each resolve to
   `<stubdir>/<name>`, and aborts the file otherwise. Update both callers:
   `tests/cli.sh:341` and `tests/model.sh:30`. Add `readlink` to the
   `isolated_path` tools list in both.
   → verify by: with one stub missing, and again with a store link to the
   real `systemctl` in the tools dir, each file prints `ABORT` and exits 1
   before any case runs. The missing stub then goes back.

3. **`tests/cli.sh`: stubs and cases, written before the code.** In `$ab`:
   - a `systemd-run` stub that logs its argv to `$SDRUN_LOG`, exits
     `${SDRUN_RC:-0}`, and otherwise runs the argv after `--` synchronously
     with `INVOCATION_ID=0123456789abcdef0123456789abcdef` and each
     `--setenv` applied;
   - a `systemctl` stub that logs its argv and answers `show` from
     `$UNIT_FIXTURE`, as `KEY=VALUE` lines, or with `--value`;
   - a `journalctl` stub that logs its argv and prints `$JOURNAL_FIXTURE`.

   Cases, from the spec's table:
   1. the launcher's happy path and its `systemd-run` argv;
   2. `running` gives exit 3, and `systemd-run` is not called;
   3. `failed` gives `stop` and `reset-failed` before the start;
   4. `systemd-run` failing gives exit 3 "could not start";
   5. a stale `--expect` in the unit gives exit 2, with no copy;
   6. an edit in the gap gives exit 2, with no copy;
   7. `APPLY_RC=4` gives in-unit exit 4;
   8. no `INVOCATION_ID` gives exit 2;
   9. the marker reads `<id> new`;
   10. `apply-status` maps dead, running, exited+success, failed(4) and an
       empty ID;
   11. `ours` true or false;
   12. `--ack` with a match, a mismatch and garbage;
   13. the `apply-log --follow` argv;
   14. `apply-log ../x` gives exit 2;
   15. #10's cases are still green. Existing cases that expected the
       streamed build or the `nixarchyFlatsnapApply` record on the
       launcher's stdout now drive the in-unit run through the stub.

   → verify by: the new cases fail against the unchanged CLI, for the
   right reason: unknown verb or argument.

4. **`bin/nixarchy-flatsnap`: launcher, in-unit run, and verbs**
   (decisions 1-6).
   - `unit=nixarchy-rebuild` sits next to `flake()`, with a `ponytail:`
     comment: "nixarchy's --detach unit; ask nixarchy-apply --status once
     the follow-up lands".
   - `cmd_apply` splits into the launcher and `apply_in_unit`.
   - Add `cmd_apply_status` and `cmd_apply_log`, `main` dispatch for
     `apply-status` and `apply-log`, and the usage line.

   → verify by: `bash tests/cli.sh` all green, and `shellcheck` is clean.
   Mutations: removing the in-unit hash re-check turns 5 and 6 red;
   removing the `running` guard turns 2 red; removing the in-unit
   `exit $rc` turns 7 red. Each is restored after.

5. **`flake.nix`: `systemd` in the terminal package's `runtimeInputs`**
   (`flake.nix:56`). Edit it with Bash (`sed`), not the editor.
   → verify by: `nix flake check -L` passes shellcheck and `checks.cli`.

6. **The panel** (decision 7).
   - `FlatsnapModel.qml`: `_invocation`, `_follow`, `_poll` and a status
     Process; the new `_apply` records; `reset()` runs the status query;
     `_ended` messages; `--ack`.
   - `Menu.qml`: the focus signal.
   - `tests/model.sh`: the same three stubs, with an `apply-status`
     fixture the test swaps.
   - `tests/model.qml`: model cases 1-7 from the spec.
     1. `a a` starts `_follow`.
     2. `failed` exit 4 ends "apply failed (exit 4)" and runs `--ack`.
     3. Reopening on a terminal-started `running` run refuses `queue()`.
     4. Reopening on our finished, unshown run shows it once.
     5. Shown, not ours, or `none` shows nothing.
     6. A forged `{"nixarchyFlatsnapApply"}` line from `_follow` does not
        end the apply.
     7. "already running" leaves `applying` false.

   → verify by: `bash tests/model.sh` all green, and the stub
   nixarchy-apply is the only one invoked.

7. **`README.md`, the apply section.** The build runs as the user unit
   `nixarchy-rebuild` and survives a shell restart. Follow it from a
   terminal with `nixarchy-flatsnap apply-log --follow`. A second apply
   during a rebuild is refused.
   → verify by: the README's keys and commands match `main` dispatch.

8. **The whole suite.**
   → verify by: `bash tests/cli.sh`, `bash tests/model.sh` and
   `nix flake check -L` are all green.

9. **Live check on razer.** This folds in #22's remaining checks.
   - **Reserve razer.** The bus claim alone has failed three times. Before
     anything else, the user is asked to reserve razer and to stop other
     agents' sessions on it. Then post the claim on the agent bus.
     **Never on p620.**
   - **Setup**, following plan/2026-09-24-10-apply-safety.md, "Live check,
     third attempt (#22)":
     - Clone razer's current nixos_config source to `/tmp/flake-23` on
       razer, with `programs.nixarchy.flake = lib.mkForce "/tmp/flake-23"`
       and the `nixarchy/nixarchy-flatsnap` input overridden to this
       branch's head.
     - Build on p620, `nix copy` it to razer, then
       `switch-to-configuration test`. Record the starting generation and
       the plugin link first.
     - Back up any existing `~/.config/nixarchy/flatsnap.nix`.
     - Relaunch the shell through `hyprctl dispatch` with
       `NIXARCHY_FLAKE=/tmp/flake-23`, since razer's session exports
       `/etc/nixos`. Confirm the value from `/proc/<pid>/environ`.
       Gotcha: kill the shell by pid, not with a bare `quickshell kill`.
   - **Checks, in one real apply.** Queue one small entry, as #22 did.
     1. `a a`. The log shows the change lines, then the build from the
        journal.
     2. During the build, Esc hides the log, the tab line shows
        `rebuilding… l shows it`, and the build keeps running
        (`systemctl --user show -p SubState nixarchy-rebuild` says
        `running`).
     3. `l` brings the log back.
     4. Close and reopen the panel. It opens on the running apply's log.
     5. `d` on a declared row (and Enter on a search result) is refused
        with the rebuild message.
     6. **New:** `omarchy-restart-shell` mid-build. The unit stays
        `running`. The reopened panel opens on the log from its start,
        with `rebuilding…`.
     7. The build ends, and the panel shows `— applied —`. A new generation
        exists.
     8. **New:** repeat the restart with the panel closed until the build
        ends. The first reopen shows "applied" once, and a second reopen
        shows nothing.
     9. `pkexec` elevated from the unit. Then `passwordless`, if razer's
        sudo allows it. Otherwise, record that it was not checked.
   - **If disrupted** (an outside shell restart before step 6, keystrokes
     that are not ours, another session): restore and stop. No retry.
   - **Restore, always.**
     - `switch-to-configuration switch` of the recorded starting generation.
     - Put the plugin link back.
     - Restore or remove `flatsnap.nix`.
     - `systemctl --user stop nixarchy-rebuild; systemctl --user reset-failed nixarchy-rebuild`.
     - `rm -rf /tmp/flake-23`, the marker and `flatsnap.nix.lock`.
     - Confirm 0 failed units, system and user.
     - Release the claim.

   → verify by: each check's outcome is recorded in this plan under
   "Live check (#22, #23)", with the evidence: log lines, `systemctl` state
   and the generation number.

10. **PR against `main`.**
    - Link `intent/`, `spec/` and `plan/2026-09-24-23-detach-apply.md`.
    - `Closes #23`. `Closes #22` **only if** step 9's checks 1-7 all passed.
      Otherwise use `Refs #22`, and say what is still open.
    - Any deviation is written into this plan in the same commit as the
      code.

    → verify by: CI (`nix flake check -L`) is green on the PR.

### Post-merge

11. **Open the nixarchy follow-up** (decision 9) on olafkfreund/nixarchy.
    Search for a duplicate first, and link it from #23.
    → verify by: the issue URL is recorded here.

## Tests

Nothing here reaches the real `nixarchy-apply`, `systemd-run`, `systemctl`,
`journalctl`, `nh` or `nixos-rebuild`. `tests/isolate.sh` aborts if it
could.

```
bash tests/cli.sh      # "N passed, 0 failed"; ABORT if any of the four tools is not the stub
bash tests/model.sh    # "model: N passed, 0 failed" (needs a Wayland session)
nix flake check -L     # shellcheck + checks.cli in the sandbox
```

The mutation checks are in steps 2 and 4. The live check (step 9) runs on
razer only.

## Rollback

- **Before merge:** drop the branch. Nothing outside the repo changed.
- **After merge:** `git revert` the merge commit.
  - The panel goes back to the in-shell `Process`.
  - A leftover `nixarchy-rebuild` unit is harmless: `nixarchy-apply
    --detach` resets a finished one.
  - The marker file under `$XDG_STATE_HOME/nixarchy-flatsnap/` is ignored,
    and can be removed.
  - `flatsnap.nix` keeps its format.
- **On razer:** the restore in step 9.
