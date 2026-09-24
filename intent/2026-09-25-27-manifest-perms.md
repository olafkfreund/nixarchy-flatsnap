---
status: draft
issue: 27
author: olafkfreund
---

# Intent: warn when an app's own manifest escapes its sandbox

## Problem

Since #12 the panel names sandbox-escaping **overrides** with what they
grant, using the escape list the CLI writes once (`ESCAPES_JSON`,
`bin/nixarchy-flatsnap:30`) and carries on every flatpak card as
`sandboxEscapes`. The same list says nothing about what the app asks for in
its own manifest. The warning therefore depends on who asked for the escape:
a user who adds `Context.filesystems=host` is told it removes the sandbox,
while an app that ships with `filesystems=host` is not. Line numbers are for
origin/main (d3a2744).

1. **The card lists manifest permissions as plain text.** `lookup_flatpak`
   (`bin/nixarchy-flatsnap:148`) passes the Flathub summary's
   `metadata.permissions` through unchanged (`:157`). `Menu.qml:262-274`
   prints each key and its values in the ordinary text colour. Only the
   whole block turns `Color.urgent`, and only when the lookup failed
   (`permissions === null`).
2. **Real apps ask for entries on the escape list.** Live
   `GET https://flathub.org/api/v2/summary/<id>` → `.metadata.permissions`
   on 2026-09-24:
   - `com.visualstudio.code`: `"filesystems":["host"]`,
     `"sockets":[...,"ssh-auth",...]`, `"devices":["all"]`,
     `"session-bus":{"talk":["org.freedesktop.Flatpak",...]}`,
     `"system-bus":{"talk":["org.freedesktop.login1"]}`. That is five
     entries on the list, one of which runs commands on the host.
   - `org.mozilla.firefox`: `"devices":["all"]`,
     `"system-bus":{"talk":["org.freedesktop.NetworkManager"]}`.
   - `com.spotify.Client`: `"filesystems":["xdg-pictures:ro",...]`,
     `"devices":["dri"]`, `"session-bus":{"own":[...],"talk":[...]}` with no
     escaping entry.
   - `org.gnome.Calculator`: `"devices":["dri"]`, `"shared"`, `"sockets"`
     with no escaping entry.
   All four cards look equally ordinary today.
3. **The two shapes differ.** The summary's keys are bare finish-arg names
   (`filesystems`, `sockets`, `devices`, `shared`, `features`,
   `persistent`), with no `Context` section. Bus access is an object keyed by
   policy: `"session-bus":{"talk":[<names>],"own":[<names>]}`. The escape
   list is written the way overrides are: section `Session Bus Policy`, key
   = bus name, value = `talk`/`own`. The model's matcher
   (`FlatsnapModel.qml:236` `_escapes`) parses override strings only, so it
   cannot be pointed at the summary as it is.
4. **Bus policies render as raw JSON.** The card falls back to
   `JSON.stringify` for anything that is not an array (`Menu.qml:271`). So
   `session-bus` shows as `{"talk":["org.freedesktop.Flatpak",…]}`, and the
   most dangerous grant on the VS Code card is the hardest one to read.
5. **An escaping app queues on one Enter.** `queue()`
   (`FlatsnapModel.qml:199`) asks twice for store-classic snaps and for any
   override. A flatpak with no overrides queues at once, whatever its
   manifest asks for.

## Proposed outcome

- On a flatpak card, each permission from the app's own manifest that
  matches the escape list is marked in `Color.urgent` and followed by what
  it grants, in the list's own wording (`says`). Matching follows the same
  rules as overrides: equal after `:ro`/`:rw`/`:create` is dropped, and key
  `*` means any bus name.
- `session-bus` and `system-bus` entries are shown as readable
  `talk`/`own` lines, not JSON. They are checked against the
  `Session Bus Policy` and `System Bus Policy` entries.
- Entries that do not match stay in the ordinary colour, as today.
- A failed summary lookup still reads `permissions: UNKNOWN` in
  `Color.urgent`. It is never "none listed" and never "no escapes".
- The escape list stays in one place, `ESCAPES_JSON`. It is not copied into
  QML.
- Recorded fixtures cover, offline: an app with `filesystems=host`,
  `ssh-auth`, `devices=all` and `session-bus` talk to
  `org.freedesktop.Flatpak` (shaped like `com.visualstudio.code`); an app
  with a `system-bus` talk only (shaped like `org.mozilla.firefox`); an app
  with no escapes (the existing `com.spotify.Client` and
  `org.gnome.Calculator` fixtures); and a failed summary
  (`org.example.NoSummary`).

## Affected users and systems

- Anyone installing a Flatpak from the plugin. It matters most for someone
  who installs a developer tool or pastes an ID from a README without seeing
  the Flathub page.
- `bin/nixarchy-flatsnap`: `ESCAPES_JSON` and `lookup_flatpak`, if matching
  or reshaping happens in the CLI.
- `FlatsnapModel.qml`: `_escapes` and, depending on open question 1,
  `queue()`.
- `Menu.qml`: the permissions `Line` on the card (`:262-274`).
- `tests/fixtures/` (new `flathub-summary-*` / `flathub-appstream-*`
  fixtures), `tests/model.sh`, `tests/model.qml`.
- Network: none added. The summary is already fetched for every card.
- README "Overrides" section, which documents the escape list.

## Constraints

- **Store text stays plain text.** Permission names and bus names come from
  the store and are untrusted. They are rendered as plain text, never as
  markup, and never interpolated into a shell string (issue #1).
- **Unknown stays unknown.** A failed or missing summary is `null` all the
  way through and reads UNKNOWN. It must never read as "none listed" or
  "no escapes". A card without `sandboxEscapes` (an older CLI) must warn
  more, never less. This is the same rule `_escapes` already applies to
  overrides.
- **Offline tests.** Every new response shape is a recorded fixture under
  `tests/fixtures/`, served through `NIXARCHY_FLATSNAP_OFFLINE`. The tests do
  not touch the network.
- **Fonts are bare `Style.font` tokens** (`Style.font.title`,
  `Style.font.heading`, `Style.font.family`), with no arithmetic or literal
  sizes. Colours come from `Color.*` tokens.
- **Keyboard only.** Any new confirmation is a key press in the existing
  arm/confirm pattern (`queueArmed`, `disarm()`), with no dialog.
- No change to what is installed or how. Overrides and the apply path are
  unchanged.

## Open questions

1. Is a highlight enough, or should an app whose own manifest escapes its
   sandbox also need a second Enter to queue, as a store-classic snap does?
   *Recommendation:* highlight only, at least at first. On the live data,
   anything that talks to a system bus name matches
   `System Bus Policy.*=talk`, which includes Firefox
   (`org.freedesktop.NetworkManager`). A second Enter would then fire on
   many common apps and train people to press twice without reading, the
   same concern that led #12 to label unverified publishers rather than
   gate them. A narrower gate could come later, limited to host
   filesystem, `session-bus` or `org.freedesktop.Flatpak` talk (which can
   run host commands), with no overrides involved. If the gate is wanted,
   it should be that narrow set and not the whole list.
2. Should manifest permissions use the same list as overrides, or a list of
   their own?
   *Recommendation:* the same list (`ESCAPES_JSON`), so there is one place
   to change it and the card and the override prompt never disagree. The
   one entry that behaves differently is `System Bus Policy` `*`, which is
   broad for manifests (see question 1). If the approver finds that too
   noisy, the fix is to narrow that entry for both uses, not to fork the
   list.
