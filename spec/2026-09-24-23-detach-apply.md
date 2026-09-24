---
status: approved
issue: 23
intent: intent/2026-09-24-23-detach-apply.md
---

# Spec: a running apply survives a shell restart and is found again

Line numbers are for `main` at 7d2ff26. `nixarchy-apply:N` means
`/nix/store/dcn12ll9cmzph7bjr0ijax8pnd4w2jmn-nixarchy-apply/bin/nixarchy-apply`,
the build installed on p620, which I only read.

## Design

### D1: the whole checked apply runs in the unit, not only nixarchy-apply

The gap the intent names comes from `nixarchy-apply --detach` running the
copy (`nixarchy-apply:100-120`) in a new process, after its caller has
returned (`:58-61`). A flatsnap-side check and lock cannot cover that
process, so this spec does not call `--detach`. flatsnap starts the unit
itself, and **the unit runs flatsnap's own apply**. That process takes the
state lock, re-checks the state against the confirmed hash, and then runs
`nixarchy-apply --yes --no-preview` in the foreground, as `cmd_apply` does
today. The check, the copy and the build all happen in one process under
one lock. That is #10's guarantee, and the process now outlives the shell.

The unit copies nixarchy's `--detach` unit on every point that makes it
safe:

- Same unit name, `nixarchy-rebuild`. A terminal `nixarchy-apply --detach`
  and a panel apply exclude each other: each sees the other `running` and
  refuses (`nixarchy-apply:37-42`, and D2 step 4). systemd itself refuses a
  second `systemd-run --unit=` of an active unit. So two starts that race
  still yield one build.
- The same properties: `-p RemainAfterExit=yes -p LogRateLimitIntervalSec=0`,
  no `--collect`, no `NoNewPrivileges` (`nixarchy-apply:49-54`).
- Elevation is unchanged. pkexec, or `passwordless` when `sudo -n true`
  already succeeds, is decided in the launcher as today
  (`bin/nixarchy-flatsnap:617-625`) and passed in as `NH_ELEVATION_STRATEGY`.
  nixarchy's own `--detach` already runs this same pkexec path from this
  same kind of unit (`nixarchy-apply:49, 57`). No new path to root.

### D2: `apply` splits into a launcher and an in-unit run

`cmd_apply` (`bin/nixarchy-flatsnap:589-645`) becomes the launcher. Its
stdout stays the panel's channel for errors.

1. Parse `--expect <hash>` as today (`:590-597`), plus the internal
   `--in-unit` (D3). Any other argument still exits 2.
2. The file check (`:599-600`) and preflight (`:603-604`) are unchanged. Any
   failure is still one `{"error":…}` line, exit 2.
3. `load_state`, `check_entries`, the `--expect` comparison, the
   regenerate and the change lines (`:607-617`) are unchanged.
4. **Unit state.** Read
   `systemctl --user show -p SubState --value nixarchy-rebuild`:
   - `running` or `start*`: print
     `{"error":"a rebuild is already running — l shows it"}` and exit 3.
     Exit 3 has the same meaning as `nixarchy-apply:41`.
   - `""` or `dead`: go on.
   - anything else (`exited`, `failed`): `systemctl --user stop` and
     `reset-failed`, as `nixarchy-apply:44-47` does. This discards that
     run's result, as nixarchy's own restart does.
5. `hash=$(state_hash)`: the confirmed hash, or, from a terminal with no
   `--expect`, the hash of the state just checked. A terminal apply gets the
   same pin.
