---
status: approved
issue: 36
intent: intent/2026-09-25-36-footer-glitches.md
---

# Spec: the panel footer fits, offers only keys that work, and tells the truth about the build

## Design

**Decided at intent approval:**

1. Every hint is short enough for one line at scale 2. The card also
   handles a footer that wraps anyway, for example at a raised text size.
2. While a field has the keyboard, the hint lists only keys that work
   there. In the app ID field those are Enter, Ctrl+F, Ctrl+S, Tab and
   Esc. In the overrides field they are `Enter queue` and `Esc back`.
3. The model gets a `typing` flag that `Menu.qml` sets. `keysHint` stays in
   the model.
4. For the armed message over the card: reproduce it on razer first, then
   fix the cause. The arming key does not scroll the card.
5. After a build, the log hint is `j k PgUp PgDn scroll   Esc back`. The
   separator changes are covered under "The hints" below.

No key changes what it does. The changes are the footer text, one model
property, and how the card and the log keep their bottom edge when the
footer changes height.

### The model knows when a field has the keyboard (`FlatsnapModel.qml`)

A new `property bool typing: false` goes next to `view`
(`FlatsnapModel.qml:46`). The model never sets it. `Menu.qml` binds it
where the model is created (`Menu.qml:42`):

```qml
FlatsnapModel { id: fs; typing: field.activeFocus || ovField.activeFocus }
```

This is the same expression as the local `typing` in `Keys.onPressed`
(`Menu.qml:138`). That local stays as it is, because it is read in the
same handler that may move the focus. `cancelsConfirm`/`keyPressed`
(`FlatsnapModel.qml:318-327`) keep their `typing` parameter, so their
tests do not change. A bound property also moves the hint when focus
changes without a key press. That happens on open (`Menu.qml:36`), on
`p` (`:202`) and on Esc from a card (`:172`).

### The hints (`keysHint`, `FlatsnapModel.qml:47-54`)

Budget: **72 characters** per hint in its longest form (with `l log`).
Worked out for razer at scale 2 with the default text size:

- The card is 960 × 0.7 = 672 px wide (`Menu.qml:115`). Take away 18 px
  of `panelPadding` on each side and the border, and about 632 px is left
  for text.
- `Style.font.title` is 14 px in the monospace family, and one character
  is about 8.4 px wide. That fits about 75 characters.
- 72 leaves a small margin. The razer step checks the real width.

Today's hints are 64 to 106 characters, so all of them are too long. To
fit the budget:

- The separator goes from three spaces to two.
- On cards, `PgUp PgDn` is left out of the hint. The keys still work, and
  the README lists them (`README.md:51`).
- The Add list no longer names Ctrl+F and Ctrl+S. The field's own hint
  does, and so does the empty list's text (`Menu.qml:362`, "Paste and press
  Enter. Ctrl+F searches Flathub, Ctrl+S the Snap Store.").

| State | Hint | Length |
| ----- | ---- | ------ |
| log, `applying` | `j k PgUp PgDn scroll  Esc leaves it running` | 43 |
| log, ended | `j k PgUp PgDn scroll  Esc back` | 30 |
| add, `typing` | `Enter look up  Ctrl+F Flathub  Ctrl+S Snap  Tab Declared  Esc back` | 66 |
| add, keys | `j k move  Enter open  / edit  Tab Declared  a apply  l log  Esc back` | 68 |
| declared | `j k move  d remove  a apply  Tab Add  l log  Esc back` | 53 |
| card, `typing` (overrides field) | `Enter queue  Esc back` | 21 |
| card, Flatpak | `j k scroll  p overrides  Enter queue  a apply  l log  Esc back` | 62 |
| card, Snap | `j k scroll  c channel  x classic  Enter queue  a apply  l log  Esc back` | 71 |

As today, `l log` appears only while `applyLog.length > 0`, and never in
the log or in a `typing` state. On the Declared tab no field can have the
keyboard: Tab calls `focusKeys` (`Menu.qml:188`).

The log state now reads `applying` (`FlatsnapModel.qml:37`). While the
build runs, `Esc leaves it running` keeps the promise from #23 in fewer
words. The first line of the log (`FlatsnapModel.qml:333`) does not
change.

### The card keeps its bottom edge when the footer changes height (`Menu.qml`)

The card ends at `footer.top` (`:232`). When the red message appears, the
card gets one line shorter, but its `contentY` stays the same. So what
was at the bottom edge goes below it. On the Spotify card this is the
last line, or the overrides row after `p`. The clamp in `scrollBy`
(`:58-60`) cannot fix this. A shorter view raises the most `contentY` can
be, so the old value is still allowed.

There are two possible causes, and the razer step below picks between
them.

**Cause A: the content does not move when the view gets shorter**
(likely). The fix makes the card keep its bottom edge. When the height
changes, `contentY` moves by the change and is clamped:

```qml
// cardView: a footer line appearing takes height from the bottom;
// keep what was at the bottom edge in sight, not what was at the top.
property real _lastHeight: 0
onHeightChanged: { if (_lastHeight > 0) root.scrollBy(cardView, _lastHeight - height); _lastHeight = height }
```

This works both ways. When the message goes away, the card gets taller
and shows more above, clamped at 0. When a card first opens it still
starts at the top: `onCardChanged` sets `contentY = 0` (`:237`), and the
height does not change then.

The log has the same problem. `logView` goes to its end only when the
content grows (`:378`), not when the view gets shorter. One line fixes
it, using the follow rule from #15:
`onHeightChanged: if (follow) toEnd()`.

The list follows `currentIndex` (razer pass for #15,
`plan/2026-09-24-23-detach-apply.md:452`), so it gets no change.

**Cause B: something is drawn over the card.**

