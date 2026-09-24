---
status: draft
issue: 27
intent: intent/2026-09-25-27-manifest-perms.md
---

# Spec: warn when an app's own manifest escapes its sandbox

## Decisions carried from the intent

| # | Question | Decision |
|---|---|---|
| Q1 | Highlight only, or also a second Enter? | Highlight only. An app whose manifest escapes queues on one Enter, as today |
| Q2 | Same list as overrides, or a manifest list? | The same list, `ESCAPES_JSON`. If `System Bus Policy *` is too noisy, narrow it for both uses (see D4: not narrowed now) |

Also approved with the intent:
- Bus permissions are shown as readable `talk`/`own` lines, not raw JSON.
- A failed summary lookup still reads `permissions: UNKNOWN` in
  `Color.urgent`, and never "none listed" or "no escapes".

Line numbers are for origin/main (d3a2744).

## Design

### D1: The CLI flags the manifest's escapes (`bin/nixarchy-flatsnap`)

`lookup_flatpak` (`:148-159`) already has the summary (`$s`) and the list
(`$esc`) in the same `jq` call. It adds one field to the card:

`manifestEscapes`: `null` when `permissions` is `null` (a failed summary).
Otherwise it is an array, possibly empty, of `{entry, says}`, one per
manifest permission that matches the list, in manifest order.

The matching happens in a jq function next to `FH_VERIFY_JQ`
(`MANIFEST_ESCAPES_JQ`). It first flattens the summary permissions into the
list's `{section, key, value}` shape:

| Summary shape | Becomes | `entry` text shown |
|---|---|---|
| `"<k>": ["v", ...]` (e.g. `filesystems`, `sockets`, `devices`) | `Context` / `<k>` / `v`, one per value | `<k>=<v>`, e.g. `filesystems=host` |
| `"session-bus": {"talk": [n...], "own": [n...]}` | `Session Bus Policy` / `n` / `talk` or `own` | `session-bus talk <n>` |
| `"system-bus": {...}` | `System Bus Policy` / `n` / `talk` or `own` | `system-bus talk <n>` |
| anything else (not an array of strings, or not an object of arrays) | skipped | none |

It then matches each entry by the rule `_escapes` uses for overrides
(`FlatsnapModel.qml:236-248`): the value, with a trailing
`:ro`/`:rw`/`:create` dropped, is in `values`; the section is equal; and the
list key is `*` or equal to the entry key. There is one addition for
manifests. A bus name ending in `.*` (Flathub has
`"org.mozilla.firefox.*"`) also matches a list key that starts with its
prefix, so `talk org.freedesktop.*` is flagged as
`org.freedesktop.Flatpak`. A wildcard warns more, never less.

`says` is copied from the matching list entry. When one value matches two
entries, the first wins. The list has no overlaps today.

Why in the CLI:
- The list and the summary are both already there.
- `tests/cli.sh` can test it offline against real recorded responses, which
  it cannot do for QML.
- QML never has to parse the summary shape.

`permissions` is left as it is (raw object or `null`), so nothing that reads
it changes.

### D2: The card shows the escapes (`Menu.qml:262-274`)

Between the licence line and the permissions line, one new `Line`, visible
only for a flatpak:

- `manifestEscapes` is a non-empty array: in `Color.urgent`, the text is
  `escapes its sandbox` followed by one indented line per match,
  `<entry>: <says>`. For example:
  `filesystems=host: the host filesystem`,
  `session-bus talk org.freedesktop.Flatpak: running commands outside the sandbox`.
- `manifestEscapes` is `[]`: hidden. The permissions line below already
  lists everything.
- `manifestEscapes` is `null` (failed lookup): hidden. The UNKNOWN
  permissions line already says it, in `Color.urgent`.
- `manifestEscapes` is `undefined` while `permissions` is an object (a CLI
  older than the QML): in `Color.urgent`,
  `sandbox escapes: not checked (no list from nixarchy-flatsnap)`. This
  mirrors `_escapes`, so losing the field warns more, never less.

The escaping entries still appear in the full permissions list below in the
ordinary colour. The urgent block is the highlight, and the list stays
complete and in store order.

`Line` is `textFormat: Text.PlainText` (`Menu.qml:78-79`), so bus names and
paths from the store cannot be read as markup. Font sizes are the `Line`
default and bare `Style.font` tokens, and the colours are `Color.urgent` and
`Color.menu.text`.

