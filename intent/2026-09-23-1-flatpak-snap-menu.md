---
status: draft
issue: 1
author: olafkfreund
---

# Intent: install Flatpak and Snap apps from the Omarchy menu

## Problem

Some software is not in nixpkgs, or is only current as a Flatpak or a Snap:
vendor-built apps, proprietary clients, things whose upstream publishes only
to Flathub or the Snap Store. On nixarchy there is no desktop route to either.

Flatpak is half there. nixarchy already pulls in `nix-flatpak` and declares
Flatpaks through `programs.nixarchy.flatpaks.apps.<name>.enable`, but only
for the entries curated in `data/flatpaks.nix`. An app outside that list
means `flatpak install` in a terminal, which works until the next rebuild
decides whether that app is managed, and never shows up in the configuration
the machine is supposed to be described by. With
`flatpaks.uninstallUnmanaged = true`, it is deleted on the next rebuild.

Snap has nothing. nixpkgs has no `snapd` service option (`services.snap*`),
no `/snap` mount and no AppArmor wiring, so a Snap cannot run on NixOS
without a module from outside nixpkgs.

In both cases the person usually has something in hand already: an app ID
from a README (`com.spotify.Client`), a store page URL
(`https://flathub.org/apps/…`, `https://snapcraft.io/…`) or a `.flatpakref`.
Today nothing takes that and turns it into an installed, declared app.

## Proposed outcome

From the Omarchy menu, a keyboard-only flow:

- Paste or type an app ID, package name, or Flathub / Snapcraft / `.flatpakref`
  URL. The plugin works out which store and which ID it is and shows the app's
  name, summary, publisher, license and requested permissions before
  anything is queued.
- Search Flathub and the Snap Store by name when there is no ID to paste.
- Queue the app. For Snaps, choose channel (stable/candidate/beta/edge) and
  confinement (strict/classic). For Flatpaks, choose remote and optional
  permission overrides.
- See what is declared, what is queued and what is installed, and remove an
  app by un-declaring it.
- Nothing is installed until an explicit apply. After apply, the app is in the
  machine's declarative configuration and survives rebuilds and rollbacks.

The whole flow carries the Omarchy theme and never needs the mouse.

## Affected users and systems

- nixarchy users on Omarchy Quattro. The plugin is opt-in, installed through
  `programs.nixarchy.plugins.<name>.src` like `nixarchy-pkg` and
  `nixarchy-plugin-browser`.
- `~/.config/nixarchy/`: where the declared app lists would live.
- The system configuration: `services.flatpak` (already present through
  `nix-flatpak`), plus a new Snap service module.
- The Omarchy shell process, which loads plugin QML unsandboxed.
- Network: read-only lookups against the Flathub and Snap Store APIs.

## Constraints

- **Declarative, not imperative.** The source of truth is a Nix file. The
  plugin writes that file and hands off to `nixarchy-apply`, and it never
  leaves an app installed that the configuration does not know about.
  Imperative `flatpak install` / `snap install` is the thing this replaces.
- **Must not break nixarchy's Flatpak semantics.** Arbitrary IDs must extend
  `services.flatpak.packages` and `remotes`, not replace them (the `++` in
  `modules/flatpaks.nix` exists because replacing the list silently drops
  Flathub). It must respect `flatpaks.uninstallUnmanaged`.
- **Must not reimplement nixarchy's writers or apply.** Reuse the backup →
  edit → `nix-instantiate --parse` → restore idiom and `nixarchy-apply`.
- **No implicit builds or elevation.** Queuing edits a file, and only an
  explicit apply rebuilds.
- **Untrusted input.** Pasted text, URLs and store metadata are data: they are
  validated against an ID grammar before they reach a Nix file or a process
  argument, they are never interpolated into a shell string, and they are shown
  as plain text, not markup.
- **Theme and keyboard.** Colours come from the shell's tokens. Every action
  has a key.
- **No symlinks inside the plugin directory.** Omarchy's validator refuses them.
- Public repo with a GitHub Pages site styled like
  `olafkfreund.github.io/nixarchy` (Jekyll under `/docs`).

## Open questions

1. **Snap service source.** nixpkgs has no `services.snap`. The choices are to
   depend on `io12/nix-snapd` (third party, maintained, adds `services.snap`
   and confinement), to write a minimal snapd module in this repo, or to scope
   v1 to Flatpak and add Snap later. Snap "fully supported" makes this the
   decision most likely to change the size of the work.
2. **Declarative Snaps.** `nix-snapd` runs the daemon but does not declare
   *which* snaps are installed. Either this project adds a small declarative
   layer (a systemd oneshot that reconciles a list against `snap list`), or
   Snaps stay imperative and are only tracked.
3. **Where the lists live.** A new `~/.config/nixarchy/flatsnap.nix` imported by
   nixarchy (needs a nixarchy change), or entries in the existing
   `advanced.nix` (no nixarchy change, but mixes with hand-written options).
4. **Menu entry point.** A new item under the Omarchy menu's *Install* section
   (like *Install → Package*), a dedicated chord, or both.
5. **Flatpak scope.** System-wide installs only (nixarchy's current
   `services.flatpak`), or also per-user through Home Manager's `nix-flatpak`
   module.
