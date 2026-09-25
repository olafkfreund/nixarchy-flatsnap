---
status: approved
issue: 44
intent: intent/2026-09-25-44-adopt-nixarchy-apply.md
---

# Spec: use nixarchy-apply's own interfaces for the flake, the rebuild's state and the pinned build

flatsnap line numbers are for `bin/nixarchy-flatsnap` and the tests on `main`
at cc10803. nixarchy-apply line numbers are for the installed copy on p620
(`/nix/store/kd8k85mv01n60a3j53xjfh2hlyk96ljg-nixarchy-apply/bin/nixarchy-apply`,
built from nixarchy d3f2cef).

Decided at the intent review (9cb9aeb):

1. Adopt `/etc/nixarchy/flake` and `--status --json`/`--log` now. Keep
   `apply --in-unit` and its lock and hash re-check until nixarchy#986 is
   fixed.
2. On an older nixarchy, refuse with one JSON error that names the version
   needed. Detect the version by capability, not by a version string.
3. This is not a blocker for the #43/#35 razer session. If it merges first,
   that session gets one extra `--status`/`--log` check.
4. `ours` and `shown` stay flatsnap's, and the marker is written from inside
   the unit.
5. flatsnap maps nixarchy's `--status`/`--log` quirks in one place until
   nixarchy#986 lands.

## Design

### A. The flake: `/etc/nixarchy/flake` replaces the source scrape

`flake()` (`:542-553`) becomes a read in this order:

1. `NIXARCHY_FLAKE` if it is set. This is unchanged, and matches how
   nixarchy-apply picks its flake (nixarchy-apply:43).