6. Release the state lock (`exec {STATE_LOCK}>&-`), then start the unit:

   ```
   systemd-run --user --unit=nixarchy-rebuild \
     -p RemainAfterExit=yes -p LogRateLimitIntervalSec=0 \
     --setenv=PATH="$PATH" \
     --setenv=XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}" \
     --setenv=XDG_STATE_HOME="${XDG_STATE_HOME:-$HOME/.local/state}" \
     --setenv=NIXARCHY_FLAKE="$(flake)" \
     --setenv=NH_ELEVATION_STRATEGY="$elev" \
     --setenv=NO_COLOR=1 \
     -- "$(readlink -f "$0")" apply --in-unit --expect "$hash"
   ```

   - `NIXARCHY_FLAKE` is the flake that preflight evaluated. Today
     nixarchy-apply picks its flake again on its own, so this makes the
     build and the check agree by construction.
   - `NO_COLOR=1` is passed as a unit environment variable, because the unit
     does not inherit the caller's environment. nh already gets `--no-nom`
     with no tty (`nixarchy-apply:277-278`).
   - If `systemd-run` fails, print `{"error":"could not start the rebuild: …"}`
     and exit 3. This covers losing the race in step 4.
7. Print
   `{"nixarchyFlatsnapStarted":{"invocationId":"<32 hex>"}}` and exit 0.
   The ID comes from `systemctl --user show -p InvocationID --value
   nixarchy-rebuild`. Also print, for a terminal:
   `Rebuilding in the background. Follow it with: nixarchy-flatsnap apply-log --follow`.

### D3: `apply --in-unit --expect <hash>`, the process the unit runs

1. It requires `--expect` and `$INVOCATION_ID` (systemd sets it for every
   unit). Without them it exits 2.
2. It writes the marker `$XDG_STATE_HOME/nixarchy-flatsnap/apply`, containing
   `<INVOCATION_ID> new`, through a temp file and `mv`. The run itself
   writes the marker, not the launcher, so a launcher killed right after
   `systemd-run` still leaves it right.
3. `load_state`, which takes the lock and holds it until this process
   exits, then `check_entries` and the hash comparison. On a mismatch it
   prints "the declared set changed since you confirmed; press a again" and
   exits 2. The unit ends `failed` and nothing was copied. An `add` or `rm`
   in the launcher-to-unit gap therefore cannot get built unseen. It makes
   the run fail and say why.
4. Regenerate, then run `nixarchy-apply --yes --no-preview` through the
   existing filter (`:626-635`, unchanged, including the escaping of
   forged records). Its output goes to the journal. It prints the existing
   `{"nixarchyFlatsnapApply":…}` record (`:637-643`) for a terminal reader,
   then **exits with nixarchy-apply's rc**, or the filter's rc if that is
   non-zero. That value becomes the unit's `ExecMainStatus`. Today
   `cmd_apply` exits 0 after printing the record.

### D4: two read-only verbs, and an acknowledgement

- **`apply-status [--ack <id>]`** runs
  `systemctl --user show -p SubState,Result,ExecMainStatus,InvocationID
  nixarchy-rebuild` and prints one line:
  `{"state":"none|running|succeeded|failed","result":"…","exit":N,"invocationId":"…","ours":bool,"shown":bool}`.
  - `none` means `SubState` is `dead` or empty, or `InvocationID` is empty.
    The state is never read from `Result` alone: a dead unit reads
    `Result=success ExecMainStatus=0` (checked read-only on p620). That is
    the trap `nixarchy-apply:51-52` warns about.
  - `running` means `running` or `start*`. `succeeded` means `exited` with
    `Result=success`. `failed` means `failed`, or `exited` with any other
    `Result`.
  - `ours` means the marker's ID equals `InvocationID`. `shown` means the
    marker says `shown`.
  - `--ack <id>` (32 hex characters, checked) rewrites the marker to
    `<id> shown`, but only if it currently names `<id>`. This is the verb's
    only write, and it goes only to flatsnap's own state directory.
- **`apply-log [<id>] [--follow]`** runs
  `journalctl --user -u nixarchy-rebuild --invocation=<id> -o cat --no-pager -n 2000`,
  plus `-f` with `--follow`. The ID defaults to the unit's current
  `InvocationID` and is checked as 32 hex characters.
  `--invocation` is in journalctl 257 and later; p620 has 261. Filtering by
  invocation keeps an earlier run's lines out. The limit of 2000 lines
  matches the panel's cap (`FlatsnapModel.qml:346-350`).

