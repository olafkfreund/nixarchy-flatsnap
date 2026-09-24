---
status: draft
issue: 21
intent: intent/2026-09-24-21-multiplier-check.md
---

# Spec: the text-size check catches a plain multiplier

## Design

**Decided at intent approval:**

1. The check covers every `*.qml` in the repo, and both `pixelSize:` and
   `fontSize:`.
2. Any arithmetic on a font size is forbidden. Only an allow-list form
   passes: a bare `Style.font.<token>`, optional whitespace, then `;`, `}` or
   end of line.

**Change, `flake.nix` only:** replace the `no-text-multiplier` check
(`flake.nix:109-119`) with the body below. It is the same kind of check as
before: one `runCommand`, grep only, no new inputs and no new files.

- **Files:** `lib.fileset` gives the check a source tree that holds only the
  `.qml` files. A new `.qml` file is scanned without editing the check, and
  the check rebuilds only when a `.qml` file changes. Today that is
  `Menu.qml`, `FlatsnapModel.qml` and `tests/model.qml`.
- **Per occurrence, not per line:** `grep -o` cuts out each
  `pixelSize:`/`fontSize:` binding up to the next `;` or `}` (or end of
  line). Every fragment must be exactly `<prop>: Style.font.<token>`,
  followed by optional whitespace. This fixes the old gap, where the pattern
  ended in `[[:space:]]` and ignored anything after a space. It also catches
  a second, bad binding on a line whose first binding is clean.
- **Self-test first:** before scanning the tree, the check runs itself over
  the case table from the intent. Every bad case must be flagged and every
  clean case must not be, or the check fails and names the case. This way,
  loosening the regex later fails CI. No sibling check is needed because the
  table costs nothing to run.
- The old `textScale|uiScale|px\(` guard stays, and now also covers every
  `.qml` file.

**Exact new check body** (replaces lines 109-119):

```nix
          # A multiplier, or any arithmetic, on a font token stops text
          # following the shell's text size (#9, #21). Every size in every
          # .qml is a bare Style.font.* token. The cases prove the check first.
          no-text-multiplier =
            let
              qml = nixpkgs.lib.fileset.toSource {
                root = ./.;
                fileset = nixpkgs.lib.fileset.fileFilter (f: f.hasExt "qml") ./.;
              };
            in
            pkgs.runCommand "nixarchy-flatsnap-text-size" { } ''
              # Prints each offending binding; succeeds when there is one.
              offenders() {
                {
                  grep -rHnE 'textScale|uiScale|px\(' "$@"
                  grep -rHnoE '(pixelSize|fontSize):[^;}]*' "$@" \
                    | grep -vE '^[^:]+:[0-9]+:(pixelSize|fontSize):[[:space:]]*Style\.font\.[A-Za-z]+[[:space:]]*$'
                } | grep .
              }

              while IFS= read -r l; do
                printf '%s\n' "$l" > case.qml
                offenders case.qml >/dev/null || { echo "check missed: $l" >&2; exit 1; }
              done <<EOF
              font.pixelSize: Style.font.title * 1.45
              font.pixelSize: Style.font.title$(printf '\t')* 1.45
              font.pixelSize: Style.font.title*1.45
              font.pixelSize: Style.font.title + 4
              font.pixelSize: Style.font.title / 2
              font.pixelSize: Math.round(Style.font.title * 1.45)
              font.pixelSize: 14
              fontSize: Style.font.title * 1.45
              a.pixelSize: Style.font.body; b.pixelSize: Style.font.body * 2
              font.pixelSize: px(Style.font.body)
              EOF

              while IFS= read -r l; do
                printf '%s\n' "$l" > case.qml
                if offenders case.qml >&2; then echo "check flagged a clean line: $l" >&2; exit 1; fi
              done <<'EOF'
              font.pixelSize: Style.font.title
              font.pixelSize: Style.font.title; font.bold: true
              Line { text: "x"; font.pixelSize: Style.font.heading; width: parent.width }
              fontSize: Style.font.body }
              font.pixelSize:Style.font.caption
              EOF

              if offenders ${qml}; then
                echo "fixed text multiplier above; use a bare Style.font token" >&2
                exit 1
              fi
              touch "$out"
            '';
```