2. Otherwise, the contents of `/etc/nixarchy/flake` (nixarchy#969). The file
   has no trailing newline. It must hold an absolute path; anything else is
   an error, not a fallback.

The `sed` over nixarchy-apply's source and the silent `/etc/nixos` fallback
are deleted, together with their stderr warning and ponytail comment
(`:543-552`). The file's path can be overridden for tests only, through
`NIXARCHY_FLATSNAP_FLAKE_FILE`, named like the existing
`NIXARCHY_FLATSNAP_FILE`. This adds no new trust:
anyone who can set this variable can already set `NIXARCHY_FLAKE`.

`cmd_preflight` resolves the flake once into a local variable, and dies with
JSON if that fails. It no longer calls `$(flake)` inside the `nix eval`
arguments (`:568`, `:578`), where a `die` would be swallowed by the
subshell. `cmd_apply` reuses the same value for `--setenv=NIXARCHY_FLAKE`
(`:700`).

### B. One mapping place for nixarchy's `--status` and `--log`

The block that holds `UNIT`, `marker`, `unit_prop` and `die3` (`:612-620`)
becomes the only code in flatsnap that talks to nixarchy about the
rebuild. It gets two functions and one message, and `unit_prop` is deleted.

- **`NIXARCHY_TOO_OLD`** is the one message:
  `"flatsnap needs nixarchy d3f2cef or later (nixarchy#969 and #981, 2026-09-24): update the nixarchy input and rebuild"`.
  nixarchy has no tag that contains d3f2cef (it is 155 commits after
  `v4.0.4-1`), so the minimum is a commit, and the README says so.
- **`nixarchy_status`** runs `nixarchy-apply --status --json`. Any
  non-zero exit counts as too old; an older nixarchy exits 2 with its usage
  text (nixarchy-apply:29-37). The output must be JSON with exactly
  nixarchy#981's contract:
  - `state` is one of `none|running|succeeded|failed`
  - `result` is a string
  - `exit` is a number
  - `invocation` is `null` or 32 lowercase hex characters

  Anything else is refused with the same message. This also covers the
  unescaped `printf` (nixarchy-apply:81-83): output that doesn't parse is
  refused, never guessed at. The function then prints flatsnap's own field
  names, so `FlatsnapModel.qml` doesn't change:
  `{state, result, exit, invocationId}`. It applies one correction:
  `invocation == null` means `state: "none"`. nixarchy reports
  `succeeded` for `SubState=exited` with no InvocationID (nixarchy-apply:61
  only checks for `none` when SubState is empty or `dead`). flatsnap's test
  "status no invocation" (`tests/cli.sh:588`) covers that case and must
  still pass.
- **`nixarchy_log <id> [--follow]`** runs
  `nixarchy-apply --log --invocation <id> [--follow]` and pipes it through
  `sed -u`, which does two things until nixarchy#986 adds `-o cat`:
  - It deletes journalctl's `-- … --` marker lines, such as `-- No entries --`.
  - It strips the short-format prefix `<date> <host> <ident>[<pid>]: `
    with `s/^[^][]*\[[0-9]+\]: //`.

  The pattern cannot pass a `[`, so it stops at the first bracket on the
  line, which is the prefix's pid. It never strips text from inside the
  message. It doesn't depend on the locale's date format.
  flatsnap always passes `--invocation`: with no ID, nixarchy prints the
  unit's whole history (nixarchy-apply:90-96).

These functions are used as follows:

- **`cmd_apply_status`** (`:752-774`) takes `state`, `result`, `exit` and
  `invocationId` from `nixarchy_status`, and adds `ours` and `shown` from the
  marker, which is unchanged (decision 4). `--ack` doesn't change. The
  `systemctl show` parse (`:764-766`) is deleted.
- **`cmd_apply_log`** (`:778-791`) validates the ID as it does today. If no
  ID is given, it uses `invocationId` from `nixarchy_status`. If that is
  empty, it answers "no rebuild to show", as it does now. It then runs
  `nixarchy_log`. The direct `journalctl` call (`:790`) is deleted.
- **`cmd_apply`**:
  - The running check (`:660-662`) reads `.state == "running"` from
    `nixarchy_status`, and still refuses with exit 3 and a JSON error.
  - The ID that the `nixarchyFlatsnapStarted` line reports (`:705`) is
    `invocationId` from `nixarchy_status`.
  - The conditional stop and reset before the start (`:679-685`) becomes an
    unconditional `systemctl --user stop` and `reset-failed`, each with
    `|| true`. A running unit has already been refused, and both are
    harmless on a unit that is dead or gone. This removes the last
    SubState read in flatsnap.
  - Because a failing `$(...)` only ends the subshell, every call to
    `nixarchy_status` follows the existing `:665` pattern: capture the
    output, and on failure print it and exit 2.

### C. Refusing an older nixarchy (decision 2)

`cmd_preflight` checks both capabilities before anything else, right after
its existing `command -v nixarchy-apply` check (`:565`):

- `/etc/nixarchy/flake` (or the test override) must exist.
- `nixarchy_status` must succeed.

This holds even when `NIXARCHY_FLAKE` is set, which it always is inside a
session. The file is the evidence of nixarchy#969, not only a source for the
path. Every apply runs preflight (`:665`), and `cmd_apply`'s running check
reaches `nixarchy_status` first anyway. So an older nixarchy gets exactly
one `{"error": NIXARCHY_TOO_OLD}` line with exit 2, and the panel shows it
through its existing error path (`FlatsnapModel.qml:419-425`). There is no
fallback to the old code.

`apply-status` fails the same way on an older nixarchy. The panel already
ignores `d.error` from a status poll (`FlatsnapModel.qml:459`), so the only
place the message appears is the apply, where the user asked for something.

### D. What stays until nixarchy#986, and what it then deletes

These stay as they are (decision 1):

- The start through `systemd-run --unit=nixarchy-rebuild`, with its
  properties and `--setenv`s (`:686-704`), and the `UNIT` name it needs.
- `apply_in_unit` (`:713-745`): the check again under `flatsnap.nix.lock`,
  held through nixarchy-apply's copy and build, the marker written from
  `$INVOCATION_ID`, the log filter and the `nixarchyFlatsnapApply` record.
- `state_hash` over the parsed state (`:610`), which preflight shows and
  the panel returns.

When nixarchy#986 is fixed (`--detach` passes `--expect-sha256` into the
unit, and the check and the copy work from one read), a follow-up issue
does the following:

- Deletes the `systemd-run` block, `apply_in_unit`, the unconditional stop
  and reset, and `UNIT`.
- Starts the build with
  `nixarchy-apply --detach --yes --expect-sha256 flatsnap=<sha256 of flatsnap.nix as rewritten at :676>`.
- Replaces the "the declared set changed since you confirmed" refusal in
  the unit with nixarchy's exit 4.
- Re-decides the marker (decision 4 applies only while flatsnap runs inside
  the unit).
