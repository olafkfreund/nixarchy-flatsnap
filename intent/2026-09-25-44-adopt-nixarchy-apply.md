---
status: approved
issue: 44
author: olafkfreund
---

# Intent: use nixarchy-apply's own interfaces for the flake, the rebuild's state and the pinned build

A follow-up to #11 and #23 (`intent/`, `spec/`, `plan/2026-09-24-23-detach-apply.md`),
and bound by #10 (`plan/2026-09-24-10-apply-safety.md`). Line numbers are for
`main` at cc10803. nixarchy-apply line numbers are for the copy installed on
p620 (`/nix/store/kd8k85mv01n60a3j53xjfh2hlyk96ljg-nixarchy-apply/bin/nixarchy-apply`),
which is built from nixarchy d3f2cef, the merge of nixarchy#981.

## Problem

flatsnap reads three things about nixarchy that nixarchy never promised to
keep the same. It did this because nixarchy had no way to ask for them.

1. **The flake apply rebuilds.** `flake()` (`bin/nixarchy-flatsnap:542-553`)
   uses `sed` to pull the default out of nixarchy-apply's source, from the
   line `flake="${NIXARCHY_FLAKE:-...}"` (nixarchy-apply:43). The match is
   tied to the text and indentation that nixfmt happens to produce. If that
   line changes, the match finds nothing. flatsnap then evaluates
   `/etc/nixos`, and says so only on stderr, which the panel never shows.
2. **The rebuild's state and log.** `UNIT=nixarchy-rebuild` and `unit_prop`
   (`:612-619`), `cmd_apply_status` (`:752-774`) and `cmd_apply_log`
   (`:778-791`) read nixarchy's unit directly with `systemctl` and
   `journalctl`. That relies on the unit's name, on its `RemainAfterExit`
   setting, on it having no `--collect`, and on the rule "SubState and
   InvocationID decide `none`, never Result". All of these are nixarchy's
   internal details. flatsnap also copies `--detach`'s systemd properties
   into its own `systemd-run` (`:691-703`), citing nixarchy-apply line
   numbers that have already moved.
3. **Building only what was checked.** `--detach` could not pin what it
   copies, so `cmd_apply` (`:644-708`) starts the unit itself. The unit runs
   flatsnap again (`apply --in-unit --expect <stateHash>`, `apply_in_unit`
   `:713-745`), which checks the state again under flatsnap's own lock and
   holds that lock through the copy and the build. If nixarchy changes how
   the unit is started or what it runs, flatsnap's copy of that logic falls
   out of date without anyone noticing.

nixarchy has now shipped interfaces for all three:

- nixarchy#969 (closes nixarchy#950) adds `/etc/nixarchy/flake`, which holds
  `programs.nixarchy.flake` and is rewritten on every rebuild
  (`modules/nixos.nix`, `"nixarchy/flake".text = cfg.flake`). It is present
  on p620 and reads `/etc/nixos`.
- nixarchy#981 (closes nixarchy#979) adds three options:
  - `--status [--json]` (nixarchy-apply:56-88). Only the JSON form is a
    stable contract. Its output is
    `{"state":"none|running|succeeded|failed","result":"<Result>","exit":<n>,"invocation":"<id>"|null}`.
  - `--log [--follow] [--invocation <id>]` (:90-97).
  - `--expect-sha256 <part>=<sha256>`, which may be repeated (:174-186). It
    hashes `~/.config/nixarchy/<part>.nix` and exits 4 before the copy loop
    on a mismatch.

The interfaces as installed do not yet match what flatsnap guarantees. I
found the following by reading the source:

- **`--detach` does not pass the pin on.** The `--detach` branch exits at
  :130, before the `--expect-sha256` loop at :174. The unit it starts runs
  `"$(readlink -f "$0")" --yes --no-preview` (:127), and `expect[@]` is not
  passed along. So `--detach --expect-sha256 flatsnap=<h>` checks nothing.
  Every pinned build is therefore a foreground apply.
  nixarchy's `tests/apply-detach-interface.nix` tests `--expect-sha256`
  only without `--detach`, so no test catches this.
- **The check is not held through the copy.** Even without `--detach`, the
  hash is read at :178 and the file is read again by `cp` at :206, with no
  lock in between. flatsnap's own writers (`add` and `rm` take
  `flatsnap.nix.lock`, `:306-314`) could write between those two reads. Today
  that window is closed by the lock `apply_in_unit` holds. nixarchy does not
  know about that lock.
- **It hashes something different.** `--expect-sha256` hashes the file's
  bytes. flatsnap's `stateHash` hashes the parsed state with sorted keys
  (`state_hash`, `:610`), which is what preflight shows and the panel sends
  back.
