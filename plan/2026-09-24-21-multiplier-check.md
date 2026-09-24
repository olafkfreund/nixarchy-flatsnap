---
status: approved
issue: 21
spec: spec/2026-09-24-21-multiplier-check.md
---

# Plan: the text-size check catches a plain multiplier

The `no-text-multiplier` flake check (added by #9) is meant to stop a fixed
multiplier on a font token from coming back. Today it checks only
`Menu.qml`, and only `pixelSize:` lines. It passes any line where
`Style.font.<token>` is followed by a space, so
`font.pixelSize: Style.font.title * 1.45` gets through. Of the inputs
tried, only `Math.round(Style.font.title * 1.45)` and
`Style.font.title*1.45` (no spaces) were caught.

**Decided at intent approval:**

1. Cover every `*.qml` file in the repo.
2. Forbid any arithmetic on a font size. Use an allow-list: a bare
   `Style.font.<token>`, optional whitespace, then `;`, `}` or end of line.

**Decided at spec approval (design):**

3. One `runCommand`, grep only. No new files and no new inputs. The source
   is `lib.fileset` limited to `.qml` files, so new `.qml` files are covered
   automatically, and the check rebuilds only when a `.qml` file changes.
4. Check each binding, not each line. `grep -o` cuts out each binding up to
   the next `;` or `}`. Every fragment must match the allow-list, so a clean
   first binding on a line cannot hide a bad second one.
5. The case table from the intent is part of the check. It runs first:
   every bad row must be flagged and every clean row must pass, or the build
   fails and names the row.
6. The old `textScale|uiScale|px\(` guard stays, and now covers every
   `.qml` file.
7. False positives are accepted: a trailing `// comment` after a bare
   token, and a binding split across lines.
8. `pointSize:` is covered too, alongside `pixelSize:` and `fontSize:`, with
   one bad and one clean self-test row.

**Merge order:** this PR (#21) merges first, then #15, then #23. Those two
rebase onto it.

## Exact check body

This replaces the whole `no-text-multiplier` block in `flake.nix`. That is
from the comment line `# A fixed multiplier on a font token stops text
following the` to the `'';` that closes the check, 11 lines at
`flake.nix:109-119` on current main. Indentation is as it should sit in the
file (10 spaces):

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
                  grep -rHnoE '(pixelSize|pointSize|fontSize):[^;}]*' "$@" \
                    | grep -vE '^[^:]+:[0-9]+:(pixelSize|pointSize|fontSize):[[:space:]]*Style\.font\.[A-Za-z]+[[:space:]]*$'
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
              font.pointSize: Style.font.title * 1.45
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
              font.pointSize: Style.font.title
              EOF

              if offenders ${qml}; then
                echo "fixed text multiplier above; use a bare Style.font token" >&2
                exit 1
              fi
              touch "$out"
            '';
```

Why this is safe as a Nix `''` string:

- Nix strips the common indentation, so the heredoc rows and both `EOF`
  terminators land at column 0, as bash requires.
- Only `${qml}` is interpolated. `$(printf '\t')` puts a real tab into the
  tab row; that is why the first heredoc is unquoted. There is no `''`
  sequence inside the body.

Before writing this plan, the body was run as plain bash, with `${qml}`
standing in for a directory holding main's three `.qml` files
(`scratchpad/mc2.sh`):

- All 11 bad rows were flagged, and all 6 clean rows passed.
- Main passed.
- A line `font.pixelSize: Style.font.title * 1.45` added to
  `tests/model.qml` failed the check and was named.

## Steps

1. **Put the block in a scratch file:** save the check body above
   verbatim to a file outside the repo, for example
   `$SCRATCH/block.nix`.
   → Verify: `head -1` of the file is the `# A multiplier` comment and
   `tail -1` is `'';`.
2. **Edit `flake.nix` through Bash only, never Write/Edit.** A managed hook
   rewrites any `.nix` file touched by Write/Edit with nixfmt, which would
   bury this change in a whole-file reformat.
   - `start=$(grep -n '# A fixed multiplier on a font token' flake.nix | cut -d: -f1)`
   - `end` is the first line after `start` that is exactly 10 spaces and
     `'';`.
   - Check that `sed -n "${start},${end}p" flake.nix` prints the old
     11-line block and nothing else.
   - Replace it: `head -n $((start-1)) flake.nix`, then `block.nix`, then
     `tail -n +$((end+1)) flake.nix`, concatenated into a scratch file and
     copied over `flake.nix`.
     *Deviation at implementation:* the original step used `sed -i … r`,
     and the worktree guard refuses a `sed` `r` program, so the splice uses
     head/cat/tail instead. The result is identical.

   → Verify: `git diff --stat origin/main...HEAD -- flake.nix` plus
   `git diff -- flake.nix` show one hunk, inside the check block only. No
   reformatting anywhere else in the file.
3. **Build the check:**
   `nix build .#checks.x86_64-linux.no-text-multiplier -L`.
   → Verify: it succeeds. This proves that the Nix wrapping (`fileset`
   source, indentation stripping, heredocs) works and that the self-test
   table passes on main.
4. **Mutation run.** Temporarily append
   `    font.pixelSize: Style.font.title * 1.45` to `Menu.qml` in the working
   tree, or to a scratch copy placed in the tree, and re-run step 3.
   → Verify: the build fails, printing
   `…/Menu.qml:<n>:pixelSize: Style.font.title * 1.45` and
   `fixed text multiplier above`.
   - Revert the file and confirm `git status` shows only `flake.nix`
     changed.
   - Optionally, change the allow-list's trailing `[[:space:]]*$` to the
     old `([;}[:space:]]|$)`. The build must fail with
     `check missed: font.pixelSize: Style.font.title * 1.45`. Revert that
     too.
5. **Full check suite:** `nix flake check -L`.
   → Verify: everything is green. Only `no-text-multiplier` changed, and the
   others must still pass.
6. **Commit** `flake.nix` alone:
   `fix(checks): no-text-multiplier catches arithmetic on any font size (#21)`,
   with the two attribution lines.
   → Verify: `git show --stat HEAD` lists only `flake.nix`.
7. **Push and open the PR.**
   - Push the branch, then open a PR `Fixes #21`.
   - The description links `intent/`, `spec/` and
     `plan/2026-09-24-21-multiplier-check.md` and states the merge order
     (#21 first, then #15, then #23).
   - Wait for CI to go green before asking for merge.
   - No razer run is needed: this is a `checks` output only, and nothing
     changes at runtime.

## Tests

| Command | Expected |
| --- | --- |
| `nix build .#checks.x86_64-linux.no-text-multiplier -L` on the branch | success |
| same, with `font.pixelSize: Style.font.title * 1.45` appended to `Menu.qml` | fails and names the line |
| same, with the old trailing class `([;}[:space:]]\|$)` in the allow-list | fails: `check missed: …` |
| `nix flake check -L` | all checks pass |
| `git diff --stat origin/main...HEAD -- flake.nix` | `flake.nix` only, changes confined to the check block |
| CI on the PR | green |

## Rollback

`git revert <fix commit>` restores the old check body. That is safe: the old
check also passes on main. There is no runtime, module or package change, so
there is nothing to undo on any host.