- Deletes the tests for these: `tests/cli.sh:351-360` (the systemd-run
  stub), `:514-581` (#23 cases 1-9), and the `SNEAK` gap-edit case
  (`:568-572`), which nixarchy's own test then covers. It also deletes the
  mapping in B that #986's `--status`/`--log` fixes make unnecessary.

### E. Tests (decision: stubs only, under `tests/isolate.sh`)

- **`tests/isolate.sh`.** `assert_isolated` also aborts unless
  `NIXARCHY_FLATSNAP_FLAKE_FILE` is set and points outside `/etc`. The real
  `/etc/nixarchy/flake` is then never read. It keeps checking
  `nixarchy-apply`, `systemd-run`, `systemctl` and `journalctl` as it does
  today (`:30-33`). flatsnap no longer calls `journalctl`, but a stray call
  must still hit a stub.
- **`tests/cli.sh`.** An `apply_stub <body>` helper writes every
  nixarchy-apply stub (today they are written separately at `:341`, `:422`,
  `:435`, `:502` and `:516`) with the same dispatch in front:
  - `--status` prints `$STATUS_FIXTURE` and exits `${STATUS_RC:-0}`.
  - `--log` logs its arguments to `$APPLY_LOG_ARGS` and prints
    `$JOURNAL_FIXTURE`, written in journalctl's short format.
  - Anything else runs the body.

  The `unit` helper (`:377`) writes a `--status` JSON fixture in place of
  the `systemctl show` lines. The `systemctl` stub keeps only its logging
  of stop and reset-failed.
- **`tests/model.sh`.** Its nixarchy-apply stub answers `--status --json`
  with `none`, and it exports a flake-file fixture. `tests/model.qml:374`
  already expects `none`.

New and rewritten cases in `tests/cli.sh`:

| Case | Replaces | Asserts |
| --- | --- | --- |
| flake from the file | `:396-397` | preflight evaluates the flake the fixture file names |
| `NIXARCHY_FLAKE` wins | `:398-399` | unchanged |
| no flake file | `:420-425` (the sed fallback) | exit 2, one `{"error"}` matching `d3f2cef`, `nix` never ran |
| flake file not absolute | new | the same refusal |
| `--status` exits 2 (older nixarchy) | new | preflight and apply both exit 2 with that error, and `systemd-run` never ran |
| `--status` gives malformed or partial JSON | new | the same refusal, nothing started |
| status mapping | `:586-595` | `none`/`running`/`succeeded`/`failed`, `invocation: null` gives `none` even when nixarchy says `succeeded`, `invocation` → `invocationId`, `ours`/`shown` unchanged |
| `--ack` | `:596-603` | unchanged |
| log | `:605-613` | nixarchy-apply got `--log --invocation <id> [--follow]`, prefixes and `-- No entries --` are stripped, a message containing `x[1]: y` keeps it, no ID uses the status's `invocationId`, an empty one gives "no rebuild to show" |
| reset before start | `:550-555` | stop and reset-failed are logged before every start, whatever the previous state |
| already running | `:543-549` | read from `--status`, still exit 3 with one JSON line and nothing started |

The #10 and #23 cases that stay (`:433-512` and `:514-581`) must pass
unchanged apart from the stub helper.

### F. Documentation

- `README.md:98-108` (Requirements) states the minimum nixarchy (d3f2cef,
  nixarchy#969 and #981) and the error an older one gives.
- `README.md:71` still describes the unit, and names nixarchy#986 as the
  reason flatsnap starts the unit itself.
- The ponytail comments at `:549` and `:615` go. A new one on the mapping
  block names nixarchy#986 as its expiry.

## Alternatives rejected

- **Adopt the pinned `--detach` now.** nixarchy-apply:99-131 exits before
  the pin is checked (:174-186) and never passes it into the unit (:127). A
  pinned detached build today is an unpinned build that looks pinned. This
  breaks #10's first guarantee.
- **Use `--expect-sha256` in the foreground inside our unit, and drop our
  lock.** The check (:178) and the copy (:206) read the file separately with
  nothing held, and flatsnap's own `add`/`rm` write under a lock nixarchy
  doesn't take. Keeping our lock and also passing the hash adds nothing.
- **Fall back to the old code on an older nixarchy.** That keeps two
  implementations and both test sets, which is the cost this issue removes.
  The old path is also the one with the silent `/etc/nixos` fallback.
- **Detect the version by parsing a version string.** nixarchy's tags don't
  contain the needed commit, and a version says nothing about a fork or a
  pinned revision. Capabilities are what is used.
- **Keep reading `journalctl` directly until nixarchy#986 adds `-o cat`.**
  Allowed by nothing in decision 1. The prefix is regular enough to strip in
  the one mapping place, and B names the case that proves the strip never
  reaches into a message.
- **Change the panel to nixarchy's field names (`invocation`).** It would
  change QML and `tests/model.qml` for a rename, and it would still leave
  `ours`/`shown` flatsnap's. The mapping stays in the CLI, and the panel's
  contract doesn't change.
- **A version check in `module.nix` (an assertion on nixarchy's options).**
  The plugin also runs on hosts where the module is imported through
  nixarchy's own copy, and an eval-time assertion can't see the running
  system's nixarchy-apply. The runtime check sees what apply will actually
  run.

## Risks

- **`--log --follow` shows only the last 10 lines when it attaches**
  (host: any). nixarchy passes no `-n`, and `journalctl -f` implies
  `-n 10`. Today flatsnap passes `-n 2000`. A panel that re-attaches to a
  running build, after a shell restart or from a terminal start, shows only
  the latest 10 lines until the build ends. At the end, `_finish` reloads
  the whole run (`FlatsnapModel.qml:495-513`) without `--follow`, so no line
  is lost from the final log. In the normal case the follower starts when
  the unit does, before 10 lines exist. This is **accepted, unless the
  reviewer decides otherwise**. It is the one quirk that can't be mapped,
  and it will be added to nixarchy#986.
- **A stopped unit that still has an InvocationID** (`SubState=dead`).
  nixarchy reports it as `succeeded` or `failed` from Result
  (nixarchy-apply:61-73), and nixarchy's JSON has no SubState field that
  flatsnap could correct this from. It appears only in the moment between
  our own stop and `systemd-run`, or when a user stops the unit by hand. For
  a run that was ours and not yet shown, the panel could show a stopped run
  as `applied` if Result was `success` with exit 0. A stop that interrupts a
  running build exits on SIGTERM (status 15), which reads as `failed`.
  Covered by nixarchy#986, item 3.
- **The prefix strip.** If nixarchy switches `--log` to `-o cat` before
  flatsnap drops the strip, a build line that itself starts with
  `something[123]: ` loses that prefix. This is cosmetic only: nothing
  parses log lines as records (`FlatsnapModel.qml:445-447` only displays
  them). It is removed together with the mapping.
- **An older nixarchy stops panel applies entirely** until nixarchy is
  updated. This is intended (decision 2). The terminal
  `nixarchy-apply` still works, and the message says what to do.
- **p620 and razer share `/etc/nixos/flake.lock`**, which pins d3f2cef.
  razer's generation 2957 is not verified to have been built from it. The
  capability check reports this at the razer session's first apply, instead
  of letting it pass silently.
- **The test override variable.** A developer shell that exports
  `NIXARCHY_FLATSNAP_FLAKE_FILE` would change which flake preflight
  evaluates. That is the same trust as `NIXARCHY_FLAKE`, and it is
  documented beside it.

## Verification

- `bash tests/cli.sh` and `bash tests/model.sh` pass with 0 failed,
  including every case in E. `assert_isolated` aborts if the flake-file
  override is missing or under `/etc`. Checked by running the suite once
  with it unset, which must abort before any case runs.
- `nix flake check` passes. It runs `checks.shellcheck` (`flake.nix:71-75`,
  which covers `tests/isolate.sh`) and `checks.cli` (`flake.nix:80-88`,
  which runs `tests/cli.sh` offline). `tests/model.sh` needs quickshell and
  is not a flake check, so it is run locally.
- Grep gates on the diff: `bin/nixarchy-flatsnap` contains no `sed` over
  nixarchy-apply, no `journalctl`, and no `systemctl … show`. `systemctl`
  appears only in the stop and reset-failed lines, and `nixarchy-rebuild`
  appears only in `UNIT`.
- On p620, only `nixarchy-apply --status --json` is run, to confirm the
  fixture shape matches the real output
  (`{"state":"none","result":"","exit":0,"invocation":null}`, recorded
  2026-09-25). Nothing builds or switches there.
- Live, on razer, only when the user has booked it (decision 3): one apply
  from the panel. `nixarchy-flatsnap apply-status` shows `running` and then
  `succeeded`, with the invocation that `nixarchy-apply --status --json`
  reports. `nixarchy-flatsnap apply-log <id>` shows the build without
  journal prefixes. A shell restart during the build re-attaches, and the
  result is shown once. If this merges before the #43/#35 session, these
  checks are added to it. Otherwise they run in the session that verifies
  the nixarchy#986 follow-up.
