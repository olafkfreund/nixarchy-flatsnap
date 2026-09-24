---
status: approved
issue: 15
intent: intent/2026-09-24-15-card-overflow.md
---

# Spec: the menu's card fits, or scrolls, at every desktop scale

## Design

**Decided at intent approval:**

1. Scroll the card, and keep the focused field in view. Compact only the
   footer. Nothing else in the layout changes.
2. With a card shown, `j`/`k` and Up/Down scroll the card (today they move
   the hidden list). PgUp/PgDn jump a page. No Ctrl+D/U, no Home/End.
3. The build log gets the same scroll keys, and stops jumping to its end
   while the user has scrolled up. The result and Declared list is
   checked on razer at scale 2 first. It gets a fix only if it does not
   already follow `currentIndex`.
4. The footer shows only the keys for the current view.

Trust information (publisher verification, permissions, the classic and
confinement warnings) is never hidden or shortened. It only scrolls.

### Which view has the keys

There are four views, and they are already mutually exclusive in
`Menu.qml`:

| View | Shown when | Visible item |
| ---- | ---------- | ------------ |
| log | `fs.showingLog` | `logView` (`Menu.qml:302-310`) |
| card | `fs.tab === 0 && fs.card && !fs.showingLog` | `cardView` (`:176-255`) |
| Add list | tab 0, no card | `list` (`:258-299`) |
| Declared | tab 1 | `list` |

The model knows all of this (`tab`, `card`, `showingLog`), so the model
names the view: a new `readonly property string view` in
`FlatsnapModel.qml`, next to `rows`/`current` (`FlatsnapModel.qml:41-42`),
with the values `"log"`, `"card"`, `"add"` and `"declared"`. `Menu.qml`
reads it for keys and the footer, and `tests/model.qml` can test it
without a window.

### Scrolling (`Menu.qml`)

One helper in `root`, used by both scrollable views:

```qml
// Flickable has no key scrolling of its own; this is it, clamped to the content.
function scrollBy(view, dy) {
  view.contentY = Math.max(0, Math.min(view.contentHeight - view.height, view.contentY + dy))
}
```

The step sizes come from the text, so they follow the shell's text size
the same way the text does:

- **One line** (`j`/`k`, Up/Down) is the height of one line of `Line` text.
  That comes from a `FontMetrics { font.family: Style.font.family;
  font.pixelSize: Style.font.title }` in `root`. `lineSpacing` is the
  step. The `pixelSize:` is a bare `Style.font` token, so the
  `no-text-multiplier` check (`flake.nix:111-119`) still passes.
- **One page** (PgUp/PgDn) is the view's height minus one line, so the
  last line of the old page stays in sight as the first of the new one.

**Key routing,** in `Keys.onPressed` (`Menu.qml:90-157`):

- **Log** (the `fs.showingLog` block, `:96-101`). Before its `return`,
  bare `j`/`k`, Up/Down and PgUp/PgDn call `scrollBy(logView, …)` and are
  accepted. Esc stays as it is. Every other key is still ignored while the
  log shows, as today.
- **Card.** In the main `switch` (`:116-138`), Up/Down and PgUp/PgDn
  check `fs.view === "card"` first. If a card is shown, they scroll
  `cardView`. If a field has the keyboard (`typing`), they also hand the
  keyboard back to the card with `root.focusKeys()`, as Down already does
  (`:136`). So no field is ever left with the keyboard while it is
  scrolled off screen. In the single-letter `switch` (`:143-155`), `j`/`k`
  scroll the card when `fs.view === "card"`, and move the cursor
  otherwise. Letters still do nothing while a field has the keyboard
  (`:142`), so `j`/`k` can still be typed into the overrides field.
- **List views.** No change to the keys: they still call
  `fs.moveCursor`.

**Keep the focused field in view.** `ovField` (`:223-231`) is the only
field inside the card. The app ID field (`:159-165`) sits above the
views and does not scroll. When `ovField` gets the keyboard
(`onActiveFocusChanged`, `p` at `:149`), the card scrolls just enough to
show its row. The row's position in the card comes from
`ovField.mapToItem(cardCol, 0, 0).y`. If the row is below the bottom
edge, `contentY` becomes `rowBottom - cardView.height`. If it is above the
top edge, `contentY` becomes `rowTop`.

**A new card starts at the top.** `cardView` is one `Flickable` reused for
every card, so its `contentY` would carry over from the last app. On
`fs.card` changing, `cardView.contentY = 0`.

