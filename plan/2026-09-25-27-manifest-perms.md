---
status: draft
issue: 27
spec: spec/2026-09-25-27-manifest-perms.md
---

# Plan: warn when an app's own manifest escapes its sandbox

## Approved decisions (self-contained)

**Problem (intent).** Since #12 the panel names sandbox-escaping overrides
with what they grant, using `ESCAPES_JSON` (`bin/nixarchy-flatsnap:30`),
which every flatpak card carries as `sandboxEscapes`. The app's own
manifest, `metadata.permissions` from `GET /api/v2/summary/<id>`, is listed
on the card as plain text. `com.visualstudio.code` asks for
`"filesystems":["host"]`, `ssh-auth`, `"devices":["all"]` and
`"session-bus":{"talk":["org.freedesktop.Flatpak",...]}`, and gets no
warning. The bus policies show as raw JSON (`Menu.qml:271`,
`JSON.stringify`).

**Decided at intent approval:**
- **Highlight only.** An app whose manifest escapes the sandbox still queues
  on one Enter. `queue()` is not changed.
- **The same list as overrides.** `ESCAPES_JSON` stays the one place the
  list is written. Nothing is copied into QML.
- A failed summary lookup stays `permissions: UNKNOWN` in `Color.urgent`.
  It never reads "none listed" or "no escapes".

**Decided at spec approval:**
- **Only the heading is red.** The block's heading line
  `escapes its sandbox` is `Color.urgent`. The entry lines under it use the
  normal text colour, `Color.menu.text`. Reason: the block appears on 17 of
  19 popular apps, and an all-red block trains people to ignore red. This
  replaces the spec's D2 wording, where the whole block was urgent.
- **`System Bus Policy *` is kept.** In the live sample, every app that
  talks to a system bus name is already flagged by another entry (Firefox
  `org.freedesktop.NetworkManager` next to `devices=all`), so narrowing it
  would change no card and would weaken #12's override warning.
- **A separate block, above the permissions list.** The full list stays
  complete, in store order, in the normal colour.
- **Wildcard bus names.** A manifest bus name ending in `.*` matches a list
  key that starts with its prefix. So `talk org.freedesktop.*` is flagged as
  `org.freedesktop.Flatpak`.

**Design summary:**
- **CLI (D1).**
  - `lookup_flatpak` adds `manifestEscapes`. It is `null` when
    `permissions` is `null`. Otherwise it is an array, possibly empty, of
    `{entry, says}` in manifest order.
  - Manifest keys are mapped onto the list's shape:
    - `"<k>": [v...]` becomes `Context`/`<k>`/`v`, with entry text `<k>=<v>`.
    - `"session-bus"` / `"system-bus": {talk|own: [n...]}` become
      `Session Bus Policy` / `System Bus Policy`, `n`, `talk`/`own`, with
      entry text `<bus> <pol> <n>`.
    - Any other shape is skipped.
  - A match uses the same rule as `_escapes`: section equal; the value, with
    a trailing `:ro`/`:rw`/`:create` dropped, is in `values`; and key `*` or
    equal, plus the `.*` prefix rule above. The first matching list entry
    gives `says`.
  - `permissions` itself is unchanged.
- **Card (D2).** Between the licence and permissions lines, flatpak only:
  - Non-empty `manifestEscapes`: a heading `escapes its sandbox` in
    `Color.urgent`, then a `Line` in `Color.menu.text` with one indented
    `<entry>: <says>` per match.
  - `[]` or `null`: nothing. For `null`, the UNKNOWN line already covers it.
  - `undefined` with an object `permissions` (an older CLI): the heading
    alone, in `Color.urgent`, reading
    `sandbox escapes: not checked (no list from nixarchy-flatsnap)`.
- **Readable bus lines (D3).** A pure function
  `permissionText(p)` in `FlatsnapModel.qml` replaces the inline text in
  `Menu.qml`. An object of arrays renders as `<k> talk: a, b` and
  `<k> own: c`. The other cases keep today's output.
- **README (D5).** One paragraph under "Overrides that escape the sandbox".

**Hosts.** This is display only. No apply, preflight or `nixarchy-apply` on
p620 or razer. Live checks are on razer only, reserved by the user (step 11).

**Merge order: #36 → #28 → #27 → #26.** This lands third, after #36 and
#28, and #26 rebases on it.

## Steps