### D3: Readable bus lines (`FlatsnapModel.qml`, `Menu.qml`)

Today the permissions text is built inline in `Menu.qml:268-273`, which
falls back to `JSON.stringify` for objects. It moves into a pure function on
the model, `permissionText(p)`, so `tests/model.qml` can test it. `Menu.qml`
binds `fs.permissionText(cardCol.c.permissions)`.

- `null`: `permissions: UNKNOWN (the Flathub lookup failed)`. The colour
  test stays in Menu.
- `{}`: `permissions: none listed`.
- An array value: `<k>: a, b, c`, as today.
- An object of arrays (`session-bus`, `system-bus`): one line per policy,
  `<k> talk: n1, n2` and `<k> own: n3`.
- Anything else: `<k>: ` + `JSON.stringify(v)`, as today. This is a
  fallback for shapes not seen yet, and is still plain text.

### D4: `System Bus Policy *` is not narrowed now

Live `GET /api/v2/summary/<id>` on 2026-09-24, for 19 popular apps. Every
app that talks to any system bus name is already flagged by another entry:

| App | `system-bus` talk | Also flagged by |
|---|---|---|
| `org.mozilla.firefox` | `org.freedesktop.NetworkManager` | `devices=all` |
| `com.visualstudio.code` | `org.freedesktop.login1` | `host`, `ssh-auth`, `devices=all`, `session-bus talk org.freedesktop.Flatpak` |
| `org.telegram.desktop` | `org.bluez` | `devices=all` |
| `com.valvesoftware.Steam` | `org.freedesktop.UPower`, `org.freedesktop.UDisks2` | `devices=all` |
| `org.signal.Signal` | `org.freedesktop.login1` | `devices=all` |
| `org.kde.kdenlive` | `org.freedesktop.UDisks2` | `host`, `devices=all` |
| `com.brave.Browser`, `org.chromium.Chromium` | `Avahi`, `UPower`, `bluez` | `host-etc` / `home`, `devices=all` |

Narrowing the entry would therefore change no app from "no highlight" to
"highlight" in this sample. It would only shorten the list inside the
block. It would also weaken the override prompt, which #12 approved as it
is. The noise that matters comes from `devices=all` (12 of 19) and
`filesystems=host` (9 of 19), and those are real grants. The entry stays.
Showing the specific bus name (`system-bus talk org.bluez: talking to
system services`) lets the reader judge each one. If it is narrowed later,
it is narrowed in `ESCAPES_JSON` for both uses.

The same sample shows the highlight will appear on most popular apps: 17 of
19. Only `org.gnome.Calculator` and `com.spotify.Client` had none. That is
an accurate picture of Flathub, and it is why Q1 chose a highlight over a
gate.

### D5: README (`README.md`, "Overrides that escape the sandbox")

Add one paragraph: the same list marks the app's own permissions on the card
in red, without a second Enter; bus policies are shown as `talk`/`own`; and
a wildcard name such as `org.freedesktop.*` counts as every name under it.

## Alternatives rejected

- **Match in QML** (a second `_escapes` for the summary shape). The panel
  would parse the store's shape, and the result could not be tested in
  `tests/cli.sh` against recorded responses. The CLI has both inputs
  already.
- **Colour the entries inside the permissions list** (one `Line` per entry,
  urgent or not). This needs a `Repeater`, per-value splitting of grouped
  lines (`sockets: x11, wayland, ssh-auth`), and a much longer card
  (Firefox has 21 entries). A separate block says the same thing with one
  `Line`.
- **Rewrite `permissions` into flattened entries in the CLI.** That breaks
  the object shape `tests/cli.sh`, `tests/model.qml` and `_showCard`'s
  `permissions !== undefined` test rely on. Adding a field is backwards
  compatible.
- **Move the override matcher to the CLI too, so there is one matcher.**
  Overrides are typed into the panel after the lookup. Matching them in the
  CLI would need a new call per keystroke or at queue time. That is out of
  scope; see Risks.
- **Narrow `System Bus Policy *` now.** See D4: it changes no highlight in
  the sample, and it weakens the approved override warning.
- **A second Enter.** Decided against in Q1.