- **`--status --json` has less in it.** It has no equivalent of flatsnap's
  `ours` or `shown`. Those come from flatsnap's marker, and the unit writes
  that marker from `$INVOCATION_ID` (`:717-720`). If nixarchy starts the
  unit, no flatsnap code runs inside it to write the marker. `none` is also
  worked out differently: nixarchy says `none` only when InvocationID is
  empty, while flatsnap also says `none` when SubState is `dead`. The
  `invocation` field is called `invocationId` in flatsnap. The JSON is
  built with `printf` and is not escaped.
- **`--log` behaves differently.** With no invocation, it shows every run
  the unit ever made, where flatsnap's `apply-log` says "no rebuild to
  show". It also passes no `-o cat`, `--no-pager` or `-n` limit.
- **Refusing a second run gives text, not JSON.** A running rebuild is
  refused with exit 3 and plain text on stderr (:106-111). The panel needs
  a JSON error.
- **The unit's environment differs.** The detached unit gets
  `NIXARCHY_FLAKE`, `XDG_CONFIG_HOME` and `NH_ELEVATION_STRATEGY` (:124-126).
  It does not get the `XDG_STATE_HOME`, `PATH` or `NO_COLOR` that flatsnap
  sets (`:697-702`), and it does not get flatsnap's
  `nixarchyFlatsnapApply` result line or its log filter (`:725-744`).
- nixarchy-apply itself does not read `/etc/nixarchy/flake`. It still uses
  `NIXARCHY_FLAKE` or its built-in default (:43). The file and the script
  agree only because the same option generates both.

## Proposed outcome

flatsnap asks nixarchy-apply for these facts and no longer depends on how
nixarchy is built inside:

- The flake that preflight evaluates is the one nixarchy says it rebuilds,
  read through nixarchy's published interface. flatsnap never scrapes
  nixarchy's source.
- The panel's rebuild state and log come from `nixarchy-apply --status --json`
  and `--log`. flatsnap no longer names nixarchy's unit or decodes its
  properties itself, beyond anything nixarchy's interface cannot answer.
- A detached build builds only the flatsnap state that preflight showed and
  the user confirmed. nixarchy enforces this, as long as nixarchy can make
  that guarantee in full.
- flatsnap's own copies of these mechanisms are deleted where nixarchy's
  interface covers them, together with the stubs and tests that exist only
  for them. Where nixarchy's interface still falls short, the gap is written
  down with a link to the nixarchy issue that closes it, and flatsnap's
  mechanism stays for that part.
- On a nixarchy older than the one required, the panel shows one clear
  error that names the version needed.

## Affected users and systems

- `bin/nixarchy-flatsnap`: `flake`, `cmd_preflight`, `cmd_apply`,
  `apply_in_unit`, `cmd_apply_status`, `cmd_apply_log`, `UNIT`/`unit_prop`,
  `marker`.
- `FlatsnapModel.qml`: the apply, watch, poll, ack and log processes
  (`:383-510`), which read flatsnap's `apply-status` JSON (`invocationId`,
  `ours`, `shown`).
- `tests/cli.sh` (the systemd-run, systemctl, journalctl and nixarchy-apply
  stubs, `:337-615`), `tests/model.sh` and `tests/isolate.sh`.
- `README.md` and `docs/`, wherever they describe apply, the log or the
  minimum nixarchy version. `flake.nix`/`module.nix` only if the minimum
  version is enforced there.
- nixarchy, as a dependency. This work may need an issue filed in nixarchy
  (the `--detach` pin). It does not change nixarchy from this repository.
- Hosts: p620 (development only, never applied from) and razer (the live
  check, when the user has booked it). p620 and razer share
  `/etc/nixos/flake.lock`, which pins nixarchy d3f2cef. That commit contains
  both #969 and #981. Whether razer's running generation 2957 was built from
  that lock is **not verified**, because razer is reserved.
- People: anyone who applies from the panel, or runs
  `nixarchy-flatsnap apply` in a terminal.

## Constraints

- **Every guarantee from #10 and #23 still holds**, with no gap between them:
  - Only a checked, confirmed state is built. The file is re-read and
    re-checked, it is rewritten from its parse, and it must still match the
    state preflight showed, **up to and including the moment it is
    copied**. A write between the check and the copy must be refused or
    must be impossible.
  - Preflight errors reach the panel as one JSON `{"error"}` line on stdout.
  - The build survives a shell restart, and the panel finds it again.
  - Each result is shown once, and only to the panel whose run it was.
  - A second apply while one is running is refused, with a JSON error.
  - No new elevation path. Elevation still goes through nh's
    `NH_ELEVATION_STRATEGY` (pkexec, or `passwordless` only where sudo
    already asks nothing). No new setuid wrapper, polkit rule or sudo rule.
