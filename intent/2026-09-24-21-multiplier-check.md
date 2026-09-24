---
status: draft
issue: 21
author: olafkfreund
---

# Intent: the text-size check catches a plain multiplier

## Problem

#9 removed the fixed 1.45 font multiplier from the menu and added the
`no-text-multiplier` flake check (`flake.nix:111-119`) so it cannot come
back. The check lists every `pixelSize:` line in `Menu.qml` and fails on any
line that is not `pixelSize: Style.font.<name>` followed by
`[;}[:space:]]` or end of line. Because whitespace counts as a valid ending,
anything after a space is ignored, so the most obvious way to bring the
multiplier back passes.

Verified by appending one line to a copy of `Menu.qml` and running the
check's grep pipeline by hand:

| Line added                                             | Result      |
| ------------------------------------------------------ | ----------- |
| `font.pixelSize: Style.font.title * 1.45`              | passes (bug) |
| `font.pixelSize: Style.font.title<TAB>* 1.45`          | passes (bug) |
| `font.pixelSize: Style.font.title + 4`                 | passes (bug) |
| `fontSize: Style.font.title * 1.45`                    | passes (not scanned) |
| `font.pixelSize: Math.round(Style.font.title * 1.45)`  | caught      |
| `font.pixelSize: Style.font.title*1.45`                | caught      |
| `font.pixelSize: Style.font.title; font.bold: true`    | passes (correct) |

The unmodified `Menu.qml` on main passes, as it should. The check also reads
only `Menu.qml`; `FlatsnapModel.qml` and `tests/model.qml` are not scanned
(neither sets a font size today).

## Proposed outcome

- A font size written as a `Style.font` token with a multiplier or other
  arithmetic after it, with or without spaces, fails `nix flake check`.
- The forms already caught stay caught; a bare token, optionally followed by
  `;` or `}` (as on `Menu.qml:190`), still passes.
- Each case in the table above is exercised, so the check is known to work
  rather than assumed to.

## Affected users and systems

- Contributors to this repo, and CI, which runs `nix flake check`.
- `flake.nix` (the `no-text-multiplier` check). No change to runtime
  behaviour or to any `.qml` file.
- `olafkfreund/nixarchy-plugin-browser#26` is porting the same check; it
  should take the fixed regex, not the current one.

## Constraints

- The check must still pass on current main.
- Edit `flake.nix` via Bash (for example `sed` or a heredoc), not the
  Write/Edit tools: a managed hook rewrites any `.nix` file touched by
  Write/Edit with nixfmt, which would bury the one-line fix in a
  reformatting diff.
- Stays a cheap, text-only check: no QML parser, no VM, no new dependency.

## Open questions

1. **Scope of files.** Should the check also cover `FlatsnapModel.qml`, or
   every `*.qml` in the repo (including `tests/model.qml`)? None of them sets a
   font size today.
2. **What is forbidden.** Should it forbid any arithmetic on font sizes
   (`*`, `/`, `+`, `-`, `Math.*`), or only multiplication?