## Risks

- **Two matchers.** Overrides are matched in QML (`_escapes`) and manifests
  in jq (D1). If they drift, the card and the override prompt disagree.
  Mitigation: both carry a comment naming the other, and `tests/cli.sh` and
  `tests/model.qml` check the same value set: each list value, with and
  without `:ro`, plus a non-match such as `~/Games`.
- **Unexpected summary shapes.** A key whose value is not an array of
  strings or an object of arrays is skipped by D1 and printed through the
  `JSON.stringify` fallback by D3. It is never flagged, but it is always
  shown. A Flathub schema change could therefore hide an escape until the
  shape is added. The "not checked" line only covers a missing field, not
  an unknown shape.
- **Highlight fatigue.** 17 of 19 sampled apps show the block. This is
  accepted by Q1. The block names each grant, so it is still information
  and not only a colour.
- **Merge order: #36 → #28 → #27 → #26. This lands third.**
  - #36 (panel footers) touches `Menu.qml`. Rebase on it, and re-check the
    card block's placement and wrapping at scale 2.
  - #28 (Bus Policy overrides cannot be typed because the field splits on
    spaces) may change how `Session Bus Policy` / `System Bus Policy`
    overrides reach `_escapes`. Rebase on it, and re-run the shared
    matcher cases in `tests/model.qml` so that both matchers still agree on
    bus sections.
  - #26 (accessibility) lands after this one and will give the new `Line`
    an `Accessible.name`. Nothing here should block that: the escape block
    is plain text in a `Line`, like its neighbours.
- **Hosts.** This is display only. Nothing is installed differently. No
  apply, preflight or rebuild on p620. Any live check of the card is on
  razer.

## Verification

- **New fixtures**, recorded from the live API and trimmed to the fields the
  CLI reads (as the existing ones are). Values are copied verbatim.
  - `tests/fixtures/flathub-summary-com.visualstudio.code.json` and
    `flathub-appstream-com.visualstudio.code.json`: the real
    `metadata.permissions` above, including `"filesystems":["host"]`,
    `"ssh-auth"`, `"devices":["all"]`,
    `"session-bus":{"talk":["org.freedesktop.Flatpak",...]}` and
    `"system-bus":{"talk":["org.freedesktop.login1"]}`.
  - `tests/fixtures/flathub-summary-org.mozilla.firefox.json` and
    `flathub-appstream-org.mozilla.firefox.json`: `"devices":["all"]`,
    `"system-bus":{"talk":["org.freedesktop.NetworkManager"]}`,
    `session-bus` `own` wildcards such as `"org.mozilla.firefox.*"`, and
    `"filesystems":["xdg-config/gtk-3.0:ro", ...]` (not flagged).
- **`bash tests/cli.sh`** (offline):
  - VS Code: `manifestEscapes` has exactly `filesystems=host`,
    `sockets=ssh-auth`, `devices=all`,
    `session-bus talk org.freedesktop.Flatpak` and
    `system-bus talk org.freedesktop.login1`, each with a non-empty `says`.
  - Firefox: `devices=all` and
    `system-bus talk org.freedesktop.NetworkManager`. The `own`
    `org.mozilla.firefox.*` wildcard is not flagged, and neither is
    `xdg-config/gtk-3.0:ro`.
  - `org.gnome.Calculator` and `com.spotify.Client` give `[]`.
  - `org.example.NoSummary` gives `permissions == null` and
    `manifestEscapes == null`.
  - An inline shape case gives `host:ro` flagged,
    `session-bus talk org.freedesktop.*` flagged, and `!host` and `~/Games`
    not flagged.
- **`bash tests/model.sh`** (`tests/model.qml`): `permissionText` returns
  UNKNOWN for `null`, `none listed` for `{}`, `session-bus talk: …` /
  `own: …` lines for bus objects, and never the substring `{"`. The existing
  `_escapes` cases still pass.
- **`nix flake check -L`**: shellcheck, cli, manifest and
  no-hardcoded-colours are green. `no-text-multiplier` (#21) passes, since
  no font size arithmetic is added.
- **Live, on razer only**: open the VS Code and Calculator cards. VS Code
  shows the red block with five lines. Calculator shows none. Both render
  bus permissions as `talk`/`own` lines at scale 1 and 2.