1. **Rebase onto main after #36 and #28 have merged.** Do not start the
   code steps before then.
   - `git fetch origin && git rebase origin/main`. Only `docs(*)` commits
     are on this branch, so there should be no conflicts.
   - Re-read what changed: `git diff d3a2744 origin/main -- Menu.qml
     FlatsnapModel.qml bin/nixarchy-flatsnap tests/`.
   - #36 (panel footers, wrapping at scale 2) touches `Menu.qml`. Update
     this plan's line numbers for the card's licence and permissions lines,
     and note any wrapping rule the new `Line`s must follow.
   - #28 (Bus Policy overrides are split on spaces) changes how
     `Session Bus Policy` / `System Bus Policy` overrides reach `_escapes`.
     Note the new override form. Step 6 must test both matchers with it.
   - If either one changes `_escapes`' matching rule or `ESCAPES_JSON`,
     update the decisions above in the same commit as step 3.
   → Verify: `bash tests/cli.sh` and `bash tests/model.sh` are green on the
   rebased branch before any edit.

2. **`tests/fixtures/`: record VS Code and Firefox.** These are read-only
   GETs, trimmed to the fields the CLI reads, as the existing fixtures are.
   Values are copied verbatim.
   ```
   for a in com.visualstudio.code org.mozilla.firefox; do
     curl -fsS https://flathub.org/api/v2/appstream/$a \
       | jq '{name, summary, developer_name, project_license, metadata}' \
       > tests/fixtures/flathub-appstream-$a.json
     curl -fsS https://flathub.org/api/v2/summary/$a \
       | jq '{metadata: {permissions: .metadata.permissions}}' \
       > tests/fixtures/flathub-summary-$a.json
   done
   ```
   → Verify: the VS Code summary has `"host"`, `"ssh-auth"`, `"all"`,
   `org.freedesktop.Flatpak` under `session-bus.talk`, and
   `org.freedesktop.login1` under `system-bus.talk`. The Firefox summary has
   `"all"`, `org.freedesktop.NetworkManager` under `system-bus.talk`,
   `org.mozilla.firefox.*` under `session-bus.own`, and
   `xdg-config/gtk-3.0:ro`. If Flathub has changed since 2026-09-24, record
   what is there now and adjust step 4's expectations in the same commit.

3. **`bin/nixarchy-flatsnap`: `MANIFEST_ESCAPES_JQ` and the new field.**
   - Add it after `FH_VERIFY_JQ`, with the same
     `# shellcheck disable=SC2016` line. Its comment names
     `FlatsnapModel.qml` `_escapes` as the matcher it must agree with.
     ```
     def manifestescapes($esc):
       if . == null then null else
       [ to_entries[] | .key as $k | .value as $v
         | ( if ($k == "session-bus" or $k == "system-bus") and ($v | type) == "object" then
               $v | to_entries[] | select(.value | type == "array") | .key as $pol
               | .value[] | select(type == "string")
               | {section: (if $k == "session-bus" then "Session Bus Policy" else "System Bus Policy" end),
                  key: ., value: $pol, entry: "\($k) \($pol) \(.)"}
             elif ($v | type) == "array" then
               $v[] | select(type == "string") | {section: "Context", key: $k, value: ., entry: "\($k)=\(.)"}
             else empty end )
         | . as $e | ($e.value | sub(":(ro|rw|create)$"; "")) as $val
         | first($esc[] | select(.section == $e.section and (.values | index($val)) != null
             and (.key == "*" or .key == $e.key
                  or (($e.key | endswith(".*")) and (.key | startswith($e.key | rtrimstr("*")))))))
         | {entry: $e.entry, says: .says} ]
       end;
     ```
   - In `lookup_flatpak`, prepend `$MANIFEST_ESCAPES_JQ` to the filter as
     `$FH_VERIFY_JQ` is. Bind the permissions once:
     `(if $s == null then null else ($s.metadata.permissions // {}) end) as $p`.
     Then emit `permissions: $p` and
     `manifestEscapes: ($p | manifestescapes($esc))`.
   - The comment above `ESCAPES_JSON` gains: "Also marks the app's own
     permissions on the card (manifestEscapes); a label, not a second
     Enter."
   → Verify: `bash bin/nixarchy-flatsnap resolve org.gnome.Calculator` with
   `NIXARCHY_FLATSNAP_OFFLINE=tests/fixtures` gives `manifestEscapes: []`.
   `shellcheck bin/nixarchy-flatsnap` is clean.