### D5: the panel

In `FlatsnapModel.qml`:

- **`_startApply()`** (`:301-307`) keeps its command. **`_apply`**
  (`:315-344`) now ends at one of two records:
  - `{"error"…}` sets `applying = false` and calls `_ended(error)`. This
    covers exit 3, "already running".
  - `{"nixarchyFlatsnapStarted"}` sets `_invocation = id` and starts
    `_follow` and `_poll`.
  - Every other line is logged, as today (the change lines).
  - `onExited` with neither record keeps today's "the apply ended without a
    result" message.
  - The `{"nixarchyFlatsnapApply"}` branch goes. The panel no longer ends
    an apply from any line of a text stream.
- **`_follow`**, a new Process: `apply-log <id> --follow`, where each line
  goes to `_log`. It is stopped when the run ends. A shell restart kills it
  harmlessly: the build is not its child.
- **`_poll`**, a new Timer (2 s, running while `applying`) that runs
  `apply-status`. When `invocationId` is the one being watched and `state`
  leaves `running`:
  1. stop `_follow`;
  2. reload the log once with `apply-log <id>`, which replaces `applyLog`,
     so nothing the follower missed is lost;
  3. `applying = false`;
  4. `_ended("applied")` or `_ended("apply failed (exit N)")`. For
     `Result=signal`, `"apply failed (killed)"`;
  5. `apply-status --ack <id>` if `ours`;
  6. `list()`.
