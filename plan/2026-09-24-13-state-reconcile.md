---
status: approved
issue: 13
spec: spec/2026-09-24-13-state-reconcile.md
---

# Plan: declared state that is kept, and reached

## Approved decisions (self-contained)

Line numbers are for `main` at 337dcf3 (after #11; updated in step 2).

**Decided at intent approval**

- **Q1: classic↔strict.** The reconciler refuses: the snap is untouched, the
  unit logs one clear line and fails. The CLI blocks the same change at `add`
  time for an installed snap. There is no reinstall.
- **Q2: scope.** C5 is in, with a new fixture for a snap that does not
  publish `stable`. C6 is in only if the razer check (step 1) shows a refresh
  on every apply. If it does not, C6 goes to its own issue.
- **Q3: `.bak`.** The backup step is dropped. The spec records the change,
  and plan #1 gets a dated note.

**Decided at spec approval**

- **The classic fix covers one direction only.** Only *declared strict,
  installed classic* is refused. *Declared classic, installed strict* is a
  normal state (snapd ignores `--classic` for a strict snap) and is left
  alone.
- **The razer check (spec D8) is run by the team, not the user.** It is step
  1 of implementation.
- **Merge order is #11 → #13 → #10 → #12.** This branch is rebased on `main`
  after #11 merges, before the first code change.

**The design, from spec D1–D8**

- **D1 (C1).** `lock_state` is called first thing in `load_state`. It runs
  `mkdir -p` on the directory, opens `exec {STATE_LOCK}>"$f.lock"`, then runs
  `flock -w 30`. On a timeout it calls
  `die "another nixarchy-flatsnap is changing $f; try again"`. It returns
  early if `STATE_LOCK` is already set, so `cmd_add` → `cmd_list` does not
  deadlock. `util-linux` is added to the `runtimeInputs` of `packages.cli` and
  to the `nativeBuildInputs` of `checks.cli`.
- **D2 (C4).** In `write_state`, delete the `cp … "$f.bak"` (`:273`) and the
  restore (`:278`). The comment becomes "Write aside, parse-check, rename".
  `docs/record.sh:206` stops naming `$FS_FILE.bak`. Plan #1 gets this dated
  line under its state-file bullet (`:18`): *"2026-09-24 (#13): the
  backup/restore step was removed; mktemp → parse → mv gives the same
  guarantee. See spec/2026-09-24-13-state-reconcile.md D2."*
- **D3 (C8, C3).** One helper, `installed_ids flatpak|snap`:
  - prints `null` when the tool is absent;
  - exits 1 when the tool fails;
  - otherwise prints a JSON array.

  Its three callers:
  - `write_state` prunes `pendingRemoval` only on an array.
  - `installed` uses `installed_ids x || echo null`.
  - `cmd_preflight:403-406` dies on a failure ("could not list installed
    Flatpaks, so preflight cannot say what apply would remove"), and turns
    `null` into `[]`.
- **D4 (C2).**
  - **Reconciler.** `installed` keeps the Notes column (`$1, $4, $6`).
    `is_classic` matches `classic` as a comma-separated item. For an installed
    snap declared `classic=false` that `is_classic`, it logs to stderr:
    *"`<name>` is installed with classic confinement but declared strict;
    snap cannot switch in place. Remove it from the menu, apply, then add it
    again."* It then sets `failed=1` and `continue`s. There is no install,
    refresh or remove. This covers hand-installed snaps too.
  - **CLI.** `cmd_add snap` calls `snap_classic <name>` before `load_state`.
    That runs `snap list --unicode=never --color=never <name>` and reads
    Notes, printing `true`, `false`, or empty when unknown or not installed.
    If the snap is installed classic and the `add` is strict, it `die`s with
    *"`<name>` is installed with classic confinement; snap cannot make it
    strict in place. Remove it, apply, then add it again."* Unknown lets the
    `add` through.
  - There is no QML change: the panel already shows `{"error"}`.
- **D5 (C5).**
  - `classify`/`parse_install` set `channel_given=true` on any channel flag.
    `channel` keeps its `stable` default, so `CHAN_RE` and `cmd_add` are
    unchanged.
  - In `lookup_snap`, an implicit channel becomes the first of
    stable/candidate/beta/edge that appears in `channels`. `confinement` and
    `classic` are read for that channel. It stays `stable` when `channels`
    is empty.
  - An explicit channel that is not published fails with *"`<id>` does not
    publish `<ch>`; it has: `<list>`"*.
  - Fixture: `tests/fixtures/snap-info-no-stable.json`, derived from
    `snap-info-hello-world.json`, with the channel map filtered to beta and
    edge and name/title set to `no-stable`. It is synthetic, and its commit
    says so.
- **D6 (C7).** In `nixstr`, `gsub("\\\\"; "\\\\\\\\")` becomes
  `gsub("\\\\"; "\\\\")`.
- **D7 (C9).** `fp_id_ok() { [ ${#1} -le 255 ] && [[ $1 =~ $FP_RE ]]; }`
  replaces every `FP_RE` check. `classify` matches `"flatpak install "*` and
  `"snap install "*`, and `parse_install` checks that `${w[1]}` is `install`.
- **D8 (C6 decision rule).**
  - If the second apply refreshes a non-`latest`-track snap, the reconciler
    compares `${tracking##*/}` to `$channel`, and `lookup_snap` uses the
    snap's own track when `latest` is absent.
  - Otherwise, open a separate C6 issue with the evidence, and leave this
    spec as it is.
  - If snapd contradicts the `--classic` assumption, stop and bring D4 back
    for review.
- **Scope boundary.** This change stays in `load_state`, `write_state`,
  `cmd_add`, `cmd_rm`, the installed-list helpers, `lookup_snap`, `nixstr`,
  `classify`/`parse_install` and the reconciler. The only overlap is
  `cmd_preflight:403-406`, which #11 also touches.

## Steps

Before each step, cite it in the PARR PLAN phase. Make one commit per step.
A deviation updates this file in the same commit as the code.

1. **razer check (spec D8).** Run on razer only, never on p620. No code
   changes.
   1. Read the agent bus immediately before starting, not from an earlier
      read. Wait while another agent holds razer. Then post a claim that
      names #13 and says what will be installed.
   2. On razer, record the current generation (`nixos-rebuild list-generations
      | grep current`) and whether `nixarchy-flatsnap-snaps.service` exists.
      If it does not, build a `/tmp` clone of nixos_config with the plugin's
      module and nix-snapd, as in plan #5 step 2.3. Point `NIXARCHY_FLAKE` at
      the clone, and activate it with `switch-to-configuration test`.
   3. **Step 1 (read only).** Query
      `https://api.snapcraft.io/v2/snaps/info/<name>?fields=channel-map`
      (with the header `Snap-Device-Series: 16`) for `lxd`, `microk8s` and
      `node`. Pick one with no `latest` track, or with a non-`latest`
      default. Also record `nixarchy-flatsnap resolve <name>`.
   4. **Step 2.** Run `nixarchy-flatsnap add snap <name>`, then
      `nixarchy-flatsnap apply`, then `snap list <name>` (record Tracking).
      Apply again with no changes, then run
      `journalctl -u nixarchy-flatsnap-snaps -b | grep "refresh <name>"`.
   5. **Step 3.** Run `snap install --classic hello-world` by hand, then
      `snap list hello-world`. Expect a "--classic ignored" warning and no
      `classic` in Notes.
   6. Clean up:
      - `nixarchy-flatsnap rm snap <name>`, then apply, so the snap goes and
        `managed` stays true.
      - `snap remove --purge hello-world`.
      - Return to the recorded generation, and delete any test generations.
   7. Post the result on the bus and on #13: the snap, its Tracking, whether
      it refreshed, the `--classic` outcome, and the generation razer is left
      on.

   → **Verify:** razer is on the recorded generation, no test snap is left,
   and `flatsnap.nix` is as it was. **Then branch:**
   - Step 2 showed a refresh: step 9 is in this task.
   - Otherwise: open an issue titled "Reconcile refreshes non-latest-track
     snaps on every apply (C6)" with the evidence, link it on #13, and drop
     step 9 (record that under Deviations).
   - Step 3 showed `classic` in Notes, or an error: **stop.** Record it under
     Deviations, bring D4 back for spec review, and do not start steps 5–6.
2. **Rebase.** After #11 merges, run `git fetch && git rebase origin/main`.
   Re-read `bin/nixarchy-flatsnap` and update the line numbers above where
   they moved.
   → **Verify:** `nix flake check -L` is green on the rebased branch before
   any code change.
3. **`bin/nixarchy-flatsnap` and `flake.nix`: the lock (D1).** Add
   `lock_state`, call it from `load_state`, and add `util-linux` to
   `packages.cli` and `checks.cli`. In `tests/cli.sh`, add the concurrent test:
   20 backgrounded `run add flatpak org.test.App$i`, then `wait`. All must exit
   0, and `list` must have 20 entries.
   → **Verify:** the new test fails on the step-2 commit and passes here. The
   existing add/rm tests do not hang, which proves there is no deadlock.
4. **`bin/nixarchy-flatsnap`, `docs/record.sh`, plan #1: no `.bak` (D2).**
   Delete the two lines, update the comment, drop `$FS_FILE.bak` from
   `record.sh:206`, and add the dated note to plan #1. In `tests/cli.sh`, add
   the stale-`.bak` test: a `$f.bak` exists, `$f` is deleted, and the parse is
   stubbed to fail. `add` must exit 2, `$f` must still not exist, and no
   `.bak` must be created by any test.
   → **Verify:** the new test fails before this step and passes after it, and
   "parse failure did not restore" still passes.
5. **`bin/nixarchy-flatsnap`: `installed_ids` (D3).** Add the helper and
   switch the three callers to it. Tests:
   - A failing `snap` stub keeps `pendingRemoval`.
   - A failing `snap` stub makes `list` report `installed: null`.
   - A failing `flatpak` stub makes `preflight` exit 2 with `{"error"}`.

   → **Verify:** the three tests pass, and the existing pendingRemoval and
   preflight tests are unchanged. `grep -c 'jq -Rsc' bin/nixarchy-flatsnap`
   is 1.
6. **`bin/nixarchy-flatsnap-reconcile` and `bin/nixarchy-flatsnap`: the
   classic refusal (D4).** Do this only if step 1.5 confirmed the assumption.
   - The stub `snap` in `tests/cli.sh` stores `name tracking notes`, `list`
     prints Notes, and `install --classic` writes `classic`.
   - Reconciler tests: `code` installed classic and declared strict gives
     exit 1, the log line, no install/refresh/remove of `code`, and another
     declared snap still installed. Declared classic on a strict install gives
     no refusal and no refresh.
   - CLI tests: `add snap code` without `--classic` against an installed
     classic `code` exits 2 and leaves the file unchanged. With `--classic`,
     it succeeds.

   → **Verify:** the new tests pass, and the existing reconciler tests still
   pass with the new stub.
7. **`bin/nixarchy-flatsnap` and the fixture: the published default channel
   (D5).**
   - Add `channel_given` and the `lookup_snap` change.
   - Generate `snap-info-no-stable.json` with a `jq` one-liner from the
     hello-world fixture, recorded in the commit message.
   - Tests: `resolve no-stable` gives `channel=="beta"`, with `classic`
     matching beta. `resolve 'snap install no-stable --channel=stable'` exits
     2 and names beta and edge. `snap install hello-world --channel=beta` is
     still `beta`.

   → **Verify:** the tests pass, and the `tests/model.sh` panel tests still
   pass.
8. **`bin/nixarchy-flatsnap`: `nixstr` and the input checks (D6, D7).**
   - Tests: a hand-edited `Environment.X = "a\\b";` survives an unrelated
     `add` and reads back as one backslash.
   - A 256-character matching ID is refused by `resolve` and `add`, and a
     255-character one is accepted.
   - `flatpak installx org.gnome.Calculator` is refused.

   → **Verify:** each new test fails before this step and passes after it.
9. **Only if step 1 showed a refresh: C6 (D8).** The reconciler compares
   `${tracking##*/}` to `$channel`. `lookup_snap` falls back to the snap's own
   track when `latest` is absent. Tests:
   - A stub with `code 22/stable` and a plan with `stable` makes no `refresh`
     call.
   - A channel-map fixture with only a non-`latest` track gives a non-empty
     `channels`.

   → **Verify:** the tests pass. Then run step 1.4 again on razer (with the
   bus read, claim and generation post) and see no refresh on the second
   apply.
10. **PR.** Open the PR against `main`, linking the intent, spec and plan,
    and listing the step 1 results and the step-1 branch taken. It merges
    after #11 and before #10.
    → **Verify:** CI and `nix flake check -L` are green, and review compares
    the diff with this plan.

## Tests

Run from the worktree. `checks.cli` builds in the Nix sandbox, where
`tests/cli.sh`'s stubbed `nixarchy-apply` cannot reach the real one, so it is
safe on any host. Do not run `bash tests/cli.sh` directly on p620.

```bash
nix flake check -L                                  # shellcheck, cli, gating, module VM test
nix build -L .#checks.x86_64-linux.cli              # the offline CLI + reconciler suite alone
bash tests/model.sh                                 # panel model (no apply involved)
grep -c 'jq -Rsc' bin/nixarchy-flatsnap             # 1 after step 5
```

Expected result: all green, with new assertions for C1, C2, C3, C4, C5, C7,
C8 and C9 (and C6 if step 9 runs). The `module` VM test is unchanged and
passes.

## Rollback

- **Code.** Revert the PR's merge commit. The file format is unchanged, so
  every existing `flatsnap.nix` loads the same before and after. A leftover
  `flatsnap.nix.lock` is inert.
- **A single step.** Each step is its own commit and can be reverted alone.
  Step 5 reverts together with any later step that calls `installed_ids`.
- **razer.** Switch to the generation recorded in step 1.2, delete the test
  generations, and run `snap remove --purge` on any test snap still listed
  (`hello-world`, the C6 snap). Post the generation on the bus.
- **Plan #1 note.** Reverting step 4 removes the dated line too.

## Deviations / results

### Step 1: razer check (2026-09-24, about 12:50–13:05Z)

The full evidence is on #13
(https://github.com/olafkfreund/nixarchy-flatsnap/issues/13#issuecomment-5814448316).

- **Branch taken: C6 is in scope, so step 9 runs.** No separate issue was
  opened. `node` (default track `24`, no `latest/stable` on amd64) was
  installed by the reconciler as `24/stable`. On each of two later runs with
  no changes, the reconciler logged `refresh node -> stable` and snap
  answered "no updates available".
- **D4 assumption confirmed; steps 6 and 7 go ahead as written.**
  `snap install --classic hello-world` printed "Warning: flag --classic
  ignored for strictly confined snap hello-world", exited 0, and
  `snap list` shows Notes `-`.
- **C5 seen live.** `resolve https://snapcraft.io/node` gives
  `channel: "stable"` with `channels: ["edge"]`, because `lookup_snap` only
  reads the `latest` track. Step 9's `lookup_snap` fallback has a real
  example: `node` has a `latest` track, but only `edge` is on it, and
  `stable` is on `24`.
- **Deviation from step 1.4.** "Apply" was not `nixarchy-flatsnap apply`.
  I built a `/tmp` clone of nixos_config main (cc89f44b9, flatsnap input
  09fe804, reconciler identical to main) that declares `node`, and activated
  it with `switch-to-configuration test`. That first activation was
  reconciler run 1. Runs 2 and 3 were `systemctl restart
  nixarchy-flatsnap-snaps`. A no-change apply does not restart this oneshot
  unit (its `ExecStart` is unchanged), so in production the extra refresh
  happens on every boot and on every switch that changes the snap plan, not
  on every apply. Step 9's re-check on razer uses the same restart method.
- **Razer afterwards.** Razer is on generation 2949 (`/run/current-system`
  `…43x4a2bh…-6774f7b`), with 0 failed units, both test snaps purged,
  `managed` empty, and snapd inactive. The core24 mount this test added was
  unmounted. The generation was posted on the bus.

### Step 9: C6, deviations from the plan (2026-09-24)

- **`lookup_snap` reads the snap's `default-track`, not only when `latest`
  is absent.** The planned fallback would not have fixed the snap that
  prompted it. `node` does have a `latest` track, but that track has only
  `edge`. Meanwhile snap installs a bare `--channel=<risk>` from the default
  track: on razer, `--channel=stable` gave `24/stable`. So `lookup_snap` now
  selects `$j."default-track" // "latest"`, which describes exactly what
  `snap install` will do. The info API returns `default-track` alongside the
  requested fields (checked live for `node`: `"24"`). The existing fixtures
  have none, so they still read `latest`.
- **The reconciler compares the risk, not `${tracking##*/}`.** `risk()`
  takes the second segment (`24/stable` gives `stable`, and
  `latest/edge/fix` gives `edge`). A branch suffix would otherwise have been
  compared as if it were the risk.
- **Tests.**
  - `tests/fixtures/snap-info-trackdemo.json` is synthetic, derived from the
    hello-world fixture: default track `24` with `24/stable` classic, plus
    `latest/edge` strict. `resolve` gives `channels == ["stable"]` and
    classic.
  - The reconciler stub uses `node 24/stable classic`. A plan with `stable`
    makes no `refresh`, and this test reproduces the razer log line exactly
    before the fix. A real change to `edge` still refreshes.