4. **`tests/cli.sh`: manifest escapes.** Add these after the
   `sandboxEscapes` block (`has_escape`, `:114-124`):
   - `com.visualstudio.code`: `[.manifestEscapes[].entry] ==
     ["devices=all", "sockets=ssh-auth", "session-bus talk
     org.freedesktop.Flatpak", "filesystems=host", "system-bus talk
     org.freedesktop.login1"]`. This is the live order on 2026-09-25,
     checked against this jq. If the recorded fixture's key order differs,
     follow the fixture. Also `all(.manifestEscapes[];
     (.says | length) > 0)`.
   - `org.mozilla.firefox`: the entries are exactly `devices=all` and
     `system-bus talk org.freedesktop.NetworkManager`. Nothing matches
     `org.mozilla.firefox.*` or `xdg-config/gtk-3.0:ro`.
   - `org.gnome.Calculator` and `com.spotify.Client`:
     `.manifestEscapes == []`.
   - `org.example.NoSummary`: `.permissions == null and
     .manifestEscapes == null`.
   - Shape cases, run inline through the same jq definitions. The file
     already runs jq with `$ESCAPES_JSON`: source the two variables with
     `sed -n` from the CLI, or add a fixture
     `flathub-summary-org.example.Shapes.json` plus its appstream file.
     The fixture is preferred, since it goes through `lookup_flatpak`
     itself. Its permissions are `filesystems: ["host:ro", "!host",
     "~/Games", "xdg-download"]`, `session-bus: {talk:
     ["org.freedesktop.*"]}`, `features: ["devel"]`, and `shared: "odd"`
     (a non-array, which is skipped). Expected entries: `filesystems=host:ro`
     and `session-bus talk org.freedesktop.*`, nothing else.
   → Verify: `bash tests/cli.sh` prints `N passed, 0 failed`. Temporarily
   removing the `.*` clause fails the Shapes case. Undo that before
   committing.

5. **`FlatsnapModel.qml`: `permissionText(p)`.** Place it next to
   `_escapes`. `_escapes`' comment gains "the manifest's own permissions are
   matched in the CLI (MANIFEST_ESCAPES_JQ); keep the rules the same".
   ```
   function permissionText(p) {
     if (p === null) return "permissions: UNKNOWN (the Flathub lookup failed)"
     p = p || {}
     var out = []
     for (var k in p) {
       var v = p[k]
       if (Array.isArray(v)) out.push(k + ": " + v.join(", "))
       else if (v && typeof v === "object"
                && Object.keys(v).every(function (pol) { return Array.isArray(v[pol]) }))
         for (var pol in v) out.push(k + " " + pol + ": " + v[pol].join(", "))
       else out.push(k + ": " + JSON.stringify(v))
     }
     return out.length ? "permissions\n  " + out.join("\n  ") : "permissions: none listed"
   }
   ```
   → Verify: step 6.

6. **`tests/model.qml`: `permissionText` and the shared matcher values.**
   - `permissionText(null)` contains `UNKNOWN`. `permissionText({})` is
     `permissions: none listed`.
   - `permissionText({"session-bus": {talk: ["a.b"], own: ["c.d"]}})`
     contains `session-bus talk: a.b` and `session-bus own: c.d`, and not
     `{"`.
   - `permissionText({devices: ["dri"]})` contains `devices: dri`.
   - Matcher agreement: for `_escapes`, `Context.filesystems=host:ro` is
     flagged, and `Context.filesystems=~/Games` and
     `Context.filesystems=!host` are not. The Bus Policy override form after
     #28 (step 1) is flagged for `org.freedesktop.Flatpak=talk`. These are
     the same values step 4 checks in jq.
   → Verify: `bash tests/model.sh` prints `model: N passed, 0 failed`.

7. **`Menu.qml`: the escape block and the permissions text.**
   - After the licence `Line`, add a `Column` (or two `Line`s) with
     `visible: !cardCol.isSnap && (escList.length > 0 || notChecked)`, where
     - `readonly property var escList: Array.isArray(cardCol.c.manifestEscapes) ? cardCol.c.manifestEscapes : []`
     - `readonly property bool notChecked: cardCol.c.manifestEscapes === undefined && cardCol.c.permissions != null && typeof cardCol.c.permissions === "object"`
   - Heading `Line`: `color: Color.urgent`, text
     `notChecked ? "sandbox escapes: not checked (no list from nixarchy-flatsnap)" : "escapes its sandbox"`.
   - Entries `Line`: `color: Color.menu.text`, `visible: escList.length >
     0`, text `"  " + escList.map(e => e.entry + ": " + e.says).join("\n  ")`.
   - Both are `Line` (`Text.PlainText`), `width: parent.width`, with the
     default font. There is no font size arithmetic and there are no colour
     literals. If #36 introduced a wrap mode for card lines, use it too.
   - The permissions `Line` keeps its colour rule. Its text becomes
     `fs.permissionText(cardCol.c.permissions)`.
   → Verify: the QML load check in Tests, then razer (step 11).

