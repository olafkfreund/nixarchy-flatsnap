---
status: approved
issue: 36
spec: spec/2026-09-25-36-footer-glitches.md
---

# Plan: the panel footer fits, offers only keys that work, and tells the truth about the build

Branch `fix/36-footer-glitches`. This merges **first** in the batch:
#36 → #28 → #27 → #26. All four touch `Menu.qml` and `FlatsnapModel.qml`.
Each later branch is rebased onto the one before it, and `tests/model.sh`
runs again after each rebase.

## Note, 2026-09-25: razer moves to one combined session (user decision)

The razer check (step 5) no longer runs for this PR alone. It runs in
**one combined razer session after #36, #28, #27 and #26 have all
merged.**

- Steps 1–4 are implemented. Step 4 (cause A: the card keeps its bottom
  edge) ships on local evidence as the most likely cause.
- The combined session confirms the cause. If it turns out to be B1 or
  B2, a small follow-up fix follows. Step 4 is not held back.
- One small real apply is allowed in that session, to check the
  ended-log hint.
- The relaunch and scale commands are the ones recorded in
  plan/2026-09-24-15-card-overflow.md (step 12):
  - `hyprctl dispatch 'hl.dsp.exec_cmd("env NIXARCHY_FLAKE=/tmp/flake-36 omarchy-launch-shell")'`
  - `hyprctl eval 'hl.monitor({ output = "eDP-1", mode = "1920x1080", position = "0x0", scale = 2 })'`,
    after recording the original line with `hyprctl monitors`.
- Step 6's PR therefore says `Closes #36`, with the razer check pending
  in the combined session.

**Deviations in step 2,** found while implementing: two existing checks
asserted the old texts, so they change with the hints.

- `tests/model.qml:25`: the add hint is checked for `Enter open`, not
  `Ctrl+F`. The list hint no longer names Ctrl+F.
- `:29-30`: the Flatpak card hint is checked for `j k scroll`, not
  `PgUp PgDn scroll`.

## Approved decisions

This section is self-contained. The intent and spec do not need to be
open to implement it.

