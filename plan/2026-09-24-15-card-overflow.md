---
status: approved
issue: 15
spec: spec/2026-09-24-15-card-overflow.md
---

# Plan: the menu's card fits, or scrolls, at every desktop scale

## Approved decisions (self-contained)

**Problem (intent).** At monitor scale 2 on razer (960x540 logical), the
Add card's content is taller than the card. The card is a clipped
`Flickable` (`Menu.qml:176-181`), and no key scrolls it. `j`/`k` and
Up/Down move the list hidden behind the card. `p` focuses `ovField`, which
may be below the edge. The build log (`Menu.qml:302-310`) has no scroll
keys and jumps to its end on every new line. The footer help line
(`Menu.qml:322-327`) wraps and takes height from the card.

**Decided at intent approval:**

1. Scroll the card, and keep the focused field in view. Compact only the
   footer.
2. With a card shown, `j`/`k` and Up/Down scroll the card. PgUp/PgDn jump
   a page. No Ctrl+D/U, no Home/End.
3. The build log gets the same keys, and stops jumping to its end while
   the user has scrolled up. The list is checked on razer at scale 2, and
   gets a fix only if it does not follow `currentIndex`.
4. The footer shows only the keys for the current view.

**Decided at spec approval:**

5. Keep the "↓ more (j)" marker on the card, and on the log while it is
   scrolled up.
6. `view` and `keysHint` live in `FlatsnapModel.qml`, so the model tests
   can check them without a window.
7. Up/Down/PgUp/PgDn while a field has the keyboard scroll the card and
   hand the keyboard back to the card (`root.focusKeys()`). `j`/`k` are
   still typed into the field.
8. The log keys are checked live with **one** real apply on razer, using
   #22's clone-and-restore procedure (step 13).

**Decided by user during implementation (2026-09-24):**

9. Scroll keys must not disarm a pending confirmation (classic, override
   or queue arm, apply arm, delete arm). This covers `j`/`k` (not typed
   into a field), Up/Down and PgUp/PgDn on a card. Any other key still
   disarms. This replaces the step-5 line "a scroll key still cancels a
   pending confirmation". The rule moves from `Menu.qml`'s
   `Keys.onPressed` into `FlatsnapModel.qml` (`cancelsConfirm` and
   `keyPressed`) so `tests/model.qml` can check it. The cases are: arm →
   scroll → still armed → Enter queues; arm → another key → disarmed; `j`
   typed into a field → disarmed. In the log view no key disarms, as
   before, because that branch returns first.

**Constraints (unchanged from the intent):**

- The UI stays keyboard only.
- Single letters keep their meaning, and nothing new fires while a field
  has the keyboard.