**"More below" marker.** A card that starts at the top can hide the Snap
warnings (`:241-252`) or the overrides row below the edge. A line of text
at the bottom of the card area says so, so the user knows there is more:

```qml
Line {  // bottom of cardView, over the content
  visible: cardView.visible && cardView.contentY < cardView.contentHeight - cardView.height - 1
  text: "↓ more (j)"; opacity: 0.7
}
```

The colour comes from `Line` (`Color.menu.text`, `:51`). A matching marker
goes on `logView` while the user has scrolled up: "↓ more (j)".

### The log stops jumping while scrolled up

Today `onContentHeightChanged: contentY = Math.max(0, contentHeight -
height)` (`:308`) pins the log to its end on every new line. Instead:

- `logView` gets `property bool follow: true`.
- `onContentHeightChanged` moves to the end only if `follow` is true.
- After a scroll key, `follow` becomes `logView.contentY >=
  logView.contentHeight - logView.height - 1`. Scrolling up turns it off.
  Scrolling back to the bottom turns it on again.
- Whenever the log is shown (`fs.showingLog` turning true: after `l`,
  reopening the panel during a build, or `a a` starting one), `follow`
  becomes true and the log jumps to its end, as today.

### The list

`list` binds `currentIndex: fs.cursor` (`:264`). A `ListView` keeps its
current item in view by default (`highlightFollowsCurrentItem` defaults
to true). If razer at scale 2 shows that it does, nothing changes. If it
does not, the fix is one line on `list`:
`onCurrentIndexChanged: positionViewAtIndex(currentIndex, ListView.Contain)`.
The PR states which case it was.

### The footer (`Menu.qml:322-327`)

The help line becomes a function of `fs.view`, and only lists keys that do
something there. It is kept in the model as
`readonly property string keysHint` next to `view`, so `tests/model.qml`
checks it:

| `view` | Footer text |
| ------ | ----------- |
| `log` | `j k PgUp PgDn scroll   Esc stops watching (the build carries on)` |
| `card`, Flatpak | `j k PgUp PgDn scroll   p overrides   Enter queue   a apply   Esc back` |
| `card`, Snap | `j k PgUp PgDn scroll   c channel   x classic   Enter queue   a apply   Esc back` |
| `add` | `Enter look up / open   Ctrl+F Flathub   Ctrl+S Snap   j k move   Tab Declared   a apply   Esc back` |
| `declared` | `j k move   d remove   a apply   Tab Add   Esc back` |

Each one also gets `   l log` before `Esc` when `fs.applyLog.length > 0`,
because `showLog` does nothing otherwise (`FlatsnapModel.qml:52`). `/` is
left out of the footer, as today, but it is still in the README. The
footer `Line` still wraps if a very narrow window needs it, but it wraps
into fewer lines than today's 19-key line.

### README

The Keys table (`README.md:46-62`): the `j` `k` / `↓` `↑` row becomes
"move; on a card or the build log, scroll". A new row: `PgUp` `PgDn`,
"scroll a card or the build log a page". The `l` row adds "scroll up to
read back; it stops following the build until you scroll back down".

### Not changed

Window and card geometry (`Menu.qml:70-73`), every `pixelSize`, colours,
the confirmation rules, the card's content and order, `bin/`, the NixOS
module.

## Alternatives rejected

- **Compact the card at small sizes** (smaller gaps, permissions on fewer
  lines, a smaller token below a width). A long permission list still
  overflows, so scrolling would be needed anyway. It would also change the
  layout at the default size, which the intent ruled out. The footer is
  the only thing compacted.
- **Ctrl+D/Ctrl+U, Home/End.** Ruled out at intent approval. PgUp/PgDn
  already cover big jumps, and every added key has to be learnt.
- **New scroll-only keys, with `j`/`k` still moving the list on a card.**
  With a card shown the list is hidden, so `j`/`k` do nothing the user can
  see. Reusing them costs no new key.
- **Qt's `ScrollBar`/`ScrollIndicator`** (`QtQuick.Controls`). It shows
  where you are, but it does not scroll by keyboard on a `Flickable`. It
  would add a Controls import and a style that `Color.*` does not reach.
  The text marker does the needed job.
- **Scroll the card to keep the focused field in view with
  `Flickable.contentItem` tricks or a `ListView` for the card.** Moving the
  card to a `ListView` of rows is a rewrite for one field. The
  `mapToItem` check is a few lines.