- Tests never touch the real nixarchy-apply, systemd-run, systemctl or
  journalctl. `tests/isolate.sh`'s `assert_isolated` stays in force for every
  test that can reach apply. Note that nixarchy-apply puts `pkgs.systemd` on
  its own `runtimeInputs` PATH, so a stub `systemctl` cannot reach the real
  script. The tests must stub nixarchy-apply as a whole.
- The minimum nixarchy version is stated (in the README and in the
  artifacts) and enforced at runtime. An older nixarchy gets a clear error,
  not a silent fallback to flatsnap's old behaviour, and never a wrong
  answer such as `succeeded` for a run that never happened.
- On p620, nothing runs that builds or switches. The only apply-related
  commands allowed there are `nixarchy-apply --status --json` and `--help`.
- The live check runs on razer only, and only when the user has booked it.
- The panel's JSON contract (`nixarchyFlatsnapStarted`, the `apply-status`
  fields) either stays the same or changes in the same PR as
  `FlatsnapModel.qml`.

## Open questions

1. **Does nixarchy's pinned input fully replace our in-unit lock and hash
   re-check?** The installed source says no, for two reasons:
   - `--detach` never passes `--expect-sha256` into the unit (nixarchy-apply
     :99-131 exits first; :127 starts the unit with only
     `--yes --no-preview`).
   - Even in the foreground, the check (:178) and the copy (:206) read the
     file separately, with no lock, while flatsnap's `add`/`rm` write under
     `flatsnap.nix.lock`, which nixarchy does not take.

   Also, `--expect-sha256` hashes the file's bytes, while flatsnap's
   `stateHash` hashes the parsed state.
   *Recommendation:* adopt the flake path (#969) and `--status`/`--log`
   (#981) now. Keep `apply --in-unit` and its lock until nixarchy fixes the
   pin. File a nixarchy issue asking that `--detach` pass `--expect-sha256`
   into the unit, and that the check and the copy work from one read (for
   example, hash a copy and then copy that copy, or take a caller-named
   lock). Once that ships, flatsnap passes
   `--expect-sha256 flatsnap=<sha256 of the file as rewritten>` and
   deletes `apply_in_unit`. Even then, flatsnap's lock is only safe to drop
   if nixarchy copies what it hashed.
2. **What happens on an older nixarchy: refuse, or fall back?**
   *Recommendation:* refuse, with one JSON error naming the version needed.
   Detect it by asking for what is needed, not by parsing a version string:
   `/etc/nixarchy/flake` must exist, and `nixarchy-apply --status --json`
   must exit 0 with the documented keys. (Today an unknown flag exits 2
   with a usage message, :29-37.) A fallback keeps both code paths and all
   their tests alive, which is the cost this issue exists to remove. p620's
   lock already has what is needed.
3. **Should this land before the pending razer session (#43, and the pkexec
   check in #35), so that session checks the final design?**
   *Recommendation:* no for the apply path, yes for the cheap parts.
   #35 checks pkexec elevation from the `nixarchy-rebuild` unit. That does
   not change as long as the unit keeps flatsnap's in-unit run, which it
   will until nixarchy fixes the pin (question 1). #43 covers UI issues (#36,
   #28, #27, #26) that this work does not touch. Holding #43 back would
   delay four fixes for a design that is still waiting on nixarchy. If the
   flake-path and `--status`/`--log` parts are approved and merged before
   the session is booked, add one `--status`/`--log` check to that session.
   Otherwise, verify them in the session that verifies the pinned
   `--detach`.
4. **Do `ours` and `shown` stay flatsnap's?** nixarchy's `--status` has no
   concept of whose run it was. If nixarchy starts the unit, flatsnap can
   only write the marker from the launcher, after it reads the invocation
   from `--status --json`. That breaks the case #23 handled of a launcher
   killed right after `systemd-run`. *Recommendation:* keep the marker, and
   keep it written from inside the unit, for as long as the unit runs
   flatsnap (question 1). Revisit it when the pin moves to nixarchy.
5. **Do we ask nixarchy to align `--status`/`--log` with what the panel
   needs?** This covers: `none` after a stop (SubState `dead` with an
   InvocationID set), escaping the JSON, `--log` with no run printing
   everything, and a JSON refusal for "already running".
   *Recommendation:* file these in the same nixarchy issue as question 1.
   Until nixarchy changes, flatsnap maps them at its own boundary, in one
   place.
