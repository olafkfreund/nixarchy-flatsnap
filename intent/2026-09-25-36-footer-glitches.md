---
status: draft
issue: 36
author: olafkfreund
---

# Intent: the panel footer fits, offers only keys that work, and tells the truth about the build

## Problem

The razer live check for #23 (`plan/2026-09-24-23-detach-apply.md`, "Live
check on razer") found three problems with the footer. All three are
cosmetic, and they date from #15, not #23. The footer is a `Column` at the
bottom of the panel (`Menu.qml:387-402`). It holds the message line
(`:391-396`, red while a confirmation is armed) and the key help line
(`:397-401`, `fs.keysHint`). The card, the list and the log all end at
`footer.top` (`Menu.qml:232`, `:327`, `:371`).

1. **At scale 2 the footer wraps, and an armed message covers the card's
   last line.** At monitor scale 2 on razer (960x540 logical), the key help
   line wraps onto a second line. The card's hint is the longest one, for
   example `j k PgUp PgDn scroll   p overrides   Enter queue   a apply   l log   Esc back`
   (`FlatsnapModel.qml:47-54`), and `Line` wraps (`Menu.qml:80`). With
   `com.spotify.Client` open and an override armed, the red confirmation
   appears, and the card's last line (`sockets:`) ends up under it. Each
   footer line is height the card no longer has. How the last line ends up
   under the message has not been checked. The card's bottom follows
   `footer.top`, so it should shrink rather than be overlapped. Possible
   causes:
   - the card keeps its `contentY` when it gets shorter. The clamp in
     `scrollBy` (`Menu.qml:58-60`) runs only on a key press.
   - the `↓ more (j)` marker (`Menu.qml:89-98`) sits over the card's
     bottom edge.

2. **The Add view offers `l log` while the text field has the keyboard.**
   On a normal open the app ID field gets the keyboard (`Menu.qml:36`), and
   Esc from a card gives it back (`:172`). While a field has the keyboard,
   single letters are typed into it and are not commands (`Menu.qml:193-195`).
   The Add hint still lists `l log` once there is a log
   (`FlatsnapModel.qml:53`), so pressing `l` types an `l`. The same hint
   also lists `j k move` and `a apply` (`:50`), which have the same
   problem. On a card, while the overrides field has the keyboard, the
   hint lists `j k`, `p` and `a` in the same way (`:52`). `keysHint` is
   worked out from `view` (`:46`) alone. It does not know whether a field
   has the keyboard. Only `Menu.qml` knows that (`typing`, `:138`).

3. **The log footer still says the build carries on after it has ended.**
   The log hint is fixed text: `Esc stops watching (the build carries on)`
   (`FlatsnapModel.qml:48`). It does not depend on `applying`
   (`FlatsnapModel.qml:37`). When the apply has ended, `applying` is false
   and Esc just goes back (`Menu.qml:143`), but the footer still says
   something is carrying on. The first line of the log also says "ESC
   stops watching; the build carries on" (`FlatsnapModel.qml:333`). That
   line is history, true when it was written, and is not part of this bug.

## Proposed outcome

- At monitor scale 2 on a 1080p monitor, the key help line of every view
  (Add, card for flatpak and snap, Declared, log) fits on one line, or, if
  it wraps, no card content is hidden behind it.
- When a confirmation is armed, the card's last line can still be read,
  scrolling with the keyboard if needed. With `com.spotify.Client` and an
  override armed, the `sockets:` line is visible.
- The footer lists only keys that do something in the current state. While
  a text field has the keyboard, it lists no single-letter command that
  would be typed instead of run.
- While a build runs, the log footer says Esc leaves it running. After the
  build has ended, it says Esc goes back.
- At scale 1 on 1080p, nothing changes apart from the wording above.

## Affected users and systems

- Everyone using the flatsnap menu. Item 1 affects small logical screens:
  scale 2 on 1080p, fractional laptop scales, a raised shell text size.
- `FlatsnapModel.qml` (`keysHint`, `view`) and `Menu.qml` (footer, message
  line, card, focus).
- The README key list, only if the wording of the keys changes.

## Constraints

- Font sizes are bare `Style.font.*` tokens, with no multiplier or
  arithmetic. The `no-text-multiplier` flake check (`flake.nix:112`)
  enforces this and must keep passing.
- Colours come from `Color.*` tokens. The `no-hardcoded-colours` check
  (`flake.nix:101`) enforces this, and the armed message stays
  `Color.urgent`.
- Keyboard only. No fix may need a mouse. Single letters keep their
  meaning and never fire while a field has the keyboard.
- Trust information (verification, permissions, classic and confinement
  warnings) and the armed confirmation text are never hidden or cut short
  to save space. They may only move.
- Esc on the log still never stops a running build (#23).
- Tested on razer only, at monitor scale 1 and 2, never on p620.

## Open questions

1. **Short hint, or a hint that may wrap?** Make every view's hint short
   enough for one line at scale 2 (fewer words, or leave out keys the user
   already knows, such as `j k`), or let it wrap and make sure the card
   gives up the space cleanly?
2. **While a field has the keyboard: hide the letters from the hint, or
   make them work?** The issue allows either for `l`. Making letters work
   in a field would break typing an app ID with an `l` in it, so the
   choice is really "hide them", and the question is which hint the field
   shows (for example `Enter look up   Ctrl+F Flathub   Ctrl+S Snap   Tab Declared   Esc back`).
3. **Must the footer know about focus?** Today the hint is model state
   (`view`), and focus is known only in `Menu.qml`. Should the model be
   told when a field has the keyboard, or should `Menu.qml` build the
   hint?
4. **The armed message over the card.** The cause is not confirmed.
   Reproduce it on razer first (`contentY` not re-clamped when the card
   gets shorter, or the more marker), then fix that cause. Or should an
   arming key also scroll the card so its last line stays in view?
5. **Log wording after the build.** Just `Esc back`, or say how it ended,
   for example `build ended   Esc back`? The end is already the log's
   last line (`FlatsnapModel.qml:341`).
