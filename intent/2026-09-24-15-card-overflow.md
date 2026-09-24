---
status: approved
issue: 15
author: olafkfreund
---

# Intent: the menu's card fits, or scrolls, at every desktop scale

## Problem

The user's requirement is that "the text and the windows need to follow the
desktop size and scale". Since #9 (PR #14) both do: the window takes its
size from the monitor (`Menu.qml:70-71`: `min(Style.space(1000), 70% of the
monitor)` wide, 78% of the monitor high), and the text takes its size from
the shell's `Style.font` tokens (`Menu.qml:50`, `:190`). What does not follow
is the amount of content. It stays the same at every size, so at a small
logical size it no longer fits the window.

Found on razer (eDP-1, 1920x1080) at monitor scale 2, which is 960x540
logical pixels. For an app with a long permission list
(`com.spotify.Client`), the Add card's content is taller than the card. The
overrides row and the closing "Enter queues it. Nothing is installed until
a applies." line fall below the card's bottom edge (screenshots in #15,
from branch `pr-assets/9`). The old fixed 1.45 text hit this sooner, so the
problem predates #9. #9 did not cause it and did not fix it.

The card is a `Flickable` with `clip: true` (`Menu.qml:176-181`), so the
content is there, but the menu is keyboard only and no key reaches it:

- Nothing changes the card's `contentY`. `j`/`k` and Up/Down call
  `fs.moveCursor` (`Menu.qml:136-137`, `:144-145`), which moves the cursor of
  the hidden list behind the card, not the card.
- `p` gives the keyboard to the overrides field (`Menu.qml:149`), but the
  card does not scroll to show it. At scale 2 the user types into a field
  that is below the edge.
- The mouse wheel or a drag would scroll it, but the menu is keyboard only
  by design and the card's `MouseArea` (`Menu.qml:79`) is there only to stop
  clicks closing the menu.

Two things make the space smaller still at small sizes:

- The footer help line (`Menu.qml:322-327`) is one long string that wraps
  onto several lines in a narrow window. The card ends at `footer.top`
  (`Menu.qml:179`), so each extra footer line is taken from the card.
- A flatpak's permission list is one `Line` per permission group
  (`Menu.qml:207-218`), so its height depends on the app, not the window.

The other two views are clipped the same way: the result and Declared list
(`ListView`, `Menu.qml:258-299`) and the build log (`Flickable`,
`Menu.qml:302-310`). The list is bound to `fs.cursor` through
`currentIndex`, and the log jumps to its end whenever it grows
(`Menu.qml:308`). Whether either one hides content from the keyboard at
scale 2 has not been checked on razer.

## Proposed outcome

- At any monitor scale and any shell text size, every line of the Add card
  can be read using the keyboard alone, including the overrides field and
  the closing line, for the longest permission lists seen on Flathub.
- When `p` gives the keyboard to the overrides field, the field is on
  screen.
- At scale 1 on a 1080p monitor, where it fits today, the card looks and
  works as it does now.
- The key map stays unambiguous: no new key collides with a single-letter
  command or with typing in a field.

## Affected users and systems

- Everyone using the flatsnap menu on a small logical screen: monitor scale
  2 on 1080p, fractional scales on laptops, or a raised shell text size
  (`omarchy display text size`).
- `Menu.qml` in this repo. `FlatsnapModel.qml` only if the fix needs model
  state (it has none for scrolling today).
- The footer help text and the README key list, if keys are added.
- The sibling plugins (`nixarchy-pkg`, `nixarchy-devenv`,
  `nixarchy-distrobox`, `nixarchy-plugin-browser`) have similar menus and
  may have the same problem. Not in scope here. A follow-up issue if the
  answer is yes.

## Constraints

- The UI stays keyboard only. The fix must not need a mouse or a touchpad.
- Single letters are commands (`j k c x p d y a l /`) and must keep their
  meaning. Nothing new may fire while a text field has the keyboard.
- Font sizes stay `Style.font.*` tokens with no multiplier or scale factor
  on top. The `no-text-multiplier` flake check (`flake.nix:111-119`)
  enforces this and must keep passing.
- Colours come from `Color.*` tokens (`no-hardcoded-colours`,
  `flake.nix:101-107`).
- Window size keeps coming from the monitor and `Style.space`, as today.
- Trust information on the card (publisher verification, permissions,
  classic and confinement warnings) is never hidden or cut short to save
  space. It may only move.
- Tested on razer only, at monitor scale 1 and 2, never on p620.

## Open questions

1. **Scroll, compact, or both?** Make the card scrollable by keyboard (and
   keep the focused field in view), or make the layout more compact at
   small logical sizes (for example a shorter footer, or permissions in
   fewer lines), or both? Compacting alone cannot cover every permission
   list, so it can only be an addition to scrolling.
2. **Which keys scroll the card?** Single letters are commands, so the
   choices are keys that are not letters: PgUp/PgDn, Ctrl+D/Ctrl+U (vim
   style, next to `j`/`k`), or Up/Down and `j`/`k` scrolling the card when
   a card is shown, since today they move a hidden list. Which one, and
   should Home/End go to the top and bottom?
3. **Same for the list and the log?** Should the Declared and result list
   and the build log get the same scroll keys, so they work the same
   everywhere? The log in particular jumps to its end on every new line,
   so the user cannot read back through a failed build by keyboard.
4. **The footer.** At small sizes the help line wraps onto several lines
   and takes height from the card. Shorten it, show only the keys that
   apply to the current view, or leave it alone?