- **B1, the `↓ more (j)` marker** (`:89-98`). It is visible only while
  `contentY < contentHeight - height - 1`, so at the true end it is gone.
  It covers the last line only if the end is missed by more than 1 px
  (fractional scale rounding). Fix: the end test becomes
  `view.atYEnd || …`, or the tolerance becomes half a line
  (`lineMetrics.lineSpacing / 2`).
- **B2, the footer painted over the card** (glyphs on glyphs). This would
  mean `footer.top` does not follow the `Column`'s height. Fix: give the
  footer `Column` an explicit
  `height: implicitHeight` so the anchor updates in the same frame.

**Razer step that picks** (scale 2, default text size):

1. Open `com.spotify.Client`'s card.
2. PgDn until the `↓ more` marker is gone. Screenshot.
3. Press `p`, type `Context.sockets=x11`, then press Enter. The message
   is armed and red. Screenshot.
4. Press `j`.

How to read the result:

- **A:** in shot 3 the card's text ends cleanly above the message, the
  marker is back, and `j` brings `sockets:` into view.
- **B1:** the marker sits over `sockets:` with nothing below it.
- **B2:** text is drawn over text.

Only the fix for the cause that razer shows ships. The PR says which
cause it was. If A and B1 both show, both fixes ship.

### Tests (`tests/model.qml:21-43`)

The existing block is updated:

- `l log   Esc back` becomes `l log  Esc back` (`:32`).
- The log check (`:35`) splits in two. With `applying = true` the hint has
  `Esc leaves it running`. With `applying = false` it equals
  `j k PgUp PgDn scroll  Esc back`, with no `carries on` and no
  `l log`.

New checks:

- `typing = true` in the add view. The hint has `Enter look up`,
  `Ctrl+F` and `Tab`. It has no `j k`, no `a apply` and no `l log`, even
  with a log.
- `typing = true` on a Flatpak card. The hint equals
  `Enter queue  Esc back`.
- A budget sweep: for every view × store × `typing` × log present or
  not × `applying`, `keysHint.length <= 72`. The failing hint is printed.
- The test resets `typing` and `applying` afterwards, so later tests start
  clean.

### README

No key changes, so the Keys table (`README.md:46-62`) stays. Its Esc row
(`:62`) is still true.

### Not changed

What any key does. `cancelsConfirm`, colours, every `pixelSize`, the
window geometry, the card's content, `bin/`, the NixOS module.

## Alternatives rejected

- **Make letter keys work inside the field.** They could then not be
  typed into an app ID or an override. Ruled out at intent approval.
- **Build the hint in `Menu.qml`,** where focus is known. That would move
  the text out of the model, and `tests/model.qml` checks it there
  headless. Ruled out at intent approval.
- **Scroll the card to the end when a confirmation arms.** It would move
  the card under the user on a key that is not a scroll key. Ruled out at
  intent approval. Keeping the bottom edge in place shows the same lines
  without jumping.
- **Clamp `contentY` again on a height change.** A shorter view only
  raises the maximum, so the clamp never moves anything. It does not fix
  cause A.
- **Keep three-space separators and drop more words** (`Esc back` or
  `a apply` from cards). Esc is the only way out of a card, and `a` is
  the next step after queueing. Two spaces cost less than either.
- **Drop `l log` everywhere** and rely on the tabs line
  (`rebuilding… l shows it`, `Menu.qml:225`) and the end message
  (`FlatsnapModel.qml:342`). The message clears on the next key, so after
  the build ended nothing would point to `l`.
- **A second footer line or a smaller text token at small sizes.** A
  smaller token breaks the bare `Style.font.*` rule. A second line is the
  bug.

## Risks

- **Binding loop on `cardView` height.** `onHeightChanged` writes
  `contentY`, never `height`, so it cannot loop. The marker's `visible`
  reads both but writes neither.
- **The `typing` binding at startup.** `field` and `ovField` exist before
  `fs` is used. `ovField` sits inside the card's `Column` and exists even
  when the card is hidden. It is never null.
- **The 72 budget is an estimate.** A wider fallback font, or a raised
  shell text size, can still wrap the hint. Point 1's second half covers
  that: cause A's fix keeps the card correct under a footer of any
  height. The razer step records the real width.
- **Merge order.** #36, #28, #27 and #26 all touch `Menu.qml` and
  `FlatsnapModel.qml`. Merge in that order: #36 first, then #28, #27,
  #26. Each later branch is rebased onto the one before it, and
  `tests/model.sh` runs again after each rebase.
- **Hosts.** Nothing runs on p620. The razer step waits until razer is
  free: it is busy with another live check. No apply is needed for this
  check. The Add, card and armed-message states need no build. The ended
  log state needs one earlier apply on razer, or it is checked headless
  only.

## Verification

- `bash tests/model.sh` (runs under `tests/isolate.sh`) prints
  `model: N passed, 0 failed`, including the new `typing`, log and budget
  checks.
- `nix flake check` passes, including `no-text-multiplier`
  (`flake.nix:112`) and `no-hardcoded-colours` (`flake.nix:101`). No new
  `pixelSize` or colour is added.
- `bash tests/cli.sh` still passes (no `bin/` change expected).
- **Razer, monitor scale 2, default text size,** after the user frees it:
  1. Every hint in the table fits on one line. That means the Add view
     with the field focused and after a search, both cards, Declared, and
     the log while running and after it ended. Screenshot each.
  2. The field-focused Add hint shows no `l`, `j k` or `a`. After
     `p`, the overrides hint is `Enter queue  Esc back`.
  3. The step above that picks the cause, then again with the fix: the
     `sockets:` line is visible under an armed message with no key
     pressed.
  4. At scale 1, the same card and the same armed message look as they do
     today, apart from the hint text.
