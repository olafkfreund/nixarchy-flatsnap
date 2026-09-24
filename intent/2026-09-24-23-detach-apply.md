---
status: draft
issue: 23
author: olafkfreund
---

# Intent: a running apply survives a shell restart and is found again

Builds on #10 (`intent/`, `spec/`, `plan/2026-09-24-10-apply-safety.md`),
whose spec listed `nixarchy-apply --detach` as a follow-up. Line numbers are
for `main` at 7d2ff26, and for nixarchy-apply as installed on p620
(`/nix/store/dcn12ll9cmzph7bjr0ijax8pnd4w2jmn-nixarchy-apply/bin/nixarchy-apply`).

## Problem

An apply only lives as long as the Omarchy shell that started it.

- The panel starts the apply as a Quickshell `Process`
  (`FlatsnapModel.qml:304-306, 315`), which is a child of the shell. That
  process runs `nixarchy-flatsnap apply --expect <hash>`. It runs
  `nixarchy-apply --yes --no-preview` in a pipe and streams its output
  (`bin/nixarchy-flatsnap:627-635`). nixarchy-apply then runs `nh os switch`
  (nixarchy-apply:279).
- Whatever ends the shell ends the whole chain: `omarchy-restart-shell`, a
  Home Manager activation, a Quickshell crash, or an outside
  `quickshell kill`. The system switch the apply makes can itself restart
  the shell.
- After a restart, `applying` (`FlatsnapModel.qml:37`) is back to its default
  `false`. The panel has no record that a build ran, how far it got, or how
  it ended. #10's guarantees (the `rebuilding…` mark, the `l` key, reopening
  onto the log: `FlatsnapModel.qml:45-52`) only hold while the shell lives.
  #10's spec names this as a known risk.
- This happened twice on razer on 2026-09-24, during #22's live check. An
  outside `quickshell kill` at 17:56:41 killed a live apply about 15 s in,
  before nixarchy-apply had copied anything.

What nixarchy already offers, as fact rather than as a chosen design.
`nixarchy-apply --detach` (nixarchy-apply:27-62):

- It needs `--yes` and exits 2 without it (`:31-34`).
- It reads the `SubState` of the user unit `nixarchy-rebuild` (`:37`). If a
  rebuild is `running` or `start*`, it prints a message and exits 3
  (`:38-42`). A finished unit, kept by `RemainAfterExit`, is stopped and
  `reset-failed` first (`:44-47`), so each detached run replaces the last
  run's result.
- It starts `systemd-run --user --unit=nixarchy-rebuild -p RemainAfterExit=yes
  -p LogRateLimitIntervalSec=0` (`:53-58`). The unit runs nixarchy-apply
  itself again with `--yes --no-preview`, with `NIXARCHY_FLAKE`,
  `XDG_CONFIG_HOME` and `NH_ELEVATION_STRATEGY` passed in (`:55-57`,
  pkexec by default). No `--collect`, so a failed unit keeps
  `Result=` readable (`:51-52`). There is no `NoNewPrivileges`, because
  elevation goes through the setuid pkexec (`:49`).
- The caller gets back only "Rebuilding in the background…" and exit 0
  (`:59-61`). The build's output goes to the user journal under
  `nixarchy-rebuild` (`journalctl --user -fu nixarchy-rebuild`). With no tty,
  nh runs with `--no-nom` (`:277-278`).
- Completion is not a line on stdout. It is the unit's state:
  `SubState=exited` (success) or `failed`, plus `Result` and
  `ExecMainStatus` (the script's own exit code: `nh`'s rc, `:279, 295`).
  This state lasts until the next `--detach` resets it, or until the user
  manager stops, for example at logout.
- The copy into the flake (`:100-120`) runs inside the unit, after the
  calling process has returned.

## Proposed outcome

- A shell restart, a Quickshell crash, or closing the panel during an apply
  does not stop the build. It runs to the end.
- A panel opened after such a restart shows that a rebuild is running, marks
  it the way #10 does (`rebuilding…`, `l`, reopening onto the log), and
  refuses queue and remove until it ends.
- The log of the running or last build can be shown from its start, not
  just from the moment the panel reopened.
