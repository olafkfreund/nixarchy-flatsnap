---
status: approved
issue: 44
spec: spec/2026-09-25-44-adopt-nixarchy-apply.md
---

# Plan: use nixarchy-apply's own interfaces for the flake, the rebuild's state and the pinned build

Line numbers are for `main` at cc10803. nixarchy-apply line numbers are for
the copy installed on p620 (`/nix/store/kd8k85mv01n60a3j53xjfh2hlyk96ljg-nixarchy-apply/bin/nixarchy-apply`,
built from nixarchy d3f2cef). This plan can be followed without opening the
intent or the spec.

## Approved decisions

Intent approved at 9cb9aeb, spec at cfd26c8.

1. **Flake path.** `flake()` returns `NIXARCHY_FLAKE` if it is set.
   Otherwise it returns the contents of `/etc/nixarchy/flake` (nixarchy#969),
   which must be an absolute path. The file can be overridden for tests only,
   with `NIXARCHY_FLATSNAP_FLAKE_FILE` (the name is approved). The `sed` over
   nixarchy-apply's source and the silent `/etc/nixos` fallback are deleted.
2. **One adapter block** (the block that holds `UNIT`, `:612-620`) is the
   only code that talks to nixarchy about the rebuild:
   - `nixarchy_status` runs `nixarchy-apply --status --json`. It checks the
     output against nixarchy#981's contract: `state` is one of
     `none|running|succeeded|failed`, `result` is a string, `exit` is a
     number, and `invocation` is `null` or 32 hex characters. It then prints
     `{state, result, exit, invocationId}`, with `invocation == null`
     turned into `state: "none"`. A non-zero exit, or output that doesn't
     match, gives the single message `NIXARCHY_TOO_OLD`.
   - `nixarchy_log <id>` (no `--follow`) runs
     `nixarchy-apply --log --invocation <id>` through a `sed` that
     deletes `-- … --` lines and strips the short-format prefix with
     `s/^[^][]*\[[0-9]+\]: //`.
   - **`--follow` stays on `journalctl`** (decided at spec approval, so the
     log view doesn't lose lines): it runs
     `journalctl --user -u "$UNIT" --invocation=<id> -o cat --no-pager -n 2000 -f`,
     inside the same block, with a comment pointing at nixarchy#986 and
     https://github.com/olafkfreund/nixarchy/issues/986#issuecomment-5828269098.
   - `unit_prop` is deleted.
3. **Older nixarchy.** It is detected by capability: `/etc/nixarchy/flake`
   (or its override) must exist, and `nixarchy_status` must succeed. This is
   checked in `cmd_preflight` right after `command -v nixarchy-apply`,
   whether or not `NIXARCHY_FLAKE` is set. The result is one `{"error"}`
   line and exit 2:
   `"flatsnap needs nixarchy d3f2cef or later (nixarchy#969 and #981, 2026-09-24): update the nixarchy input and rebuild"`.
   There is no fallback.
4. **Kept until nixarchy#986 is fixed:**
   - the `systemd-run --unit=nixarchy-rebuild` start (`:686-704`)
   - `apply_in_unit` (`:713-745`) and its lock
   - the marker written from `$INVOCATION_ID`, and `ours`/`shown`
   - `state_hash` (`:610`)
   - the log filter and the `nixarchyFlatsnapApply` record

   The follow-up will delete these and start the build with
   `nixarchy-apply --detach --yes --expect-sha256 flatsnap=<sha256>`.
5. **`cmd_apply`.** The running check (`:660-662`) and the invocation ID it
   reports (`:705`) come from `nixarchy_status`. The stop and reset before
   `systemd-run` (`:679-685`) become unconditional, each with `|| true`.
   Every `$(nixarchy_status)` follows the `:665` pattern: on failure, print
   the output and exit 2.
6. **The panel's contract doesn't change.** `FlatsnapModel.qml` and
   `tests/model.qml` are not edited.
7. **Accepted risks:**
   - A stopped unit that still has an InvocationID reads as
     succeeded/failed rather than `none`. This is recorded, and tracked in
     nixarchy#986.
   - The prefix strip on the non-follow log is cosmetic if nixarchy changes
     its format first.
8. **Host rules.** p620 is for development only. There, only
   `nixarchy-apply --status --json` and `--help` may be run. Never
   nixarchy-apply with any other flag, never flatsnap `apply`/`preflight`
   against the real tools, never `systemd-run` or `nixos-rebuild`. The live
   check is one `--status`/`--log` check folded into the pending combined
   razer session (#43/#35), not a session of its own.

## Steps

Each step is one commit on `refactor/44-adopt-nixarchy-apply`, and the
commit message names the step. Any `.nix` edit is made through Bash, never
the Edit tool. None is expected, since `flake.nix` already runs
`tests/cli.sh`.

1. **`tests/isolate.sh`:** `assert_isolated` also aborts unless
   `NIXARCHY_FLATSNAP_FLAKE_FILE` is set and neither it nor its
   `readlink -f` starts with `/etc/`. The existing checks on the
   `nixarchy-apply`, `systemd-run`, `systemctl` and `journalctl` stubs
   (`:30-33`) stay.
   → Verify by sourcing `tests/isolate.sh` and calling `assert_isolated`
   directly with the variable unset, then set to `/etc/nixarchy/flake`
   (both must print `ABORT`), and then set to a temporary fixture (must
   pass). *Deviation, made while implementing:* the plan first said to run
   `bash tests/cli.sh` with the variable unset. That can't show anything,
   because the suite exports the variable itself. Steps 1 and 2 go in one
   commit, so no commit leaves the suite aborting.
   *Deviation:* step 6's `tests/model.sh` changes also move into this
   commit. `model.sh` calls `assert_isolated` too, so it would abort from
   step 1 onwards. From step 3 on, its preflight also needs the stub to
   answer `--status`.
2. **`tests/cli.sh`: harness only.**
   - Export `NIXARCHY_FLATSNAP_FLAKE_FILE="$work/etc-nixarchy-flake"`,
     holding `/srv/their-flake` with no trailing newline.
   - Add `apply_stub <body>`. It writes `$ab/nixarchy-apply` with a
     dispatch in front of the body:
     - `--status`: `cat "$STATUS_FIXTURE"; exit ${STATUS_RC:-0}`
     - `--log`: log `$*` to `$APPLY_LOG_ARGS`, then `cat "$LOG_FIXTURE"`
     - anything else: the body
   - Convert the five nixarchy-apply stubs (`:341`, `:422`, `:435`,
     `:502`, `:516`) to use it. Keep their `flake=` lines for now, because
     the old CLI still scrapes them.
   - Change `unit()` (`:377`) so it also writes the matching `--status` JSON
     to `$STATUS_FIXTURE`. It keeps the `systemctl show` fixture until
     step 5 removes the last reader.

   → Verify with `bash tests/cli.sh` on p620: 0 failed. Every existing case
   still passes against the unchanged CLI.
3. **`bin/nixarchy-flatsnap`: flake and capability (decisions 1 and 3).**
   - Add `NIXARCHY_TOO_OLD`, plus a `nixarchy_status` that only validates
     for now.
   - Rewrite `flake()` (`:542-553`) to read
     `${NIXARCHY_FLATSNAP_FLAKE_FILE:-/etc/nixarchy/flake}`.
   - `cmd_preflight`:
     - Add the capability check after `:565`.
     - Resolve `fl=$(flake) || die …` once, and use `$fl` at `:568` and
       `:578`.
   - `cmd_apply`: pass the same value to `--setenv=NIXARCHY_FLAKE` (`:700`).
   - `tests/cli.sh`: drop the `flake=` lines from the stub bodies, so
     `:396-397` now proves the flake comes from the file. Replace `:420-425`
     with these cases:
     - no flake file
     - a relative path in the file
     - `STATUS_RC=2`
     - malformed or partial status JSON

     Each must give exit 2 and one `{"error"}` matching `d3f2cef`, and the
     `nix` and `systemd-run` stubs never ran.

   → Verify with `bash tests/cli.sh` (0 failed) and
   `shellcheck bin/nixarchy-flatsnap tests/*.sh`.
4. **`bin/nixarchy-flatsnap`: status through nixarchy (decisions 2 and 5).**
   - `nixarchy_status` does the full mapping.
   - `cmd_apply_status` (`:752-774`) uses it, and keeps the marker and
     `--ack` logic as they are.
   - `cmd_apply`:
     - The running check and the invocation ID come from `nixarchy_status`.
     - The stop and reset become unconditional.
   - `tests/cli.sh`:
     - Rewrite `:586-595` against `$STATUS_FIXTURE`. Include
       `{"state":"succeeded","invocation":null}` → `none`, and
       `invocation` → `invocationId`.
     - Rewrite `:550-555` so it asserts stop and reset-failed before every
       start.
     - `:543-549` (already running) must pass on the fixture.

   → Verify with `bash tests/cli.sh` (0 failed). Grep
   `bin/nixarchy-flatsnap` for `systemctl --user show` and `unit_prop`: the
   only matches left are `unit_prop`'s definition and its one use in
   `cmd_apply_log`. Step 5 deletes both. *Deviation, made while
   implementing:* the plan said "no matches" here, but the log's missing-ID
   lookup is step 5's work.
5. **`bin/nixarchy-flatsnap`: log (decision 2, split).**
   - `nixarchy_log` handles the non-follow read.
   - `--follow` keeps calling `journalctl` inside the adapter block, with
     the nixarchy#986 comment.
   - `cmd_apply_log` (`:778-791`) takes a missing ID from
     `nixarchy_status`, and still answers "no rebuild to show" when there
     is none.
   - Delete `unit_prop` and the ponytail comments at `:549` and `:615`. Add
     one on the adapter block that names nixarchy#986 as its expiry.
   - `tests/cli.sh`:
     - Drop the `systemctl show` fixture from `unit()`.
     - Rewrite `:605-613`. The non-follow read must reach nixarchy-apply as
       `--log --invocation <id>`. `$LOG_FIXTURE` is in short format, with a
       `-- No entries --` line and a message `x[1]: y`. The prefixes and the
       marker line are gone, and `x[1]: y` is kept.
     - `--follow` must reach the `journalctl` stub as
       `--user -u nixarchy-rebuild --invocation=<id> -o cat --no-pager -n 2000 -f`.
     - With no ID, the status's `invocationId` is used. An empty one gives
       exit 2 "no rebuild to show".

   → Verify with `bash tests/cli.sh` (0 failed). In `bin/nixarchy-flatsnap`,
   `journalctl` appears only in the follow line of the adapter block, and
   `systemctl` only in the stop and reset-failed lines. `nixarchy-rebuild`
   appears only in `UNIT`.
6. **`tests/model.sh`** (done in the step 1+2 commit; see the deviation there):
   - Its nixarchy-apply stub (`:21`) answers `--status` with
     `{"state":"none","result":"","exit":0,"invocation":null}`.
   - Export `NIXARCHY_FLATSNAP_FLAKE_FILE` pointing at a fixture under
     `$d`.

   `FlatsnapModel.qml` is not touched, so `qmlformat` isn't needed. If any
   QML does change, parse-check it with
   `/nix/store/0x7jcnb8rls5v0jrl17ji5zj3w99wbp2-qtdeclarative-6.11.0/bin/qmlformat <file> >/dev/null`.
   → Verify with `bash tests/model.sh` on p620, which must print
   `model: N passed, 0 failed`. It runs only under `assert_isolated`.
7. **`README.md`:**
   - Requirements (`:98-108`): the minimum nixarchy (d3f2cef, nixarchy#969
     and #981), and the error an older one gives.
   - `:71`: flatsnap still starts `nixarchy-rebuild` itself, because of
     nixarchy#986.

   → Verify by reading the diff. Every nixarchy link resolves
   (`gh pr view 969 --repo olafkfreund/nixarchy`, `gh pr view 981 …`,
   `gh issue view 986 …`).
8. **Whole-repo gate.** Run `nix flake check`, which runs
   `checks.shellcheck` and `checks.cli` (`tests/cli.sh` offline, in the
   sandbox), and `nix fmt -- --ci`.
   → Verify that both exit 0. `nix flake check` builds only the check
   derivations and switches nothing.
9. **One-time contract check on p620 (read-only).**
   `nixarchy-apply --status --json | jq -e 'keys == ["exit","invocation","result","state"]'`
   → Verify that it exits 0. The fixture shape then matches the real
   output. Nothing else of nixarchy-apply runs on p620.
10. **PR.** Open it against `main`, linking the intent, the spec and this
    plan, with "Closes #44" and "Follow-up: nixarchy#986". Add one checklist
    item to the combined razer session issue #43 (with #35): after an apply
    from the panel, `nixarchy-flatsnap apply-status` shows `running` and
    then `succeeded` with the same invocation as
    `nixarchy-apply --status --json`, and `nixarchy-flatsnap apply-log <id>`
    shows the build without journal prefixes.
    → Verify with `gh pr view` (links present) and `gh issue view 43`
    (item present).

## Tests

Run on p620. Every one runs against stubs only.

| Command | Expected |
| --- | --- |
| `bash tests/cli.sh` | `N passed, 0 failed`, and every existing #10 and #23 case (`:433-512`, `:514-581`) still passes |
| `assert_isolated` called directly with `NIXARCHY_FLATSNAP_FLAKE_FILE` unset, then `/etc/nixarchy/flake`, then a fixture | `ABORT`, `ABORT`, then pass |
| `bash tests/model.sh` | `model: N passed, 0 failed` |
| `nix flake check` | exit 0 (shellcheck, cli, manifest and the rest of `checks`) |
| `nix fmt -- --ci` | exit 0 |
| `grep -n 'journalctl\|systemctl\|nixarchy-rebuild' bin/nixarchy-flatsnap` | only the follow line, the stop and reset-failed lines, `UNIT`, and comments |
| `nixarchy-apply --status --json \| jq -e 'keys == ["exit","invocation","result","state"]'` | exit 0. This is the only nixarchy-apply command in this plan. |

Live, in the combined razer session (#43/#35) only, when the user has booked
it: the step 10 checklist item.

## Rollback

`git revert` the implementation commits, or the merge commit. None of this
changes any on-disk format:

- the marker file (`~/.local/state/nixarchy-flatsnap/apply`)
- `flatsnap.nix`
- the unit's name and properties
- the panel's JSON contract

A reverted flatsnap therefore works against the same nixarchy and the same
unit straight away. It goes back to scraping the flake path, which is still
correct on d3f2cef. No host state needs cleaning up, and nothing on razer
has to be undone, because razer is only read.
