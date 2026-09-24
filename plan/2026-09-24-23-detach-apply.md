---
status: approved
issue: 23
spec: spec/2026-09-24-23-detach-apply.md
---

# Plan: a running apply survives a shell restart and is found again

Line numbers were written for `main` at 7d2ff26. Step 1 rebased onto
e176454 (#21 and #15 merged). The numbered references to `bin/`, `tests/`
and `flake.nix` did not move, and `FlatsnapModel.qml` and `Menu.qml` are
named by function here. `nixarchy-apply:N`
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
   **Deferred (user decision, 2026-09-24).** This step runs in one combined
   razer session with #15 and #22. That session waits until the unknown
   deployer is found: it keeps rewriting `nixarchy.distrobox` and
   restarting the shell. Until then the PR stays a draft with `Refs #22`.
   - **Reserve razer.** The bus claim alone has failed three times. Before
     anything else, the user is asked to reserve razer and to stop other
     agents' sessions on it. Then post the claim on the agent bus.
     **Never on p620.**
   - **Setup**, following plan/2026-09-24-10-apply-safety.md, "Live check,
     third attempt (#22)":
     - Clone razer's current nixos_config source to `/tmp/flake-23` on
       razer, with `programs.nixarchy.flake = lib.mkForce "/tmp/flake-23"`
       and the `nixarchy/nixarchy-flatsnap` input pinned to this branch's
       head. Edit only the nested flatsnap node's `locked` entry in
       `flake.lock`, not `--override-input` (#15's lesson).
     - Build on p620, `nix copy` it to razer, then
       `switch-to-configuration test`. Record the starting generation and
       the plugin link first.
     - Back up any existing `~/.config/nixarchy/flatsnap.nix`.
     - Relaunch the shell through `hyprctl dispatch` with
       `NIXARCHY_FLAKE=/tmp/flake-23`, since razer's session exports
       `/etc/nixos`. Confirm the value from `/proc/<pid>/environ`.
       Gotchas:
       - Kill `omarchy-launch-shell` first, because it relaunches the shell
         in a loop (#15's lesson).
       - Then kill the shell by pid, not with a bare `quickshell kill`.
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

## Deviations during implementation

- **Step 4, launcher order.** The `running` check comes before preflight,
  not after the regenerate. A running build holds the state lock until it
  ends, so preflight would wait 30 s on it and then fail with a lock
  message instead of "already running". A finished unit is still stopped
  and reset only after every check has passed, just before the start. The
  change lines are printed after the unit check, so a refusal is one line.
- **Step 4, the pinned hash.** After the regenerate, the launcher re-reads
  the file and hashes that. A hand edit's dropped attributes (#10 case 3)
  would otherwise give a hash the unit's re-read can never match.
- **Step 4, the terminal hint** ("Rebuilding in the background…") goes to
  stderr. The panel's stdout stays records and change lines only.
- **Step 3/4, tests.** `env` joins the isolated tools list in
  `tests/cli.sh` (the systemd-run stub runs the unit's command through
  it). `INVOCATION_ID` is unset with the other hermetic variables, because
  a test run from inside a systemd unit inherits one.

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

## Live check on razer (#23, #22, #33), 2026-09-24 22:16–22:35 BST

One combined session, run once. The user reserved razer and suspended
p620-a1c969's #25 claim for the window. The claim is bus `$rGk1os6Z…` and
"done" is `$sqS4aObZ…`. Nothing from outside disrupted the run.

- **Setup.**
  - `/tmp/flake-23` was nixos_config 20b655c24. Unchanged, it evaluates to
    razer's gen 2954 toplevel (`06kpcydy…`).
  - Only the `nixarchy-flatsnap` node's `locked` entry was edited, to
    point at 64c9c94.
  - `programs.nixarchy.flake` was forced to `/tmp/flake-23`.
  - Built on p620 (`qivj46ks…`). `diff-closures` against 2954 showed only
    `nixarchy-flatsnap`.
  - `nix copy --no-check-sigs` to razer. Without the flag, the copy failed
    with "lacks a signature by a trusted key".
  - `switch-to-configuration test`: the plugin link moved to `8dx0n9s5…`,
    and nixarchy-apply's fallback flake is `/tmp/flake-23`.
  - Shell relaunch: the `omarchy-launch-shell` loop was killed first, then
    the shell was started through `hyprctl dispatch` with
    `NIXARCHY_FLAKE=/tmp/flake-23`.
  - `pgrep -f quickshell-wrapped_` also matches the ssh command that runs
    it. Use `pgrep -x .quickshell-wra`.
- **Driving.** wtype and grim over ssh, with the shell's own
  environment, and `omarchy-shell shell toggle nixarchy.flatsnap`.

### (A) #23

| Check | Result | Evidence |
|-------|--------|----------|
| Real apply through the `nixarchy-rebuild` unit ends "applied" | **pass** | See the notes below. |
| Elevation from the user unit | **pass (passwordless)**. pkexec **unverified** | razer's `sudo -n true` succeeds, so apply chose `passwordless`. The journal shows `NH_ELEVATION_STRATEGY=passwordless` and root sudo sessions for the `test` and `boot` steps. pkexec from a user unit is a follow-up issue, opened after merge (user decision). |
| Shell restart during the build | **pass** | See the notes below. |
| A result that finished while no panel watched is shown exactly once | **pass, with a method note** | See the notes below. |
| "Already running" | **pass** | `nixarchy-flatsnap apply --expect 000…0` during the build answered `rc=3 {"error":"a rebuild is already running — l shows it"}`. Nothing was started. `nixarchy-apply --detach` was not used (user decision). |

- **Real apply.**
  - Invocation `a758f52a…`: `a a` at 22:23:18, and the unit ended at
    ~22:24:33 with `SubState=exited Result=success ExecMainStatus=0`.
  - The panel log ended `— applied —`.
  - Gen 2955 was built from `/tmp/flake-23`: the copies were staged there,
    `flatsnap.nix` was added, snapd became active, and hello-world was
    installed.
- **Shell restart during the build.**
  - `omarchy-restart-shell` at 22:24:09. The shell pid went 2604299 →
    2627755, and the unit stayed `running`.
  - The reopened panel opened on the log. Scrolled to the top, the log
    starts with the unit's first line (`Started [systemd-run] …
    apply --in-unit --expect b24d…`), so it was reloaded from the
    journal.
  - The relaunched shell had `NIXARCHY_FLAKE=/etc/nixos`. The build was
    not affected, because the flake reached the unit through `--setenv`.
- **Finished while no panel watched.**
  - The natural sequence did not happen. The switch's Hyprland reload had
    already closed the panel (nixarchy#919), so the "close" toggle
    reopened it, and the watcher ended the run itself: `— applied —`,
    marker `a758f52a… shown`.
  - The unseen-result path was then exercised against the real, finished
    unit and CLI:
    1. With the panel closed, the marker was set back to
       `a758f52a… new`.
    2. The first reopen showed the log from the journal, ending
       `— applied —`, and the marker went to `shown`.
    3. The second reopen showed nothing, with `l log` offered.
  - Only the marker reset was simulated.

### (B) #22

| Check | Result | Evidence |
|-------|--------|----------|
| The real apply ends `— applied —` | **pass** | As in (A). |
| Esc during the build keeps it running | **pass** | The tab line shows `rebuilding… l shows it`, and the unit stays `running`. |
| `l` brings the log back | **pass** | |
| Close and reopen shows the running apply | **pass** | The panel reopened on the log with the build still running. |
| `d` refused | **pass** | "a rebuild is running — wait for it to finish". |
| Enter (queue) refused | **not verified** | The lookup did not bring up a card before the second Enter. The message on screen may have been left over from `d`. `flatsnap.nix` was unchanged. The model tests cover it; live, it stays open. |

### (C) #33 (#15's deferred checks)

| Check | Result |
|-------|--------|
| Scale 2: the card scrolls with j, k, Up, Down, PgUp and PgDn (Down = one line; PgUp back to the top) | **pass** |
| The "↓ more (j)" marker, hidden at the bottom | **pass** |
| A new card (`code`) opens at the top after the old card was scrolled | **pass** |
| `p` scrolls the overrides field into view with the keyboard in it; `j` types `j`; Up leaves the field and scrolls; then `j` scrolls | **pass** |
| PgUp and PgDn from inside the overrides field | **pass** |
| Scroll keys keep an armed queue confirmation ("Enter again: … Context.shared=network"); `c` disarms it | **pass** |
| The list keeps the cursor row visible at scale 2 (Ctrl+F "editor", j ×16) | **pass**, no `positionViewAtIndex` needed |
| The footer shows only the current view's keys (add, card flatpak and snap, declared, log) | **pass** |
| Scale 1: no marker when the card fits; shorter footers | **pass** |
| The log follows only at the end, and the scroll keys work during a real apply | **not verified** |

The log-follow check could not be judged. While the build ran, the log was
shorter than the view: the evaluation printed only a few lines, and the
build took ~75 s. So scrolling up had nothing to hold against. After the
end, PgUp to the top of the long log works, and the marker shows.

Also seen, all cosmetic and none from this task:

- At scale 2, the footer wraps.
- At scale 2, the armed red message covers the card's last line.
- In the Add view the footer offers `l log`, but the field has the keys,
  so `l` types an `l`.
- The log footer still says "the build carries on" after the build has
  ended.

### Restore (verified by end state)

- **Generation.** `switch-to-configuration switch` of system-2954-link.
  Then the profile was switched back to 2954, gen 2955 was deleted, and
  `boot` ran. The profile is `system-2954-link`, and `/run/current-system`
  is `06kpcydy…`.
- **Plugin and shell.** The plugin link is back on `ziwc8…`. One shell is
  running, relaunched through `hyprctl` with `NIXARCHY_FLAKE=/etc/nixos`,
  with one `omarchy-launch-shell`. eDP-1 is 1920x1080 at scale 1.
- **Snaps.**
  - `snap remove --purge hello-world`.
  - Mistake: `core` was removed too, but it pre-existed (it was not in
    this run's snap change 50). It was reinstalled at the same rev 17292.
  - The other snaps and their mounts (active since 2026-09-23) are
    untouched.
- **Files and unit.** `flatsnap.nix` and its lock, the marker directory,
  `/tmp/flake-23` and the helper files are removed. The unit is stopped,
  reset and `dead`.
- **Health.** 0 failed units, system and user.

## Post-merge note (2026-09-24)

PR #34 merged as 1a04bc1, and #23 is closed. The follow-ups:

- **Step 11, the nixarchy follow-up (decision 9):**
  olafkfreund/nixarchy#979. It asks for `--status` and `--log`, a pinned
  input for `--detach`, and the unit name as an interface. The search found
  no duplicate; the closest open issue is nixarchy#967, which it references.
- **pkexec from the user unit is unverified** (razer has NOPASSWD sudo):
  olafkfreund/nixarchy-flatsnap#35. It needs a host where sudo asks for a
  password.
- **Three cosmetic findings from #15:** olafkfreund/nixarchy-flatsnap#36.
  - At scale 2 the footer wraps, and the red confirmation covers the card's
    last line.
  - The Add view offers `l log` while the field has the keys.
  - The log footer still says "the build carries on" after the build has
    ended.
- **#22 closed as completed.** Its substance passed live: the real apply
  to `— applied —`, Esc, `l`, reopen, and `d` refused. Enter-refused is
  covered by `tests/model.qml`. The evidence is in its comment.
- **#33 stays open, retitled to its one remaining check:** the apply log
  follows only at the end, and the scroll keys work, during a real build.
  Every other check passed.

## Live check (#33, #35), 2026-09-25

This was one user-reserved razer session (claim `$Tx-y3Ts…`). The setup
and #33's results are in plan/2026-09-24-15-card-overflow.md under the same
heading. #33 passed.

### #35: pkexec from the `nixarchy-rebuild` user unit, not verified

- **Preparation (done).**
  - razer's `sudo -n true` succeeds, so apply would choose `passwordless`.
    For one apply the shell was relaunched with
    `NH_ELEVATION_STRATEGY=pkexec`, which `elevation()` respects, and
    `NIXARCHY_FLAKE=/tmp/flake-33`. razer's sudo configuration was not
    changed.
  - Confirmed from `/proc/<pid>/environ`.
- **Relevant finding.** razer's polkit rule for nh gives
  `AUTH_ADMIN_KEEP` to `org.freedesktop.policykit.exec` of `env` **only
  when `subject.local && subject.active`**. A process in `user@.service`
  may not count as being in an active session. So each of nh's three
  elevations (profile build, `test`, `boot`) may prompt separately, or be
  refused. That is exactly the open question.
- **The polkit agent** is the Omarchy shell itself. No separate agent
  process runs.
- **What happened.**
  - While the check waited for the user, p620-08903c deployed razer at the
    user's direction ("flatsnap is finished, go now"). The deploy made
    **generation 2957** (nixos_config main ce3014c64), razer's new
    baseline, and replaced the shell with one that had
    `NIXARCHY_FLAKE=/etc/nixos` and no `NH_ELEVATION_STRATEGY`.
  - The `a a` sent at 00:13 then reached the new shell's launcher search,
    not the flatsnap panel. No apply started: the unit's `InvocationID`
    stayed `2cfff8a7…`, and no `pkexec` process appeared.
- **Not verified:** the approved-prompt path to `— applied —`, the number
  of prompts, and the cancelled-prompt path ("apply failed (exit N)").
  #35 stays open.
  - It needs a new window on razer's 2957 baseline, with a clone of 2957's
    nixos_config.
  - Or it needs a host whose sudo asks for a password.

### Restore (verified by end state)

- **No rollback.** 2957 is the baseline, and it was not switched or
  changed.
- **Generations.** My generations 2955 and 2956 are deleted
  (`nix-env --delete-generations 2955 2956`). The list is now 2952, 2953,
  2954 and 2957 (current).
  - `switch-to-configuration boot` of the current profile (2957) removed
    the stale `nixos-generation-2956` Lanzaboote entry. /boot now holds
    2954 and 2957 only.
- **Files and unit.**
  - `flatsnap.nix`, its lock and the apply marker are removed. The
    `nixarchy-rebuild` unit is stopped and reset (not-found, dead).
  - `/tmp/flake-33` (razer and p620) and `/tmp/zz-vl` are removed.
  - eDP-1 is at scale 1. One shell runs, 08903c's, with
    `NIXARCHY_FLAKE=/etc/nixos` and no `NH_ELEVATION_STRATEGY`.
  - 0 failed units, system and user.
- **Not restored: the hello-world snap.**
  - 2957 has no snapd, because snapd came only from the test generations'
    `flatsnap.nix`. So `snap remove --purge hello-world` is not
    available.
  - `/var/lib/snapd/snaps/hello-world_29.snap` remains, and so does its
    transient mount unit `/run/systemd/system/snap-hello\x2dworld-29.mount`
    (active). The mount unit is gone at the next reboot.
  - Removing the snap needs snapd running, for example a short
    `switch-to-configuration test` of a config with snapd. That is left to
    the user.
  - `core` and the other pre-existing snaps were not touched.
