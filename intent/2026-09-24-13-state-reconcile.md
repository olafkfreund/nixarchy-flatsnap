---
status: approved
issue: 13
author: olafkfreund
---

# Intent: declared state that is kept, and reached

## Problem

`flatsnap.nix` is meant to be the one place that says which Flatpaks and
Snaps the machine has. Today it can quietly fail at that in two ways. What the
user asked for can be lost before it reaches the file. Or it can reach the
file and never be applied. The 2026-09-24 review found these cases. Line
numbers are for `main` at 64f97b2.

**Confirmed (reproduced, or clear from the code alone)**

- **C1: lost writes.** `add` and `rm` (`bin/nixarchy-flatsnap:310-348`,
  `:352-364`) read the state, change it and write it back, with no lock. Two
  panel actions, or a panel action plus a terminal command, can overwrite each
  other. Twenty concurrent `add` calls leave one entry, and all twenty exit 0.
  Nothing tells the user anything was lost.
- **C2: a classic/strict change is never applied.** The reconciler
  (`bin/nixarchy-flatsnap-reconcile:40`) compares only the tracking channel.
  Turning `classic` on or off while keeping the same channel changes the file
  and does nothing on the machine. `--classic` is passed only on install or on
  a channel change.
- **C3: pending removals dropped on a snapd failure.** `write_state`
  (`bin/nixarchy-flatsnap:266-268`) prunes `pendingRemoval` against
  `snap list 2>/dev/null`. If snapd is down or slow, the list comes back
  empty, so every pending removal is treated as done. The next apply can then
  turn snapd off while the snap is still installed. That strands the snap, and
  the module exists to prevent exactly that.
- **C4: a backup that cannot help.** `write_state` already writes to a
  mktemp file, parse-checks it and `mv`s it into place. That is atomic, and
  `$f` is never touched on failure. The `.bak` copy (`:273`) and restore
  (`:278`) add nothing, with one exception: `$f` is gone but an old `.bak`
  is still there, and the new file fails to parse. In that case, a stale
  state is restored. `docs/record.sh:170` also cleans up the `.bak`. The spec
  for #1 (`spec/2026-09-23-1-flatpak-snap-menu.md:78`) and its plan
  (`:18`) describe this backup step as the idiom, so removing it changes
  approved wording.
- **C5: a default channel the snap may not publish.** The CLI (`:36`),
  `lookup_snap` (`:123-139`) and the panel (`FlatsnapModel.qml:113`) all
  default to `stable`, even for a snap with no `latest/stable`. The card then
  shows a channel that queues fine and fails at apply. `cycleChannel`
  (`FlatsnapModel.qml:124-138`) filters to published channels, but only once
  the user presses the key. This is confirmed from the code. No fixture covers
  it: both `tests/fixtures/snap-info-*.json` publish `stable`.