**The problems** (razer live check for #23, scale 2 = 960x540 logical):

1. The footer hint wraps, and an armed red message hides the card's last
   line (`sockets:` on `com.spotify.Client`).
2. While a text field has the keyboard, the hint offers letter keys that
   would be typed into the field instead: `l log`, `j k`, `a apply`, and
   on a card `p`.
3. After the build has ended, the log hint still says "the build carries
   on".

**Decided at intent approval:**

- Every hint fits on one line at scale 2. The card also handles a footer
  that wraps anyway, for example at a raised text size.
- While a field has the keyboard, the hint lists only keys that work
  there. In the app ID field those are Enter, Ctrl+F, Ctrl+S, Tab and
  Esc. In the overrides field they are `Enter queue` and `Esc back`.
- The model gets a `typing` flag that `Menu.qml` sets. `keysHint` stays in
  the model.
- The red message over the card is reproduced on razer first, and only
  the fix for the cause razer shows ships. The arming key does not
  scroll the card.

**Decided at spec approval:**

- Hint items are separated by two spaces instead of three.
- Cards leave `PgUp PgDn` out of the hint. The keys still work, and the
  README lists them (`README.md:51`).
- The Add list leaves Ctrl+F and Ctrl+S out of the hint. The field's
  hint and the empty-list text (`Menu.qml:362`) still name them.
- While a build runs, the log hint says `Esc leaves it running`.
- The budget is **72 characters** per hint, accepted as an estimate:
  about 632 px of text width at scale 2 with 14 px monospace is about 75
  characters. Razer checks the real width.

**The hints** (`keysHint`, `FlatsnapModel.qml:47-54`):

| State | Hint |
| ----- | ---- |
| log, `applying` | `j k PgUp PgDn scroll  Esc leaves it running` |
| log, not `applying` | `j k PgUp PgDn scroll  Esc back` |
| add, `typing` | `Enter look up  Ctrl+F Flathub  Ctrl+S Snap  Tab Declared  Esc back` |
| add | `j k move  Enter open  / edit  Tab Declared  a apply` + L + `  Esc back` |
| declared | `j k move  d remove  a apply  Tab Add` + L + `  Esc back` |
| card, `typing` | `Enter queue  Esc back` |
| card, Flatpak | `j k scroll  p overrides  Enter queue  a apply` + L + `  Esc back` |
| card, Snap | `j k scroll  c channel  x classic  Enter queue  a apply` + L + `  Esc back` |

L is `  l log` when `applyLog.length > 0`, and is empty otherwise. It
never appears in the log or in a `typing` state. The longest hint (Snap,
with L) is 71 characters.

**Cause A of the overlap** (the likely one). When the footer grows, the
card gets shorter but keeps its `contentY`, so what was at its bottom edge
goes out of sight. The clamp in `scrollBy` (`Menu.qml:58-60`) cannot fix
this: a shorter view only raises the most `contentY` can be. The fix
keeps the bottom edge in place:

```qml
// cardView: a footer line appearing takes height from the bottom;
// keep what was at the bottom edge in sight, not what was at the top.
property real _lastHeight: 0
onHeightChanged: { if (_lastHeight > 0) root.scrollBy(cardView, _lastHeight - height); _lastHeight = height }
```

The log gets the same fix, `onHeightChanged: if (follow) toEnd()`, next to
`onContentHeightChanged` (`Menu.qml:378`).

**Cause B1:** the `↓ more (j)` marker (`Menu.qml:89-98`) covers the line
because rounding misses the end by more than 1 px. Fix: its `visible`
becomes `view.visible && !view.atYEnd && view.contentY < view.contentHeight - view.height - 1`.

**Cause B2:** the footer is painted over the card. Fix: the footer
`Column` (`Menu.qml:387`) gets `height: implicitHeight`.

**Unchanged:** what any key does, `cancelsConfirm`/`keyPressed` and their
`typing` parameter, every `pixelSize` (bare `Style.font.*`), colours
(`Color.*`, the armed message stays `Color.urgent`), window geometry,
card content, `bin/`, the NixOS module, the README.

## Steps

Each commit cites its step, for example `fix(menu): … (#36, plan step 2)`.

1. **`FlatsnapModel.qml`: `typing` and the new hints.**
   - Add `property bool typing: false` after `view` (`:46`), with the
     comment "set by Menu.qml: a text field has the keyboard, so letters
     are typed, not run".
   - Rewrite `keysHint` (`:47-54`) to the table above. The log state
     reads `applying`. `typing` in `add` and `card` returns the field
     hints with no L.

   → verify by `grep -n 'carries on\|   ' FlatsnapModel.qml`. The only
   hits are the log's first line (`:333`) and indentation, and no hint
   string has three spaces.

2. **`tests/model.qml`: the checks** (the block at `:21-43`).
   - `:32` expects `l log  Esc back`.
   - `:35` splits in two:
     - `fs.applying = true`: the hint contains `Esc leaves it running`
       and not `l log`.
     - `fs.applying = false`: the hint equals
       `j k PgUp PgDn scroll  Esc back`.
   - New: `fs.typing = true` in the add view with `applyLog = ["x"]`. The
     hint contains `Enter look up`, `Ctrl+F` and `Tab Declared`. It
     contains none of `j k`, `a apply` or `l log`.
   - New: `fs.typing = true` on a Flatpak card. The hint equals
     `Enter queue  Esc back`.
   - New budget sweep. Loop over:
     - a card of store `flatpak`, a card of store `snap`, no card on tab
       0, tab 1, and `showingLog`;
     - × `typing` true/false;
     - × `applyLog` empty/`["x"]`;
     - × `applying` true/false.

     Check `t.ok(fs.keysHint.length <= 72, "budget " + fs.keysHint.length + ": " + fs.keysHint)`.
   - Afterwards reset `typing = false`, `applying = false`,
     `showingLog = false`, `applyLog = []`, `card = null` and `setTab(0)`.

   → verify by `bash tests/model.sh` printing `model: N passed, 0 failed`.
   It runs on p620 in the isolated PATH (`tests/isolate.sh`). Only stubs
   and store tools are reachable, and no apply can start. To check that
   the tests catch a mistake: temporarily put a three-space separator
   back into one hint, run the tests, and see the budget check or the
   exact-match check fail. Then undo it.

   Steps 1 and 2 are one commit.

3. **`Menu.qml:42`: bind the flag.**
   `FlatsnapModel { id: fs; typing: field.activeFocus || ovField.activeFocus }`.
   The local `typing` in `Keys.onPressed` (`:138`) stays.

   → verify by `nix flake check` passing (`no-text-multiplier`,
   `no-hardcoded-colours`, the rest), and `bash tests/model.sh` again.
   Commit.

4. **`Menu.qml`: the cause-A fix, as a separate commit.**
   - Add `_lastHeight`/`onHeightChanged` to `cardView` (after `:237`).
   - Add `onHeightChanged: if (follow) toEnd()` to `logView` (next to
     `:378`).

   This commit is built for razer but ships only if step 5 shows cause A.

   → verify by `nix flake check` and `bash tests/model.sh`. Record the
   commit SHAs of step 3 (the "hints" build) and step 4 (the "fix A"
   build).

5. **Razer: reproduce, pick the cause, check everything.**
   - **Before anything else:** the user reserves razer. Read the agent
     bus immediately before, and post a claim. **Never on p620.**
   - **Setup.** Follow plan/2026-09-24-23-detach-apply.md step 9:
     - Record razer's generation (expected **2957**) and the flatsnap
       plugin link.
     - Clone razer's current nixos_config source to `/tmp/flake-36` on
       razer, with `programs.nixarchy.flake = lib.mkForce "/tmp/flake-36"`.
     - In the clone's `flake.lock`, edit only the nested
       `nixarchy-flatsnap` node's `locked` entry, not
       `--override-input`. Build two toplevels on p620, one pinned to the
       step-3 SHA and one pinned to the step-4 SHA. `nix store
       diff-closures` against gen 2957 must show only `nixarchy-flatsnap`.
     - `nix copy --no-check-sigs` both to razer.
   - **Switch.** `switch-to-configuration test` the step-3 build. A
     switch reloads Hyprland and closes the panel (nixarchy#919).
   - **Relaunch the shell.**
     - Kill `omarchy-launch-shell` first, because it relaunches the shell
       in a loop.
     - Kill the shell by pid, found with `pgrep -x .quickshell-wra`, not
       `pgrep -f`.
     - Relaunch with `hyprctl dispatch 'hl.dsp.exec_cmd("env NIXARCHY_FLAKE=/tmp/flake-36 omarchy-launch-shell")'`.
       Razer's Hyprland uses the Lua config. If #23's session used a
       different launch command, use that one instead.
     - Confirm `NIXARCHY_FLAKE` from `/proc/<pid>/environ`, and that
       `pgrep -x .quickshell-wra` counts exactly one shell.
   - **Scale.** Set monitor scale 2 with
     `hyprctl eval 'hl.monitor({ output = "eDP-1", mode = "1920x1080", scale = 2 })'`.
     Record the original monitor line first, to restore it.
   - **Drive.** Use wtype and grim over ssh, with the shell's own
     environment, and `omarchy-shell shell toggle nixarchy.flatsnap`.
   - **Checks on the step-3 build:**
     1. Screenshot each state and confirm the hint is on one line:
        - the Add view with the field focused (on open);
        - the Add view after Ctrl+F `editor` (list, keys);
        - a Flatpak card (`com.spotify.Client`) and a Snap card;
        - the overrides field after `p`;
        - Declared.

        `l log` appears only if razer has a log this session. Record
        whether it does.
     2. The field-focused Add hint has no `l`, `j k` or `a`. After `p`,
        the hint reads `Enter queue  Esc back`.
     3. **Pick the cause.** On `com.spotify.Client`'s card:
        1. PgDn until `↓ more` is gone. Screenshot.
        2. Press `p`, type `Context.sockets=x11`, and press Enter. The
           message is armed and red. Screenshot.
        3. Press `j`. Screenshot.

        How to read it:
        - **A:** the card's text ends cleanly above the message, the
          marker is back, and `j` brings `sockets:` into view.
        - **B1:** the marker sits over `sockets:` with nothing more
          below.
        - **B2:** text is drawn over text.
     4. Esc until the card closes. The message is cancelled and nothing
        is queued.
   - **If A:** `switch-to-configuration test` the step-4 build, then
     relaunch and set the scale again as above. Repeat check 3.
     `sockets:` must be visible under the armed message with no key
     pressed. Also check the log (below) if it was shown.
   - **If B1 or B2:** end the session (restore below), add that fix in
     `Menu.qml` as its own commit, drop the step-4 commit
     (`git revert` or rebase), and repeat step 5 with that build. If A
     and B1 both show, both fixes stay.
   - **The ended-log hint** needs a finished apply. It is checked on
     razer only if the user allows one small real apply in this session.
     Otherwise it is covered by the headless test in step 2, and the PR
     says so. Never snap-remove `core`.
   - **Scale 1.** Restore the original monitor line. The same card and
     the same armed message look as they do today, apart from the hint
     text. Screenshot.
   - **If disrupted** (an outside shell restart, keystrokes that are not
     ours, another session): restore and stop. No retry.
   - **Restore, always.**
     - The original monitor line.
     - `switch-to-configuration switch` of gen 2957's toplevel.
     - Check the plugin link is back.
     - Relaunch the shell the normal way, with no `NIXARCHY_FLAKE`
       override, and check `pgrep -x .quickshell-wra` counts one.
     - Disarm or Esc anything left open.
     - `rm -rf /tmp/flake-36`.
     - 0 failed units, system and user.
     - Post the generation razer is left on, and release the claim.

   → verify by the screenshots and a results table added to this plan
   under "Live check on razer", in the same commit as any code change the
   check forces.

6. **PR.** Push, then open a PR against `main`:
   - `Closes #36`, links to the intent, spec and plan, the razer table,
     and which cause it was.
   - The merge-order note: first of #36 → #28 → #27 → #26.

   → verify by CI green (flake check, shellcheck, the tests CI runs), and
   the diff matches this plan.

## Tests

| Command | Where | Expected |
| ------- | ----- | -------- |
| `bash tests/model.sh` | p620, isolated PATH | `model: N passed, 0 failed` |
| `nix flake check` | p620 | passes, including `no-text-multiplier` and `no-hardcoded-colours` |
| `bash tests/cli.sh` | p620, isolated PATH | passes, with no `bin/` change |
| Razer step 5 | razer only | every hint on one line at scale 2, the field hints right, `sockets:` visible under an armed message, scale 1 as before |

## Rollback

- **Code:** revert the PR's commits. Steps 1–3 and step 4 are separate
  commits, so the hint change and the overlap fix can be reverted apart.
  No state, file format, CLI or module changes, so nothing needs
  migrating.
- **Razer:** `switch-to-configuration switch` of gen 2957, restore the
  monitor line, relaunch the shell normally, and `rm -rf /tmp/flake-36`.
- **Batch:** if #36 has to be reverted after #28/#27/#26 are rebased on
  it, revert only the #36 commits on `main`. Then run
  `bash tests/model.sh` on `main`, because a later branch may have
  started using `typing` or the new hint texts.
