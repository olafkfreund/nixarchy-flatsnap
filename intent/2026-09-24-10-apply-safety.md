---
status: draft
issue: 10
author: olafkfreund
---

# Intent: make apply check what it builds, report its errors, and stay visible

## Problem

Apply is the one step that turns what the user queued into root system
configuration. It has five problems. Line numbers are for `main` at 64f97b2.

1. **It builds from a file it never checked.** `load_state`
   (`bin/nixarchy-flatsnap:213-229`) is the only place that asserts
   `flatsnap.nix` is exactly the shape this tool writes. `list`, `add` and `rm` call
   it, but `cmd_apply` (`:420-446`) does not. It runs
   `nixarchy-apply --yes --no-preview` (`:435`), which copies
   `~/.config/nixarchy/flatsnap.nix` into the flake and imports it as a full
   NixOS module. Any process running as the user can write that file, so
   whatever it adds (a service, a user, an `environment.etc` entry) becomes
   root configuration at the next apply. The user's only confirmation is a
   polkit prompt that doesn't show what will be built. nixarchy's own
   `advanced.nix` goes through the same path and has the same weakness.
2. **Preflight errors come back empty.** `pf=$(cmd_preflight)` (`:422`) is a
   bare assignment under `set -euo pipefail`. When preflight calls `die`
   (nixarchy-apply missing, the host configuration fails to evaluate), the
   error JSON stays inside the command substitution. The script exits 2 with
   empty stdout, and the panel gets no `{"error":...}` line to show. This
   has been reproduced.
3. **A running apply can drop out of view, and its input can still be
   edited.** `queue()` (`FlatsnapModel.qml:170`) and `remove()` (`:193`)
   check `busy` but not `applying`, so `flatsnap.nix` can be rewritten while
   the rebuild is reading it. Esc on the log (`Menu.qml:101`) and reopening
   the panel (`open()` → `reset()`, `FlatsnapModel.qml:42-46`) both leave the
   rebuild running with nothing on screen to show it. The only activity mark,
   `Menu.qml:171`, reads `fs.busy` alone.
4. **"checking…" is never shown.** `apply()` sets `message = "checking…"`
   (`FlatsnapModel.qml:238`), and `_run()` clears it straight away (`:86`).
   While preflight evaluates the whole host configuration, which can take
   seconds, the panel shows nothing.
5. **The build log can end the apply early (plausible, not reproduced).**
   Any stdout line that starts with `{"nixarchyFlatsnapApply"`
   (`FlatsnapModel.qml:257`) ends the apply. The build log comes through the
   same stdout (`bin/nixarchy-flatsnap:434-437`), so a build that prints that
   prefix marks the apply finished, and turns the rest of the log into
   ordinary lines, while the rebuild is still running.

## Proposed outcome

- Apply builds only what this tool would have written. If `flatsnap.nix`
  contains anything else, the rebuild does not start and the user is told
  why.
- The user can see what an apply will change before approving it.
- Every apply or preflight failure reaches the panel as a readable message,
  never as an empty result.
- While a rebuild is running, the panel shows it on every view, including
  after Esc and after the panel is closed and reopened. Queue and remove are
  refused until it finishes, and the refusal says why.
- "checking…" appears while preflight runs.
- Only the tool's own final status line can end an apply. Build output
  cannot.

## Affected users and systems

- nixarchy users with the flatsnap plugin and module installed.
- `bin/nixarchy-flatsnap` (`cmd_apply`, `cmd_preflight`, `load_state`).
- `FlatsnapModel.qml` and `Menu.qml` (apply state, busy gating, messages,
  log parsing).
- `~/.config/nixarchy/flatsnap.nix` and the flake copy nixarchy-apply makes
  of it.
- Possibly nixarchy's `nixarchy-apply` and `advanced.nix` handling (see open
  question 3).
- `tests/` (model and CLI tests).

## Constraints

- **Must stay compatible with nixarchy-apply's copy-into-flake model.** The
  plugin keeps handing off to `nixarchy-apply` and does not rebuild around
  it. Whatever the fix, `flatsnap.nix` stays where nixarchy-apply expects it,
  in the form it expects.
- **Tests must never invoke the real nixarchy-apply**, nor `nixos-rebuild`,
  `nh`, or anything else that changes the system. Apply is tested against a
  stub on `PATH`.
- No new elevation path. pkexec or passwordless sudo stay as they are
  (`:429-431`).
- Esc still never stops a running build. Stopping a switch halfway is never
  what Esc meant.
- Must not lose the user's declared apps. Refusing a malformed file leaves it
  in place and says what to do, as `load_state` does today.
- Keyboard-only, and colours from the shell's theme tokens.

## Open questions

1. **Regenerate or refuse.** Before apply, should the tool regenerate
   `flatsnap.nix` from the parsed state (anything else in the file is
   silently dropped, and the built file is always our shape), or run the
   `load_state` shape check and refuse on a mismatch (the user sees the
   problem, and nothing is rewritten behind their back)? Or both: check,
   then regenerate?
2. **Preview.** Should apply drop `--no-preview` so nixarchy-apply's own
   diff is shown, or should the panel show a diff of the declared set (or of
   `flatsnap.nix`) and ask for a second confirmation before the rebuild?
   Whether nixarchy-apply's preview works without a tty (the panel has
   none) is not yet checked.
3. **Is B1 also a nixarchy issue?** nixarchy-apply imports `advanced.nix`
   the same way, and any user process can write it. Do we fix only this
   plugin's file here and open a nixarchy issue for the general case, or
   wait for a nixarchy-side guard that covers both?