**Plausible (the code path is confirmed; snapd's behaviour is not verified)**

- **C6: non-`latest` tracks.** `CHAN_RE` allows only a risk (`stable` …
  `edge`), and both `lookup_snap` (`:124`) and the reconciler (`:40`) assume
  the `latest` track. Suppose a snap's default track is something else, and
  `snap list` reports e.g. `22/stable`. Then the comparison never matches, and
  the reconciler runs `snap refresh` on every apply. `lookup_snap` would also
  show no channels at all for such a snap.

**Low / hygiene (latent, no user-visible failure today)**

- **C7: `nixstr` doubles backslashes.** `nixstr` (`:236`) writes each
  backslash as two. This is latent, because the ID grammars already forbid
  `\`. The `${` escaping is correct.
- **C8: one pipeline, three copies.** The installed-list → JSON pipeline
  appears three times (`:267`, `:287-290`, `:406`). That is how C3 exists in
  one copy and not the others.
- **C9: two loose input checks.** `FP_RE` (`:12`) has no length cap, unlike
  `SNAP_RE`. The `parse_install` prefix match (`:59`) has no trailing space,
  so `flatpak installx …` is accepted as an install command.

## Proposed outcome

- Every `add` or `rm` that exits 0 is in `flatsnap.nix` afterwards, even when
  it runs at the same time as another. Two concurrent writers never lose an
  entry.
- After an apply, each declared snap has the declared confinement as well as
  the declared channel. When that is not possible, the apply fails visibly and
  says why. It never quietly leaves the machine different from the file.
- A pending removal is dropped only when snap reports that the snap is gone.
  If snap cannot be asked, the removal stays pending and snapd stays on.
- `write_state` keeps its current guarantee (a failed write leaves the file as
  it was) with no `.bak` step. It can never restore stale state.
- The installed-list pipeline exists once. Every caller treats "could not ask"
  as unknown, not as empty.
- The hygiene items (C7, C9) are fixed, and each fix comes with a test in
  `tests/cli.sh`.
- If in scope: the channel the card shows first is one the snap publishes, and
  a snap on a non-`latest` default track does not refresh on every apply.

## Affected users and systems

- Anyone who queues or removes apps from the panel or with
  `nixarchy-flatsnap add|rm`, especially from two places at once.
- Snap users who change confinement, or who remove a snap while snapd is
  unhealthy.
- `bin/nixarchy-flatsnap` (`write_state`, `cmd_add`, `cmd_rm`, `installed`,
  `cmd_preflight`, `lookup_snap`, `nixstr`, `classify`/`parse_install`).
- `bin/nixarchy-flatsnap-reconcile`, which runs as root in
  `nixarchy-flatsnap-snaps.service` and so acts on the live system.
- `FlatsnapModel.qml` (the default channel, if C5 is in scope).
- `tests/cli.sh` and `tests/fixtures/`. `docs/record.sh:170` (the `.bak`
  cleanup).
- Documents: `spec/` and `plan/` for #1, whose backup-step wording changes.
- Test host: razer. No live test runs on p620.

## Constraints

- **A hand-installed snap is never removed.** This is the existing rule: only
  names in the reconciler's `managed` file can be removed. Nothing here may
  widen that. That includes a reinstall done to change confinement.
- **No new dependencies** beyond coreutils and util-linux. `flock` comes from
  util-linux, so the CLI package's runtime inputs must provide it.
- **Unknown is not empty.** When `snap` or `flatpak` cannot be asked, callers
  must not act as if nothing is installed.
- **A failed write leaves the file as it was.** Keep the parse check, and keep
  refusing any file that is not in this tool's shape.
- **No change to the file format.** Existing `flatsnap.nix` files must load
  unchanged.
- **Removal keeps `--purge`** (see the reconciler comment on NixOS PAM).
  Warning the user about that data loss is Group D (D5), not this task.
- Everything except the apply-path safety work (Group B) and the store trust
  UX (Group D) is out of scope, unless a fix here has to touch the same lines.

## Open questions

1. **How is a classic↔strict change applied?** snap has no in-place switch
   between strict and classic, so there are three options:
   - (a) **Reinstall.** Run `snap remove --purge` then `snap install` with the
     new confinement, only for managed snaps. This loses the snap's data.
   - (b) **Refuse.** Leave the snap alone, mark the unit failed, and log a
     message saying to remove and re-add the snap.
   - (c) **Block in the CLI.** Refuse the change at `add` time for an
     installed snap, so the file never asks for a switch the machine cannot
     make.

   *Recommendation:* (b) in the reconciler and (c) in the CLI/panel. Both
   are visible, and neither deletes data without an explicit remove.
2. **Are C5 and C6 in scope?** C5 is confirmed from the code but has no
   fixture. C6 depends on how snapd reports non-`latest` default tracks,
   which would need a check on razer first.
   *Recommendation:* C5 in scope, with a new fixture for a snap that does not
   publish `stable`. C6 in scope only if a razer check shows the
   refresh-on-every-apply behaviour. If not, split C6 into its own issue.
3. **Approve removing the `.bak` step.** Spec #1
   (`spec/2026-09-23-1-flatpak-snap-menu.md:78`) and plan #1 (`:18`) name
   "back up … restore the backup on failure" as the idiom. The same guarantee
   comes from mktemp → parse → `mv`, without the stale-restore case.
   *Recommendation:* approve. The spec for this task would record the change,
   with a dated note in plan #1, and would not rewrite approved text.
