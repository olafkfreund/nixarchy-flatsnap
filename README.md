# nixarchy-flatsnap

Install **Flatpak** and **Snap** apps from the Omarchy menu on
[nixarchy](https://github.com/olafkfreund/nixarchy) (Omarchy on NixOS). You paste
a link or an ID, check what the app can reach, queue it, and apply. Everything
works from the keyboard, and everything is declarative.

Some software is only current as a Flatpak or a Snap. nixarchy already
declares Flatpaks for a curated handful. This plugin covers the rest, without
falling back to `flatpak install` in a terminal and hoping the next rebuild
keeps it.

## What you get

| Piece | What it does |
|---|---|
| **Panel** (`nixarchy.flatsnap`) | *Install → Flatpak & Snap* in the Omarchy menu. Paste, look up, queue, apply. |
| **`nixarchy-flatsnap`** | The CLI behind the panel: `resolve`, `search`, `list`, `add`, `rm`, `preflight`, `apply`. JSON out. |
| **NixOS module** | Turns `~/.config/nixarchy/flatsnap.nix` into `services.flatpak.packages` and, for Snaps, [nix-snapd](https://github.com/nix-community/nix-snapd) plus a reconciler unit. |

## What you can paste

| Paste | Becomes |
|---|---|
| `https://flathub.org/apps/org.gnome.Calculator` | Flatpak `org.gnome.Calculator` |
| `https://dl.flathub.org/repo/appstream/<id>.flatpakref` | Flatpak `<id>` |
| `https://snapcraft.io/spotify` | Snap `spotify` |
| `flatpak install flathub org.gimp.GIMP` | Flatpak, with the command line read and never run |
| `snap install code --classic --channel=edge` | Snap, keeping the flags |
| `com.spotify.Client` | Flatpak |
| `spotify` | Both stores are checked, and you pick |

Anything else is refused with a one-line reason: other hosts, `http://`,
non-Flathub remotes, per-user installs, flags it doesn't know. Pasted text
reaches the network, the Nix file or a command only after it matches the
Flatpak or Snap ID grammar.

## Keys

| Key | Does |
|---|---|
| *(paste)* then `Enter` | look it up |
| `Ctrl+F` / `Ctrl+S` | search Flathub / the Snap Store for what is in the field |
| `j` `k` / `↓` `↑` | move |
| `Enter` | on a result: open it; on a card: queue it |
| `c` | cycle the Snap channel: stable → candidate → beta → edge |
| `x` `x` | switch a Snap to classic confinement (two presses: it removes the sandbox) |
| `p` | Flatpak overrides, e.g. `Context.filesystems=xdg-pictures:ro` |
| `Tab` | switch between *Add* and *Declared* |
| `d` then `y` | un-declare the selected app |
| `a` | apply (runs `nixarchy-apply`; the build log streams into the panel) |
| `Esc` | one step back; closes from the top |

Nothing is installed until you press `a`.

## Install

Add the flake and import the module on the host, then give Home Manager the
plugin:

```nix
# flake.nix
inputs.nixarchy-flatsnap.url = "github:olafkfreund/nixarchy-flatsnap";
inputs.nixarchy-flatsnap.inputs.nixpkgs.follows = "nixpkgs";

# NixOS module list
inputs.nixarchy-flatsnap.nixosModules.default

# Home Manager
{ inputs, pkgs, ... }:
let fs = inputs.nixarchy-flatsnap.packages.${pkgs.stdenv.hostPlatform.system}; in {
  programs.nixarchy.plugins.flatsnap.src = fs.default;
  home.packages = [ fs.cli ];   # optional: the CLI on PATH
}
```

Then enable it once: `omarchy plugin enable nixarchy.flatsnap`.

**Requirements:**
- nixarchy's `nixarchy-apply` must copy `flatsnap.nix` into the flake. `nixarchy-flatsnap preflight`
  tells you if yours does not.
- The module relies on nix-flatpak's `services.flatpak.*` options, which nixarchy
  already imports. Outside nixarchy, import
  `github:gmodena/nix-flatpak` yourself.

## What it writes

A single file, `~/.config/nixarchy/flatsnap.nix`. The tool owns it and regenerates
it whole:

```nix
{
  programs.nixarchy.flatsnap = {
    flatpaks = [
      { appId = "org.gimp.GIMP"; overrides = { "Context" = { "filesystems" = [ "xdg-pictures" ]; }; }; }
    ];
    snaps = [
      { name = "spotify"; channel = "stable"; classic = false; }
    ];
  };
}
```

You can edit it by hand if you keep that shape. If it holds anything else, the
tool refuses to touch it rather than drop your edit. Every write is guarded:
back up, write, run `nix-instantiate --parse`, and restore the backup on failure.

## Security: read this before adding Snaps

- **Snap confinement on NixOS is weaker than on Ubuntu.** nix-snapd runs Snaps
  without AppArmor. It uses a setuid `snap-confine` and a bubblewrap
  patched to drop `PR_SET_NO_NEW_PRIVS`. Treat a strict Snap here as roughly as
  trustworthy as the publisher, not as sandboxed. The panel says so on every
  Snap.
- **Classic Snaps have no sandbox at all.** They take two presses to choose
  and are marked in red.
- **snapd is off unless you need it.** The daemon and its setuid helper exist only
  while at least one Snap is declared, or one is still waiting to be removed.
- **Flatpak permissions are shown before you queue.** Overrides only widen or
  narrow what you type, and nix-flatpak keeps any `flatpak override` you set
  yourself.
- **Removal is conservative.** The reconciler removes only Snaps it installed.
  A Snap you installed by hand is never touched. Flatpaks follow nixarchy's
  `flatpaks.uninstallUnmanaged`. If that is on, `a` lists what the apply would
  remove and asks for a second `a`.

**Removing a Snap deletes its data without a snapshot.** snapd normally saves a
snapshot of the data when a snap is removed. On NixOS that step fails (it runs
`sudo` under PAM), so the reconciler removes with `--purge`. The data would be
deleted either way; the snapshot backup is what you give up. Copy anything you
want to keep out of `~/snap/<name>` before un-declaring it.

## Rollback

Un-declare the app and apply. A NixOS rollback restores which apps are
**declared**, not their versions: Flatpaks and Snaps live outside the Nix store.

## Development

```bash
bash tests/cli.sh                     # offline tests (fixtures, no network)
nix flake check                       # + shellcheck, module VM test, gating, manifest, colours
```

The design record is in [`intent/`](intent/), [`spec/`](spec/) and [`plan/`](plan/).

## License

MIT