8. **`README.md`: one paragraph** under "Overrides that escape the sandbox",
   after the table: "The card also checks the app's own permissions against
   this list. Matches are listed under **escapes its sandbox** with what
   they grant; that is a label, not a second `Enter`. Bus access is shown as
   `talk`/`own` lines, and a name ending in `.*` counts as every name under
   it." → Verify: it reads correctly in the rendered Markdown.

9. **Local checks** (Tests below), all green.

10. **Commit per step** with `(#27)` in the subject. A deviation from this
    plan updates this file in the same commit as the code.

11. **razer: the live check.** No apply is needed: this is display only.
    - **Reserve razer.** The user reserves razer for the window, which
      means other agents' razer sessions are stopped, not just asked to
      wait. Read the bus right before starting, post a claim ("no
      switches, no shell restarts until done"), and do not start until the
      user confirms.
    - **Baseline:** generation 2957. Confirm it with
      `readlink /nix/var/nix/profiles/system` before starting. Record the
      monitor line (`hyprctl monitors`).
    - **Setup** (#22's route): a throwaway clone of nixos_config at the
      commit 2957 came from, in `/tmp/flake-27` on razer, with
      `programs.nixarchy.flake = lib.mkForce "/tmp/flake-27"` and the
      `nixarchy-flatsnap` input set to this branch's head. Build on p620
      (build only, no apply or preflight there), `nix copy` to razer, then
      run `switch-to-configuration test` on razer. `test` adds no
      generation.
    - **Shell restart:** kill `omarchy-launch-shell` and the shell by pid
      first, then relaunch with `hyprctl dispatch
      'hl.dsp.exec_cmd("env NIXARCHY_FLAKE=/tmp/flake-27
      omarchy-launch-shell")'`. Confirm `NIXARCHY_FLAKE` in
      `/proc/<pid>/environ`, the plugin link on the new build, and no
      `ReferenceError` or `TypeError` in the shell journal.
    - **Checks at scale 1 and at scale 2** (`hyprctl eval 'hl.monitor({
      output = "eDP-1", mode = "1920x1080", position = "0x0", scale = 2 })'`):
      - `com.visualstudio.code`: a red `escapes its sandbox` heading, then
        five entries in the normal colour, each with what it grants.
        Bus permissions show as `session-bus talk: …` and `system-bus talk:
        …`, with no `{"`.
      - `org.mozilla.firefox`: two entries.
      - `org.gnome.Calculator`: no block.
      - The card scrolls to the end with `j`/PgDn (#15). Lines wrap and do
        not clip (#36).
      - Nothing is queued. Enter is not pressed on any card.
    - Screenshots at both scales go to branch `pr-assets/27`.
    - One attempt only. If razer is disrupted from outside, restore (step
      12) and stop. Do not retry without the user.

12. **razer: restore** (always, also after a stop):
    - `/run/current-system` back to 2957:
      `/nix/var/nix/profiles/system-2957-link/bin/switch-to-configuration
      test`.
    - Restore the monitor line, or run `hyprctl reload`.
    - Kill `omarchy-launch-shell` and the shell, then relaunch with
      `hyprctl dispatch 'hl.dsp.exec_cmd("omarchy-launch-shell")'` (no
      `NIXARCHY_FLAKE`).
    - Remove `/tmp/flake-27`.
    - **Never remove `core`** (snap) or any snap or flatpak. This check
      installs nothing, so there is nothing to remove.
    - Confirm the generation is still 2957, 0 failed units (system and
      user), and the plugin link back on its starting store path. Post that
      on the bus.

13. **PR** into main. It links the intent, spec and plan, holds the
    screenshots, and says it merged after #36 and #28 and that #26 rebases
    on it.

## Tests

Nothing below runs `nixarchy-apply`, preflight or a switch on p620.

```
bash tests/cli.sh     # "N passed, 0 failed", incl. VS Code / Firefox / Shapes / NoSummary
bash tests/model.sh   # "model: N passed, 0 failed", incl. permissionText
nix flake check -L    # shellcheck, cli, manifest, no-hardcoded-colours, no-text-multiplier
```

- **QML load:** `Menu.qml` loads with no `ReferenceError` or `TypeError`.
  This is checked in the shell journal after the step-11 relaunch on razer.
- **Live:** step 11 on razer only.

## Rollback

- **Before merge:** drop the branch. Nothing outside the repo changes
  except razer, which step 12 restores.
- **After merge:** `git revert` the merge commit. `manifestEscapes` is a
  new, optional field. An older `Menu.qml` ignores it, and a newer
  `Menu.qml` with an older CLI shows "not checked". There are no state file
  or module changes.
- **On razer:** step 12. It restores generation 2957's system, the monitor
  line and the shell without `NIXARCHY_FLAKE`, removes `/tmp/flake-27`,
  and removes nothing else.