- Font sizes are bare `Style.font.*` tokens. The `no-text-multiplier`
  check (`flake.nix:111-119`, tightened by #21) must pass.
- Colours are `Color.*` tokens (`no-hardcoded-colours`,
  `flake.nix:101-107`).
- Window geometry (`Menu.qml:70-73`) does not change.
- Trust information (verification, permissions, the classic and
  confinement warnings) is never hidden or shortened. It only scrolls.
- Live checks are on razer only, never p620.

**Design summary:**

- **`fs.view`** (model): `"log"` if `showingLog`; else `"card"` if
  `tab === 0 && card`; else `"add"` (tab 0) or `"declared"` (tab 1).
- **`fs.keysHint`** (model): the footer text for the view.

  | `view` | `keysHint` |
  | ------ | ---------- |
  | `log` | `j k PgUp PgDn scroll   Esc stops watching (the build carries on)` |
  | `card`, Flatpak | `j k PgUp PgDn scroll   p overrides   Enter queue   a apply   Esc back` |
  | `card`, Snap | `j k PgUp PgDn scroll   c channel   x classic   Enter queue   a apply   Esc back` |
  | `add` | `Enter look up / open   Ctrl+F Flathub   Ctrl+S Snap   j k move   Tab Declared   a apply   Esc back` |
  | `declared` | `j k move   d remove   a apply   Tab Add   Esc back` |

  Outside the log, `   l log` goes before `   Esc` when
  `applyLog.length > 0`.
- **`scrollBy(view, dy)`** (`Menu.qml` `root`): clamps
  `contentY + dy` to `[0, contentHeight - height]`.
- **Line step:** `FontMetrics { font.family: Style.font.family;
  font.pixelSize: Style.font.title }`, `.lineSpacing`. **Page step:** view
  height minus one line.
- **Keep the field in view:** on `ovField` getting the keyboard, scroll
  `cardView` just enough to show the row. The row position comes from
  `ovField.mapToItem(cardCol, 0, 0).y`.
- **A new card starts at the top:** `contentY = 0` when `fs.card` changes.
- **The log follows only at the bottom:** `logView.follow`. It turns off
  when a scroll key leaves the log short of the end, and on again at the
  end or whenever the log is shown.
- **README:** the Keys table gets the scroll keys.

## Steps

Each step is one commit on `fix/15-card-overflow`, and cites the step
number in its body.

1. **Rebase onto main after #21 merges.** The merge order is #21 → #15 →
   #23. Wait until #21 (the tighter `no-text-multiplier`) is on main, then
   `git fetch origin && git rebase origin/main`. → Verify by `git log
   --oneline origin/main..HEAD`, which shows only this task's commits, and
   by `nix flake check -L` passing on the rebased branch before any code
   change.

2. **`FlatsnapModel.qml`: add `view` and `keysHint`.** Both are
   `readonly property string`s, next to `rows`/`current` (`:41-42`). They
   use the rules and table above, with the store read from `card.store`.
   Nothing else in the model changes. → Verify by step 3.

3. **`tests/model.qml`: cases for step 2.**
   - `view`: `"add"` after `reset()`, `"card"` after `_showCard({store:
     "flatpak", …})`, `"declared"` after `setTab(1)`, and `"log"` with
     `showingLog = true` while a card is shown. Reset state after each
     case.
   - `keysHint`:
     - A Flatpak card has `p overrides` and no `c channel`.
     - A Snap card has `c channel` and `x classic` and no `p overrides`.
     - Declared has `d remove`, and the log has `Esc stops watching`.
     - `l log` is absent with `applyLog = []`, and present with
       `applyLog = ["x"]` (outside the log view).

   → Verify by `bash tests/model.sh` (it sources `tests/isolate.sh`) →
   `model: N passed, 0 failed`. The new cases fail when run against the
   step-1 model (quick check, not committed).

4. **`Menu.qml`: the scroll helper and line metrics.** In `root`, add
   `FontMetrics { id: lineMetrics; … }` and `function scrollBy(view, dy)`,
   and `function pageOf(view) { return view.height - lineMetrics.lineSpacing }`.
   → Verify by `nix flake check -L`: `no-text-multiplier` passes with the
   new `pixelSize: Style.font.title`.

5. **`Menu.qml`: keys.**
   - **Log.** In the `fs.showingLog` block (`:96-101`), before its
     `return`: bare `j`/Down scroll `logView` by one line, bare `k`/Up by
     minus one line, and PgDn/PgUp by a page. Each one is accepted and
     then updates `logView.follow` (step 7). Esc is unchanged.
   - **Card.** One block after the confirmation-cancel rule and before the
     Ctrl and main `switch`es: if `fs.view === "card"`, `scrollKey(k,
     bare && !typing, cardView)` gives the distance for Down/Up (± a line),
     PgDn/PgUp (± a page) and bare `j`/`k` (± a line, not while typing).
     A non-zero distance scrolls `cardView`, calls `root.focusKeys()` if
     `typing`, and is accepted. The existing Down/Up and `J`/`K` cases
     are left as they are and so still call `fs.moveCursor` in the other
     views. PgUp/PgDn are not accepted outside the card and the log.
     *(Deviation from the first draft of this step, which edited each
     `switch` case: one block covers the same keys with the same
     behaviour, and does not touch the cases.)*
   - ~~The confirmation-cancel rule is unchanged, so a scroll key still
     cancels a pending confirmation.~~ Superseded by decision 9: on a
     card, scroll keys keep the arm.

   → Verify by `nix flake check -L` and the QML load (step 11).

6. **`Menu.qml`: card position and markers.**
   - `Connections { target: fs; function onCardChanged() { cardView.contentY = 0 } }`.
   - `ovField.onActiveFocusChanged`: if it gained focus, compute the row's
     top and bottom via `ovField.mapToItem(cardCol, 0, 0).y`. Set
     `contentY` to `bottom - cardView.height` if the row is below the
     view, or to `top` if above.
   - A `MoreMarker` inline component at the file's root: a `Line`
     reading "↓ more (j)" at `opacity: 0.7`, on a `Color.menu.background`
     `Rectangle` so it stays readable over the text. It is anchored to its
     view's bottom-right, and visible while
     `view.visible && view.contentY < view.contentHeight - view.height - 1`.
     There is one for `cardView` and one for `logView`.
     *(Deviation: the draft had a bare `Line`, which is hard to read over
     the text. The log marker also drops the `!follow` term, because
     `follow` is only true at the end, so "not at the end" says the same
     thing.)*

   → Verify by the QML load (step 11) and razer (step 12).

7. **`Menu.qml`: the log follows only at the bottom.**
   - `logView` gets `property bool follow: true`.
   - `onContentHeightChanged` (`:308`) jumps to the end only if `follow`
     is true.
   - After each log scroll key: `follow = contentY >= contentHeight -
     height - 1`.
   - `Connections` on `fs.showingLog` turning true: `follow = true` and
     jump to the end.

   → Verify by razer (step 13).

8. **`Menu.qml`: the footer.** The second footer `Line` (`:322-327`)
   becomes `text: fs.keysHint`. `opacity: 0.7` and the width stay. →
   Verify by razer: each view shows its row of the table.

9. **`README.md`: Keys table (`:46-62`).**
   - The `j` `k` / `↓` `↑` row becomes "move; on a card or the build log,
     scroll".
   - New row: `PgUp` `PgDn`, "scroll a card or the build log by a page".
   - The `l` row adds: "scroll up to read back; it stops following the
     build until you scroll back to the end".

   → Verify by reading the rendered table on the PR.

10. **Plan deviations.** If any step has to differ, this file is updated
    in the same commit as the code.

11. **Local checks** (the Tests section below), all green before razer.

12. **razer: the scale checks.** Needs razer to itself (see "Reserving
    razer" below).
    - **Setup (#22's route, not a hand-staged plugin).** A throwaway
      clone of nixos_config at the commit razer's current generation came
      from, in `/tmp/flake-15` on razer:
      - `programs.nixarchy.flake = lib.mkForce "/tmp/flake-15"`;
      - the `nixarchy/nixarchy-flatsnap` input overridden to this branch's
        head.

      Build it on p620, `nix copy` it to razer, and run
      `switch-to-configuration test` there. Record the starting
      generation number first.
    - **Shell restart to load the new `Menu.qml`.** Kill the shell by pid
      (a bare `quickshell kill` needs `-p`). Then run `hyprctl dispatch
      'hl.dsp.exec_cmd("env NIXARCHY_FLAKE=/tmp/flake-15
      omarchy-launch-shell")'`. Confirm `NIXARCHY_FLAKE` from
      `/proc/<pid>/environ`, and that the plugin link points at the new
      build.
    - **Scale 2:** `hyprctl eval 'hl.monitor({ output = "eDP-1", mode =
      "1920x1080", position = "0x0", scale = 2 })'`. Record the original
      monitor line first with `hyprctl monitors`.
      - `com.spotify.Client`: the card opens at the top with "↓ more (j)".
        `j`/Down step one line and PgDn one page, down to the closing
        line. `k`/Up/PgUp go back. The marker hides at the bottom.
      - `p`: the overrides field scrolls into view with the keyboard in
        it. Typing `j` types a `j`. Down leaves the field and scrolls.
      - A classic snap (`code`): the Snap warnings can be reached, and the
        footer shows the Snap hint.
      - Ctrl+F with a common word: `j` past the last visible row keeps the
        cursor row on screen. **If it does not,** add
        `onCurrentIndexChanged: positionViewAtIndex(currentIndex,
        ListView.Contain)` to `list` (`Menu.qml:258`). Record it in this
        plan in the same commit (step 10), rebuild, and repeat this check.
      - Each view's footer matches the table.
    - **Scale 1:** the same monitor command with `scale = 1`. The card and
      footer look as before, apart from the shorter footer, and there is
      no marker when everything fits.
    - Screenshots at both scales go to branch `pr-assets/15`.

13. **razer: the log keys, with ONE real apply.** This runs in the same
    reserved window as step 12, after it, at scale 2.
    - Queue `hello-world` (snap). Press `a`, then `a` again. The real
      `nixarchy-apply` builds against `/tmp/flake-15` (preflight shows
      that; if it names `/etc/nixos`, stop and restore).
    - While it builds: `k`/PgUp scroll the log up, new lines do not pull
      it back down, and "↓ more (j)" shows. `j`/PgDn to the end follow
      again. Esc hides the log, `l` shows it at its end.
    - The switch reloads Hyprland and may close the panel (nixarchy#919)
      and reset the monitor scale. That is expected. Reopen, `l`, and
      check that the log ends in `— applied —`.
    - One attempt only. If anything outside the test restarts the shell
      or switches razer, restore and stop. Do not retry.

14. **razer: restore** (always, also after a stop):
    - `snap remove --purge hello-world`, and unmount any leftover
      `/snap/hello-world` mounts.
    - Remove `flatsnap.nix` and its lock if this run made them.
    - Switch back to the starting generation (`switch-to-configuration
      switch`, then `boot`, of `system-<start>-link`).
    - Delete **only** the generation this run made.
    - Restore the monitor line recorded in step 12 (or `hyprctl reload`).
    - Relaunch the shell without the `NIXARCHY_FLAKE` override.
    - Remove `/tmp/flake-15`.
    - Confirm 0 failed units (system and user), the plugin link back on
      its starting store path, and the generation number unchanged. Post
      that on the bus.

15. **PR.** It links the intent, spec and plan, and holds the screenshots
    and the list result (fixed or not needed). It notes that #23 rebases on
    it.

### Reserving razer

A bus claim alone has failed three times: agents that did not claim
razer restarted its shell or switched it mid-run. So for steps 12-14:

- **The user is asked to reserve razer for the window.** That means other
  agents' razer sessions are stopped, not just asked to wait. Steps 12-14
  do not start until the user confirms.
- Then read the bus right before starting, and post a claim naming the
  window and "no switches, no shell restarts until done".
- If disrupted (an outside shell restart, switch, stray keystrokes, or a
  plugin directory rewritten), restore (step 14) and stop. Report what
  happened. Do not retry without the user.
- Post "done" with the generation razer is left on.

## Tests

Nothing below runs the real `nixarchy-apply`, except step 13 on razer.

```
bash tests/model.sh   # sources tests/isolate.sh; "model: N passed, 0 failed"
bash tests/cli.sh     # unchanged CLI; still "N passed, 0 failed"
nix flake check -L    # no-text-multiplier, no-hardcoded-colours, shellcheck, checks.cli
```

- **QML load:** `Menu.qml` loads on the installed plugin layout with no
  `ReferenceError` or `TypeError` in the shell log. On razer, check the
  shell's journal right after the step-12 relaunch.
- **Live:** steps 12-13 on razer only.

## Rollback

- **Before merge:** drop the branch. Nothing outside the repo changed
  apart from razer, which step 14 restores.
- **After merge:** `git revert` the merge commit. No user file format
  changes: `flatsnap.nix` is untouched by this task.
- **On razer:** step 14. It returns to the starting generation, deletes
  only this run's generation, removes `hello-world` and `/tmp/flake-15`,
  and restores the monitor scale and the shell's environment.

## Live check on razer, first attempt (2026-09-24): not completed

razer was reserved by the user for this run, and the claim was posted on
the bus (`$XxbDi3bM…`) and acknowledged. The run was still disrupted from
outside during setup, so per the one-attempt rule it stopped before step 12's
checks. Nothing in steps 12-13 was verified. Step 14 (restore) ran.

- **Setup (done).**
  - `/tmp/flake-15` on razer was a clone of nixos_config 20b655c24, the
    source of generation 2954. It had
    `programs.nixarchy.flake = lib.mkForce "/tmp/flake-15"`, and the
    `nixarchy-flatsnap` node's `locked` in `flake.lock` was set to PR head
    5db4884.
  - It was built on razer. `nix store diff-closures` against 2954 showed
    only `nixarchy-flatsnap`, and the plugin's `Menu.qml` has `scrollBy`.
  - `switch-to-configuration test` moved the plugin link to `c8ij6xc1…`.
- **Setup gotchas, for the next run.**
  - `nix flake lock --override-input nixarchy/nixarchy-flatsnap …` drops
    the node's `follows` (nixpkgs, nix-flatpak) and pulls a second
    nixpkgs. Patching only `.nodes["nixarchy-flatsnap"].locked` (rev,
    lastModified, and narHash from `nix flake prefetch --json`) keeps them.
  - `omarchy-launch-shell` is a relaunch loop ("Omarchy shell exited with
    status 143; relaunching"). Killing the quickshell pid relaunches it with
    the loop's old environment (`NIXARCHY_FLAKE=/etc/nixos`). The relaunch
    has to kill the `omarchy-launch-shell` bash parent first, then exec the
    new one with `NIXARCHY_FLAKE=/tmp/flake-15`.
- **Disruption.**
  - At 20:25:30 BST, four ssh sessions that were not ours opened within
    one second.
  - `~/.config/omarchy/plugins/nixarchy.distrobox` was rewritten as a real
    directory (mtime 20:25:30.913), and about 40 "Local plugin changed:
    nixarchy.distrobox" reloads followed.
  - At 20:25:31.04 the shell logged `Exiting due to IPC request`, and a new
    `omarchy-launch-shell` started with `NIXARCHY_FLAKE=/etc/nixos`.
  - This is the same signature as #22's third attempt (a distrobox rewrite
    and an IPC exit).
- **Restore (done, verified by end state).**
  - `switch-to-configuration switch` of system-2954-link. No generation was
    made, so none needed deleting.
  - The plugin link is back on `ziwc8…`, and one shell runs with
    `NIXARCHY_FLAKE=/etc/nixos`.
  - eDP-1 stayed at 1920x1080, scale 1 (it was never changed).
  - `/tmp/flake-15` is removed. No `flatsnap.nix`, snap or apply.
  - 0 failed units, system and user. "done" was posted on the bus
    (`$p83lBY9z…`).
- **What the next run needs.** A user reservation plus a bus claim was not
  enough. Whatever rewrites `nixarchy.distrobox` and restarts the shell has
  to be found and stopped first. The same run could then use the corrected
  shell relaunch above.

## Live check (#33, #35), 2026-09-25

razer was reserved by the user, and the bus claim is `$Tx-y3Ts…`. The run
used main d3a2744 and passed #33's remaining check.

- **Setup.**
  - `/tmp/flake-33` was nixos_config 20b655c24, the source of gen 2954.
    Only `.nodes["nixarchy-flatsnap"].locked` was pinned to d3a2744, and
    `programs.nixarchy.flake = lib.mkForce "/tmp/flake-33"`.
  - Built on p620 (`r7r5gqnl…`). `diff-closures` against 2954 showed only
    `nixarchy-flatsnap`. Then `nix copy --no-check-sigs`, rsync and
    `switch-to-configuration test`.
  - The shell was relaunched with `NIXARCHY_FLAKE=/tmp/flake-33`.
- **Relaunch gotcha.** razer's Hyprland now takes Lua config, so
  `hyprctl dispatch exec …` is rejected (`')' expected near 'env'`). The
  relaunch is `hyprctl dispatch 'hl.dsp.exec_cmd("env NIXARCHY_FLAKE=… omarchy-launch-shell")'`.
  The first attempt killed the shell and then failed to start it, so there
  was no shell for a few minutes.
- **Apply 1** (hello-world snap, `passwordless`) ended `— applied —`
  (gen 2955).
  - Its build phase lasted about 5 s (23:44:45–23:44:50), too short to
    drive by hand.
  - The switch's Hyprland reload then closed the panel (nixarchy#919) and
    put the scale back to 1, so the scroll keys sent then did nothing.
- **Apply 2** (unit `2cfff8a7…`, gen 2956, `Result=success`) ended
  `— applied —`.
  - The clone had a temporary chain of 40 sequential derivations
    (`zz-vl-slow-N`, `sleep 2` each), so the log grew by a `building` line
    about every 2 s for about 100 s.
  - Checked at scale 2. Times are from the journal and screenshots.

| Check | Result | Evidence |
|-------|--------|----------|
| At the end, the log follows new lines | **pass** | 23:48:40 → 23:48:46: the last line went from `slow-4` to `slow-6`. |
| k k, Up and PgUp scroll during the build, and the view holds while lines arrive | **pass** | 23:48:47 → 23:48:53: the journal grew 156 → 159 lines (slow-7 → slow-10). The view stayed on `slow-25 … slow-40` both times, with "↓ more (j)". |
| j and Down while scrolled up move one line each, and it still holds | **pass** | The top moved from `slow-25` to `slow-27`. |
| Scrolling back to the end (PgDn ×10) resumes following | **pass** | 23:48:55 → 23:49:02: the last line went from `slow-11` to `slow-14`. |

#33 is closed on this evidence. The restore is recorded in
plan/2026-09-24-23-detach-apply.md, "Live check (#33, #35), 2026-09-25".