Notes for the implementer:

- Nix strips the common indentation of a `''` string, so the heredoc lines
  and their `EOF` terminators start at column 0 in the script, as bash
  needs. The first heredoc is unquoted on purpose: `$(printf '\t')` puts a
  real tab into the tab case. Nothing else in it expands. Only `${` would be
  interpolated by Nix, and the body has only `${qml}`.
- **Edit `flake.nix` through Bash** (for example a small script or `sed`
  line-range replacement). Do not use the Write/Edit tools: a managed hook
  runs nixfmt over any `.nix` file they touch, and that would bury this
  change in a whole-file reformat.

## Alternatives rejected

- **Only tighten the regex, as the issue suggests**
  (`pixelSize: Style\.font\.[A-Za-z]+[[:space:]]*([;}]|$)`). This fixes the
  space case, but the check still works per line: a clean first binding
  hides a bad second one on the same line. There would also be no proof that
  the check works. The per-fragment form is the same size.
- **Deny-list of operators** (`*`, `/`, `+`, `-`, `Math.`). Rejected at
  intent approval. An allow-list cannot miss an operator nobody thought of.
- **List the files explicitly** (`${./Menu.qml} ${./FlatsnapModel.qml}
  ${./tests/model.qml}`). This is the gap that let only `Menu.qml` be
  checked: a new `.qml` file is silently skipped.
- **`${./.}` as the source.** It copies the whole repo, including
  `docs/` media, into the store, and rebuilds the check on every commit.
  `fileset` copies only the `.qml` files.
- **Separate `tests/text-size.sh` plus a sibling check.** It adds a file,
  a shellcheck entry and a second derivation for about 30 lines of shell
  that only this check uses.
- **A QML parser (qmllint/qmlformat AST).** Too heavy for this rule, and
  it pulls Qt into the check closure.

## Risks

- **False positives on legitimate forms.** A trailing `// comment` after a
  bare token, or a binding split across lines, is flagged. Neither exists
  today, and the error names the line, so the cost is a one-line reformat.
  This is accepted.
- **Missed forms.** An intermediate property (`font.pixelSize: big`) is
  flagged, because `big` is not a `Style.font` token. What still passes is a
  size set without `pixelSize:`/`fontSize:`, for example a whole `font:`
  object or `font.pointSize:`. None of that exists here. The check is a
  guard rail, not a proof.
- **`lib.fileset` availability.** `fileFilter` with `hasExt` needs nixpkgs
  24.05 or later. The pinned nixos-unstable (`6774f7b`, 2026) has it.
- **Host impact:** none. This is a `checks` output only; the plugin package
  and the module are unchanged. Nothing runs on razer or p620.

## Verification

1. **By hand, before editing `flake.nix`:** this was already done while
   writing this spec. The check body was run as plain bash
   (`scratchpad/mc2.sh`, with `${qml}` replaced by a directory holding the
   three `.qml` files from main):
   - All 10 bad cases were flagged, and all 5 clean cases passed.
   - Main (`Menu.qml`, `FlatsnapModel.qml`, `tests/model.qml`) passed.
   - Appending `font.pixelSize: Style.font.title * 1.45` to
     `tests/model.qml` failed the check with
     `tests/model.qml:222:pixelSize: Style.font.title * 1.45`. This shows
     that files other than `Menu.qml` are now scanned.
2. **After the edit:**
   `nix build .#checks.x86_64-linux.no-text-multiplier` succeeds, and
   `nix flake check` is green.
3. **Negative, not committed:** add `font.pixelSize: Style.font.title * 1.45`
   to `Menu.qml` in the working tree. The same `nix build` must fail and
   print that line. Then revert.
4. **Self-test bites:** temporarily change the allow-list's trailing
   `[[:space:]]*$` to the old `([;}[:space:]]|$)`. The build must fail with `check missed: font.pixelSize: Style.font.title * 1.45`.
   Then revert.
5. **Diff hygiene:** `git diff flake.nix` touches only the
   `no-text-multiplier` block. No nixfmt reformat anywhere else.
