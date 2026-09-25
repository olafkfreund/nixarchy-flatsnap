# nixarchy-flatsnap

Install **Flatpak** and **Snap** apps from the Omarchy menu on
[nixarchy](https://github.com/olafkfreund/nixarchy) (Omarchy on NixOS). You paste
a link or an ID, check what the app can reach, queue it, and apply. Everything
works from the keyboard, and everything is declarative.

Some software is only current as a Flatpak or a Snap. nixarchy already
declares Flatpaks for a curated handful. This plugin covers the rest, without
falling back to `flatpak install` in a terminal and hoping the next rebuild
keeps it.

![Pasting a Flathub link for GNOME Calculator into the Flatpak & Snap panel: its card shows the publisher, license and sandbox permissions, and Enter queues it](https://olafkfreund.github.io/nixarchy-flatsnap/img/flatsnap-flatpak.gif)

A real session on a nixarchy laptop. The Snap search, the classic
confirmation, and applying (build log shortened) are on
[the site](https://olafkfreund.github.io/nixarchy-flatsnap/).

## What you get

| Piece | What it does |
|---|---|
| **Panel** (`nixarchy.flatsnap`) | *Install → Flatpak & Snap* in the Omarchy menu. Paste, look up, queue, apply. |
| **`nixarchy-flatsnap`** | The CLI behind the panel: `resolve`, `search`, `list`, `add`, `rm`, `preflight`, `apply`, `apply-status`, `apply-log`. JSON out. |
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
| `j` `k` / `↓` `↑` | move; on a card or the build log, scroll |
| `PgUp` `PgDn` | scroll a card or the build log by a page |
| `/` | put the cursor back in the field |
| `Enter` | on a result: open it; on a card: queue it |
| `c` | cycle through the channels this Snap publishes: stable → candidate → beta → edge |
| `x` `x` | switch a Snap to classic confinement (two presses: it removes the sandbox) |
| `p` | Flatpak overrides, e.g. `Context.filesystems=xdg-pictures:ro`; several separated by spaces; a section may contain spaces, e.g. `Session Bus Policy.org.freedesktop.Flatpak=talk` (queuing with overrides takes a second `Enter`) |
| `Enter` `Enter` | queue a classic Snap or a Flatpak with overrides: the first `Enter` says what leaves the sandbox |
| `Tab` | switch between *Add* and *Declared* |
| `d` then `y` | un-declare the selected app |
| `a` then `a` | apply: the first `a` checks `flatsnap.nix` and lists what changes since the last apply, the second runs `nixarchy-apply` with the build log streaming into the panel |
| `l` | show the build log again (after `Esc`, or after closing and reopening the panel). Scroll up to read back; it stops following the build until you scroll back to the end |
| `Esc` | one step back; closes from the top. During a build it hides the log and the build carries on |

Nothing is installed until you press `a` twice. Apply builds only what this
tool writes: a `flatsnap.nix` edited outside its shape, or with an entry
`add` would refuse, is refused before anything is built. The file is then
rewritten from what was checked, so anything else in it is dropped. Comments
you added by hand are dropped too.

The build runs in the user unit `nixarchy-rebuild`, the one
`nixarchy-apply --detach` uses, not inside the shell. Restarting or
closing the shell does not stop it. When you reopen the panel it shows the
running build, or shows once how a build you started ended. While any
rebuild runs, including one started from a terminal, a second apply is
refused, and queuing and removing wait. To follow it from a terminal, run
`nixarchy-flatsnap apply-log --follow`. `nixarchy-flatsnap apply-status`
reports its state, as `nixarchy-apply --status --json` gives it.

flatsnap starts that unit itself rather than through `--detach`, and checks
the file again inside it under its own lock. The reason is that `--detach`
does not yet pass on the hash of what was checked
([olafkfreund/nixarchy#986](https://github.com/olafkfreund/nixarchy/issues/986)).

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
- nixarchy's `nixarchy-apply` must copy `flatsnap.nix` into the flake. That lands with
  [olafkfreund/nixarchy#906](https://github.com/olafkfreund/nixarchy/pull/906), and
  `nixarchy-flatsnap preflight` tells you if yours does not do it yet.
- nixarchy at commit `d3f2cef` or later. That commit brings `/etc/nixarchy/flake`
  ([olafkfreund/nixarchy#969](https://github.com/olafkfreund/nixarchy/pull/969)),
  which names the flake apply rebuilds, and `nixarchy-apply --status --json` / `--log`
  ([olafkfreund/nixarchy#981](https://github.com/olafkfreund/nixarchy/pull/981)).
  On an older nixarchy, apply stops at once with "flatsnap needs nixarchy
  d3f2cef or later". It never guesses the flake. Update the nixarchy input
  and rebuild.
- The *Install → Flatpak & Snap* menu row is nixarchy's own
  ([olafkfreund/nixarchy#914](https://github.com/olafkfreund/nixarchy/pull/914)),
  which also ships this plugin by default. On nixarchy you need none of the
  install steps above.
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
  and are marked in red. Queuing one takes a second `Enter` too, whether you
  chose classic or the store publishes the Snap that way.
- **Verified publishers are labelled, not required.** The card says whether
  Flathub or the Snap Store verified the publisher (for Flathub, by which
  website or login), and search results say `verified` or `unverified`. Most
  apps are unverified; it is a fact to weigh, not a block. When the store
  could not be asked, the card says `verification UNKNOWN` in red.
- **Unknown permissions are not "none".** If Flathub's permission lookup fails,
  the card says `permissions: UNKNOWN` in red instead of an empty list.
- **snapd is off unless you need it.** The daemon and its setuid helper exist only
  while at least one Snap is declared, or one is still waiting to be removed.
- **Flatpak permissions are shown before you queue.** Overrides only widen or
  narrow what you type, and nix-flatpak keeps any `flatpak override` you set
  yourself. Some overrides take the app out of its sandbox altogether; see
  [Overrides that escape the sandbox](#overrides-that-escape-the-sandbox).
- **Removal is conservative.** The reconciler removes only Snaps it installed.
  A Snap you installed by hand is never touched. Flatpaks follow nixarchy's
  `flatpaks.uninstallUnmanaged`. If that is on, `a` lists what the apply would
  remove and asks for a second `a`.

**Removing a Snap deletes its data without a snapshot.** snapd normally saves a
snapshot of the data when a snap is removed. On NixOS that step fails (it runs
`sudo` under PAM), so the reconciler removes with `--purge`. The data would be
deleted either way; the snapshot backup is what you give up. Copy anything you
want to keep out of `~/snap/<name>` before un-declaring it. The panel says so
when you press `d` on a Snap.

### Overrides that escape the sandbox

Every override takes a second `Enter`. These ones are named in red with what
they grant, because they leave little of the sandbox (the list is
`ESCAPES_JSON` in `bin/nixarchy-flatsnap`). A `:ro`, `:rw` or `:create`
suffix does not change the match, and a subfolder such as `~/Games` is not on
the list.

| Override | Grants |
|---|---|
| `Context.filesystems=host`, `host-os`, `host-etc` | the host filesystem |
| `Context.filesystems=home`, `~` | your whole home folder |
| `Context.sockets=session-bus` | the whole session bus, which can run commands outside the sandbox |
| `Context.sockets=system-bus` | the whole system bus |
| `Context.sockets=ssh-auth` | your SSH agent and its keys |
| `Context.sockets=gpg-agent` | your GPG agent and its keys |
| `Context.devices=all` | every device, including cameras and input |
| `Session Bus Policy.org.freedesktop.Flatpak=talk` or `own` | running commands outside the sandbox |
| `System Bus Policy.<any name>=talk` or `own` | talking to system services |

The card also checks the app's own permissions against this list. Matches
are listed under **escapes its sandbox**, each with what it grants. That is
a label, not a second `Enter`, and most popular apps have at least one
(often `devices=all` or `filesystems=host`). Bus access is shown as
`talk`/`own` lines, and a name ending in `.*` counts as every name under it.

## Rollback

Un-declare the app and apply. A NixOS rollback restores which apps are
**declared**, not their versions: Flatpaks and Snaps live outside the Nix store.

## Development

```bash
bash tests/cli.sh                     # offline tests (fixtures, no network)
bash tests/model.sh                   # panel model rules; needs a Wayland session, draws nothing
nix flake check                       # + shellcheck, module VM test, gating, manifest, colours
```

The design record is in [`intent/`](intent/), [`spec/`](spec/) and [`plan/`](plan/).

## License

MIT