- **Put `scrollBy` in the model.** It takes the view's geometry, which the
  model has no business knowing. It is a one-line clamp, and razer checks
  it. The model gets what can be tested headless: `view` and `keysHint`.

## Risks

- **Keys the field takes first.** The keys reach `Keys.onPressed` on the
  `FocusScope` only if the focused `TextField` does not accept them. Down
  already gets through today (`:136`). PgUp/PgDn in a single-line
  `TextInput` are expected to get through too. Checked on razer with the
  overrides field focused. If they do not, the fallback is
  `Keys.onPressed` on `ovField` passing them on.
- **Warnings below the edge.** A Snap's confinement warning can start
  below the edge at scale 2. The "↓ more (j)" marker says so. Queuing a
  classic snap still needs two `Enter` presses, with the reason shown in
  the footer message (`FlatsnapModel.qml` `queue()`), which does not
  scroll. So the warning is never skipped silently.
- **`j`/`k` change meaning on a card.** Anyone used to `j` on a card doing
  nothing sees it scroll instead. Low risk: before, it moved a list they
  could not see.
- **The log keeps following after the user scrolls up.** This happens if
  `follow` is not updated on every scroll key. Checked on razer only if a
  build is running there anyway (see Verification).
- **`FontMetrics.lineSpacing` versus the `Line` height.** A small mismatch
  only makes a step a little short or long. It never breaks the clamp.
- **Hosts.** Visual checks are on razer only. It is shared with other
  agents: claim it on the bus first.

## Verification

1. **Model tests.** New cases in `tests/model.qml`:
   - `fs.view` is `"add"` after `reset()`, `"card"` after `_showCard(...)`,
     `"declared"` after `setTab(1)`, and `"log"` with `showingLog` true,
     even with a card shown.
   - `fs.keysHint` for a Flatpak card has `p overrides` and no `c channel`.
     A Snap card has `c channel` and `x classic` and no `p`. Declared has
     `d remove`. The log hint has `Esc stops watching`. `l log` shows only
     when `applyLog` is not empty.

   Run `bash tests/model.sh`, which sources `tests/isolate.sh` and aborts
   unless `nixarchy-apply` is the stub. Expect
   `model: N passed, 0 failed`. Never run the model test outside that
   wrapper.
2. **`nix flake check -L`** passes, including `no-text-multiplier` (the
   new `FontMetrics` `pixelSize` is a bare token) and
   `no-hardcoded-colours`.
3. **QML load.** `Menu.qml` loads on the installed plugin layout with no
   `ReferenceError` (as #9 checked it).
4. **razer, by hand.** Claim razer on the agent bus right before and post
   when done. Dev install: stage the plugin in
   `~/.config/omarchy/.nixarchy-flatsnap-staging`, then one `mv` into
   `plugins/`. Restart the shell so the new `Menu.qml` loads. Set the
   scale with Hyprland 0.56's
   `hyprctl eval 'hl.monitor({ output = "eDP-1", mode = "1920x1080", position = "0x0", scale = 2 })'`
   and then again with `scale = 1`:
   - Scale 2, `com.spotify.Client`: the card opens at the top with
     "↓ more (j)". `j` and Down step one line, and PgDn one page, down to
     the closing line. `k`/Up/PgUp go back. The marker goes at the bottom.
   - Scale 2, `p`: the overrides field scrolls into view with the
     keyboard in it. Typing `j` there types a `j`. Down leaves the field
     and scrolls.
   - Scale 2, a classic snap (e.g. `code`): the warnings can be reached,
     and the footer shows the Snap hint.
   - Scale 2, Ctrl+F with a common word (many hits): `j` past the last
     visible row keeps the cursor row on screen. This decides whether the
     list needs the fix above.
   - Log: the live shell's model runs the real `nixarchy-apply`, so the
     agent does not start a build. This check runs only when a build is
     running or finished on razer anyway: the user presses `a a`, or it
     happens during another task's apply. Then `l`. `k` scrolls up, and new
     lines do not pull it back down. `j` to the end follows again.
     Otherwise the PR says that the log keys were checked only by the QML
     load and by review.
   - Scale 1: the card and footer look as before, apart from the shorter
     footer. No marker when everything fits.
   - Screenshots at both scales go to the PR (`pr-assets/15`).
   - Put the scale back to razer's original setting and post on the bus.