- When the build ends, whether or not the panel was open, the panel reports
  success or failure with the exit code. It reads that from something the
  build log cannot forge.
- A second apply while one is running is refused with a message. It does
  not start another build or queue one behind the first.

## Affected users and systems

- nixarchy users with the flatsnap plugin and module installed, on any host.
  razer is where it was seen.
- `bin/nixarchy-flatsnap` (`cmd_apply`, and possibly a new read-only verb
  for status or log).
- `FlatsnapModel.qml` (`_apply`, `applying`, `reset()`, `open()`, log
  parsing) and `Menu.qml` (the activity mark).
- The user systemd manager and journal (unit `nixarchy-rebuild`), which are
  shared with nixarchy's own `--detach` callers. A terminal
  `nixarchy-apply --detach` and a panel apply use the same unit name.
- Possibly nixarchy's `nixarchy-apply` (see open question 1).
- `tests/cli.sh`, `tests/model.sh`, `tests/model.qml`, `tests/isolate.sh`.

## Constraints

- **Keep #10's guarantees.**
  - Only the checked, `--expect`-pinned state is built: the shape check,
    `check_entries`, the regenerate and the hash comparison
    (`bin/nixarchy-flatsnap:599-613`) still run before anything is built.
  - Preflight and apply errors reach the panel as `{"error":…}` JSON, never
    as empty output.
  - Only the tool's own end record ends an apply. No build output can end
    it.
- Under `--detach`, the flake copy happens inside the unit, after the CLI
  (and its state lock, `:276-286, 605`) has exited. The `--expect`
  guarantee must still hold across that gap. A write between the check and
  the copy must not get built unseen.
- **No new elevation path.** pkexec, or passwordless when `sudo -n` already
  allows it (`:617-625`), stays the only way to root. No new setuid, polkit
  rule, or system unit.
- The plugin still hands off to nixarchy-apply and never rebuilds around it
  (#10).
- **Tests never invoke the real nixarchy-apply**, `systemd-run`, `nh` or
  `nixos-rebuild`. Every test PATH goes through `tests/isolate.sh`, and
  anything new (`systemd-run`, `systemctl`, `journalctl`) is a stub there,
  never a store link to the real tool.
- Esc still never stops a running build (#10).
- Keyboard-only, and colours from the shell's theme tokens.
- Live checks run on razer, never on p620.

## Open questions

1. **Does it need a nixarchy-side change, meaning a status and log
   interface for detached runs?** Today a caller would read
   `systemctl --user show nixarchy-rebuild` and `journalctl` itself, which
   ties the plugin to nixarchy's unit name and properties. The `flake()`
   helper (`bin/nixarchy-flatsnap:512-523`) already works around a missing
   interface by reading nixarchy-apply's source with `sed`. The copy also
   running inside the unit, after flatsnap's lock is released, may need
   nixarchy to accept a pinned input, such as an expected hash or a
   pre-copied flake.
   *Recommendation:* ship on this plugin's side first, reading the unit
   through `systemctl show -p SubState,Result,ExecMainStatus` and
   `journalctl --user -u nixarchy-rebuild` behind one small CLI verb. Hold
   the state lock (or re-check the hash) until the unit's copy has
   happened. Then open a nixarchy issue for `nixarchy-apply --status` /
   `--log` and a way to pass the expected content, and switch over when it
   lands. The spec must settle how the `--expect` guarantee survives the
   gap, because it cannot be deferred.
2. **What does the panel show on reopen if the build finished while it was
   closed?**
   *Recommendation:* show the finished result once, on the log view: the
   last lines from the journal and "applied" or "failed (exit N)", read
   from `Result`/`ExecMainStatus`. Do it only when the finished run is one
   this plugin started and the panel has not already shown its result.
   Keep a small marker under `$XDG_STATE_HOME`, such as the unit's
   invocation ID. After that, open normally. A result from a terminal
   `nixarchy-apply --detach`, or one already shown, is not raised again.
3. **Does the unit still exist after the build?** No action needed:
   `RemainAfterExit` keeps the result until the next `--detach` or logout.
   A reopened panel that finds no unit shows nothing, the same as today.