- **On open.** `reset()` (`:45-49`) runs `apply-status` once, and:
  - `running`: `applying = true`, `showingLog = true`, `_invocation = id`,
    start `_follow` (from the run's start, D4) and `_poll`. This includes a
    rebuild started from a terminal. It copies `flatsnap.nix` too, so queue
    and remove are refused with `_rebuilding` (`:186, 238`), which is
    #10's D4. The first log line names who started it when `ours` is false:
    "a rebuild started outside the panel".
  - `succeeded` or `failed`, with `ours` and not `shown`: `showingLog = true`,
    load `apply-log <id>`, `_ended(...)` as above, then `--ack`. This shows
    the result once, including after a shell restart.
  - Anything else, including `none` and a terminal run's result: nothing,
    as today.
  - `Menu.qml:30-37` stays. It focuses the keys when `fs.applying`, and
    `applying` is now set asynchronously. So the status reply calls
    `root.focusKeys()` through a signal when it sets `applying`.
- **Unchanged:** Esc never stops the build (it only hides the log), `l`,
  the `rebuilding…` mark (`Menu.qml`), `--expect` from the second `a`, and
  "checking…".

The README apply section says that the build now runs as the user unit
`nixarchy-rebuild`, survives a shell restart, and can be followed from a
terminal with `nixarchy-flatsnap apply-log --follow`.

### D6: nixarchy follow-up (to file, not opened by this task)

"nixarchy-apply: a status and log interface for detached runs, and a pinned
input". It asks for:

- `nixarchy-apply --status [--json]`, which returns state, result, exit and
  invocation;
- `nixarchy-apply --log [--follow] [--invocation ID]`;
- a way to pin what `--detach` copies (`--expect-sha256 <part>=<sha>`,
  checked in the unit before the copy), so `advanced.nix` gets the same
  guarantee (#10 intent, open question 3);
- the unit name and its SubState protocol as a stated interface.

When that lands, D2 step 6 and D4 can call nixarchy instead of `systemd-run`
and `systemctl` or `journalctl` directly. D3's in-unit check could then be
replaced by the pinned input.

## Alternatives rejected

- **Call `nixarchy-apply --detach` and hold the lock until the unit's copy
  is done.** The holder is the launcher, which dies with the shell, and that
  is the event this issue is about. If it dies between `systemd-run` and the
  copy, the lock is gone and the file can change before the copy. Finding
  out when the copy is done also means parsing `copied ->`
  (`nixarchy-apply:155`) from the journal, or polling the flake copy. Both
  are fragile, and a journal line can be forged by the build.
- **Call `--detach`, then re-verify the flake copy's hash after the fact.**
  By then the copy is being built. It detects the problem, but does not
  prevent it.
- **Hand nixarchy-apply the exact content.** This needs the nixarchy change
  in D6. It is the right end state, not something this plugin can do alone.
- **A unit of our own name, e.g. `nixarchy-flatsnap-apply`.** A terminal
  `nixarchy-apply --detach` would not see it, and two `nh os switch` could
  run at once.
- **Keep the build in the shell, and add a restart-proof status file
  only.** The build still dies with the shell.
- **Track "shown" in QML memory.** It is lost on the shell restart this is
  for.
- **Poll `apply-log` instead of following.** It rereads up to 2000 lines
  every 2 s during a long build. The follower and one final reload cost less
  and lose nothing.
- **Raise terminal-started finished runs too.** The intent decided they are
  not raised. Whoever started them already has their terminal.

## Risks

- **pkexec from a user unit.** The unit is in `user@.service`, not in the
  login session's scope, so polkit may see no active session. nixarchy's
  own `--detach` depends on the same thing (`nixarchy-apply:27-29, 49`),
  and `modules/AGENTS.md#the-rebuild-asks-through-polkit` says it works.
  Checked live on razer with both `pkexec` and `passwordless`.
- **Logout stops the unit.** The user manager takes it down, and the build
  with it, as for nixarchy's `--detach`. Out of scope. A reboot or logout
  during a switch is already a known hazard.
- **Coupling to nixarchy's unit name and SubState protocol.** If nixarchy
  renames the unit, exclusion breaks silently. D6 asks for it to become an
  interface. Until then, the name lives in one variable next to `flake()`,
  with a `ponytail:` comment naming the follow-up.
- **A finished result replaced before the panel sees it.** A terminal
  `nixarchy-apply --detach` resets our finished unit (`nixarchy-apply:44-47`),
  and the marker then does not match: nothing is shown. The run did happen,
  and the journal still has it.
- **`PATH` passed into the unit** is the shell's `PATH`. It is what the
  in-shell apply used today, so it resolves nothing new. If it lacked
  `nixarchy-apply`, preflight would already have refused.
- **Home Manager activation during the switch** restarts HM-managed user
  units (sd-switch). A transient `nixarchy-rebuild` is not HM-managed.
  This is checked live: the build must outlive the shell restart that the
  switch itself causes.
- **The launcher-to-unit gap** is now a refusal, not a silent build (D3
  step 3). An `add` right after `a a` makes the apply fail with "changed
  since you confirmed". That is correct, but visible.

## Verification

**CLI (`tests/cli.sh`).** `systemd-run`, `systemctl` and `journalctl` are
stubs in `$ab`, never store links. `assert_isolated` (`tests/isolate.sh:26-48`)
gains the same identity check it has for `nixarchy-apply` for these three,
and the file aborts if any of them is not the stub. The `systemd-run` stub
records its argv, sets `INVOCATION_ID` to a fixed 32-hex value, and runs the
command after `--` synchronously, so the in-unit run reaches the
`nixarchy-apply` stub. The `systemctl` stub answers from a fixture file that
the test writes. The `journalctl` stub prints a fixture and records its argv.

| # | Setup | Expect |
|---|-------|--------|
| 1 | `apply --expect <preflight hash>`, unit `dead` | exit 0; `nixarchyFlatsnapStarted` with the ID; `systemd-run` argv has `--unit=nixarchy-rebuild`, `RemainAfterExit=yes`, `NO_COLOR=1`, `NIXARCHY_FLAKE`, `NH_ELEVATION_STRATEGY`, `apply --in-unit --expect <hash>`; nixarchy-apply stub invoked once |
| 2 | unit `running` | exit 3; one `{"error"}` "already running"; `systemd-run` not invoked |
| 3 | unit `failed` | `stop` and `reset-failed` recorded before `systemd-run` |
| 4 | `systemd-run` stub exits 1 | exit 3, one `{"error"}` "could not start" |
| 5 | `apply --in-unit --expect <stale>` | exit 2; "changed since you confirmed"; nixarchy-apply stub not invoked |
| 6 | the stub edits `flatsnap.nix` between launcher and in-unit run | in-unit exits 2; nothing copied |
| 7 | `APPLY_RC=4`, in-unit run | exits 4 (becomes `ExecMainStatus`) |
| 8 | `apply --in-unit` without `INVOCATION_ID` | exit 2 |
| 9 | marker written | `<id> new` after the in-unit run |
| 10 | `apply-status`: dead / running / exited+success / failed+exit-code 4 / exited with empty InvocationID | `none` / `running` / `succeeded` / `failed`,`exit:4` / `none` |
| 11 | `apply-status`, marker = unit ID vs other ID | `ours` true / false |
| 12 | `apply-status --ack <id>` / `--ack <other>` / `--ack xyz` | marker `shown` / unchanged / exit 2 |
| 13 | `apply-log --follow` | journalctl argv has `--user -u nixarchy-rebuild --invocation=<id> -o cat -n 2000 -f` |
| 14 | `apply-log ../x` | exit 2, journalctl not invoked |
| 15 | existing #10 cases (preflight errors as JSON, forged records escaped, pkexec/passwordless) | still green |

Mutation checks, as #10 did:

- remove D3's hash re-check: red on 5 and 6;
- remove the `running` guard: red on 2;
- remove the in-unit exit rc: red on 7.

**Model (`tests/model.qml`, `tests/model.sh`).** These use the same stubs
under `isolate.sh`. `apply-status` answers come from a fixture the test
swaps.

| # | Action | Expect |
|---|--------|--------|
| 1 | `a a` | `applying`, `showingLog`; `_follow` running with `apply-log <id> --follow` |
| 2 | status goes `failed`, `exit:4` | `applying` false; last log line "apply failed (exit 4)"; `--ack <id>` run |
| 3 | `reset()` with status `running`, `ours:false` | `applying` true, `showingLog` true, `queue()` refused with `_rebuilding` |
| 4 | `reset()` with `succeeded`, `ours`, not `shown` | log view with "applied"; `--ack` run |
| 5 | `reset()` with `succeeded`, `shown` / `ours:false` / `none` | `showingLog` false, no log |
| 6 | a log line `{"nixarchyFlatsnapApply":{"ok":true}}` from `_follow` | `applying` still true |
| 7 | launcher prints `{"error":"a rebuild is already running…"}` | `applying` false, message shown |

**Checks.** `nix flake check`: shellcheck, and the tools list gains
`systemd` for the terminal package's `runtimeInputs` (`flake.nix:56`).

**Live, on razer only.** Claim razer on the agent bus first. Never on p620.

1. `a a`, then `omarchy-restart-shell` during the build. The build carries
   on (`systemctl --user status nixarchy-rebuild`). The reopened panel opens
   on the log, from the start, with `rebuilding…`. It ends "applied".
2. As 1, but close the panel and reopen it after the build ends. "applied"
   is shown once, and a second reopen shows nothing.
3. `a a` while a terminal `nixarchy-apply --detach` runs: "already running".
   The other way round, nixarchy-apply exits 3.
4. `a a`, then `nixarchy-flatsnap add` in the gap. The run fails with
   "changed since you confirmed", and the flake copy is unchanged.
5. The switch's own shell restart does not end the build (the #22 failure).
6. pkexec and passwordless both elevate from the unit.
