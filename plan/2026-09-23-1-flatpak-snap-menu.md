---
status: approved
issue: 1
spec: spec/2026-09-23-1-flatpak-snap-menu.md
---

# Plan: install Flatpak and Snap apps from the Omarchy menu

## Approved decisions (self-contained)

- **Snap runtime:** `nix-community/nix-snapd`, as a pinned flake input
  (`inputs.nixpkgs.follows = "nixpkgs"`). `services.snap.enable` is set only
  when at least one snap is declared.
- **Snaps are declarative:** a oneshot unit, `nixarchy-flatsnap-snaps.service`, reconciles
  the declared list. It removes only the snaps listed in
  `/var/lib/nixarchy-flatsnap/managed`, never a snap installed by hand.
- **The state file** is `~/.config/nixarchy/flatsnap.nix`. It is generated and owned
  by the CLI, regenerated whole, and guarded by backup → write → `nix-instantiate --parse` → restore.
- **Entry point:** the Omarchy menu row *Install → Flatpak & Snap* runs
  `nixarchy-plugin nixarchy.flatsnap` and is gated by `when = nixarchy-plugin --enabled nixarchy.flatsnap`.
  There is no new keybinding.
- **Flatpaks:** system-wide only and from Flathub only. The module appends to
  `services.flatpak.packages`, sets `services.flatpak.overrides.<appId>` per
  entry, and **never sets `remotes`**.
- **Input handling:** `resolve` accepts Flathub app URLs, Flathub
  `.flatpakref` URLs, Snapcraft URLs, pasted `flatpak install`/`snap install`
  lines, a reverse-DNS ID, or a bare snap name (both stores are looked up and the user picks one).
  Everything else is refused. The ID grammars are:
  - Flatpak: `^[A-Za-z_][A-Za-z0-9_-]*(\.[A-Za-z_][A-Za-z0-9_-]*){2,}$`
  - Snap: `^[a-z0-9][a-z0-9-]{0,39}$`

  Only validated IDs reach curl, Nix or argv. curl runs with `--proto =https
  --max-time 10 --max-filesize 2M`.
- **APIs:**
  - Flathub `GET /api/v2/summary/<id>`, `GET /api/v2/appstream/<id>` and
    `POST /api/v2/search`.
  - Snap `GET /v2/snaps/info/<name>` and `GET /v2/snaps/find?q=`, both with
    `Snap-Device-Series: 16`.
- **Apply:** `NH_ELEVATION_STRATEGY=pkexec nixarchy-apply --yes --no-preview`,
  streamed as JSON lines (the pattern in `nixarchy-pkg/bin/nixarchy-pkg:1187-1230`).
  Before applying, it checks that `programs.nixarchy.flatsnap` exists in the
  flake and prints the exact import line if it does not.
- **UI:** a full-screen QML card with theme tokens only, `Text.PlainText`
  everywhere, and these keys:
  - `Enter`: resolve, then queue
  - `Ctrl+F` / `Ctrl+S`: search Flathub / the Snap Store
  - `j` `k` and the arrow keys: move through lists
  - `c`: cycle the snap channel
  - `x` `x`: turn on classic confinement (the second `x` confirms)
  - `p`: Flatpak overrides
  - `Tab`: switch between Add and Declared
  - `d` then `y`: remove
  - `a`: apply
  - `Esc`: back, then close

  It shows three warnings:
  - classic snaps are unsandboxed;
  - snap confinement on NixOS is weakened (no AppArmor);
  - the Flatpaks that `uninstallUnmanaged` would remove.
- **nixarchy patch:** a separate PR on `olafkfreund/nixarchy`. It adds `flatsnap` to
  the part loop in `nixarchy-apply` and adds the `install.flatsnap` row to `modules/apps.nix`.
- **Pages:** `docs/` is Jekyll, copied from `nixarchy-pkg/docs/{_config.yml,_layouts,_includes,assets}`
  (that site already carries the nixarchy look). It is served from `main:/docs` at
  `https://olafkfreund.github.io/nixarchy-flatsnap/`.

## Deviations during implementation

- **Step 4, `pendingRemoval`.** When the last snap is un-declared, turning
  snapd off in the same rebuild also removes the reconciler, so the snap would
  never be removed. Now `rm snap X` also adds X to
  `programs.nixarchy.flatsnap.pendingRemoval` (an internal option).
  - snapd stays on while `snaps != [] || pendingRemoval != []`.
  - The CLI prunes names that `snap list` no longer shows at its next write, so
    snapd turns off on the apply after that.
  - The removal itself is still decided by `managed` alone.
- **Step 4, nix-flatpak is required, not imported.** Defining
  `services.flatpak.packages` needs nix-flatpak's option declarations, even
  under `mkIf false`. nixarchy imports nix-flatpak, and a second import from this
  flake would declare the options twice. So the module relies on the host's copy,
  and `nix-flatpak` (v0.7.0, the same pin as nixarchy) is a flake input used only by
  the checks.
- **Step 4, extra check.** `checks.module-gating` evaluates that snapd is off
  with nothing declared, and on with a snap or a pending removal.
- **Step 4, `TimeoutStartSec = 30min`** on the reconciler. A oneshot has no start
  timeout by default.
- **Step 6, `omarchy plugin validate`.** `omarchy` is not available in the build
  sandbox, so it runs on the host. The flake keeps the manifest check, as
  nixarchy-pkg does.

- **Step 6, overrides field.** A single-line field of space-separated
  `Section.key=value` entries, not one per line. A single-line field is what the
  shell's `TextField` gives, and the CLI validates each entry anyway.
- **Step 6, host check: done (2026-09-23).** The first attempt copied the
  plugin in file by file (`cp -r` + `chmod -R`). That caused ten full shell
  reloads in one second, and the shell wedged at 100% CPU until the folder was
  removed. The retry prepared the folder outside `plugins/` and moved it in with
  one `mv`: one reload, about 12 s busy, then healthy. So the cause was the
  reload burst, not the plugin (compare nixarchy's open issue on shell.json saves
  rebuilding every panel).

  Live, by keyboard (`wtype`), with screenshots:
  1. Pasting a Flathub URL and pressing Enter showed Calculator's card with
     its real permissions.
  2. Enter queued it, and `flatsnap.nix` was written.
  3. Tab showed it under Declared.
  4. For `snap install hello-world`, `c c` moved the channel stable → beta, the
     no-AppArmor warning was shown, and `x` armed the classic confirmation.
  5. Esc left the card without queuing.
  6. `d` then `y` removed the Flatpak, and the file was back to empty lists.

  The test file was deleted afterwards. **Dev installs: stage outside
  `plugins/` and `mv` in.**

- **Step 10, `snap remove --purge`.** On razer, removal failed. snapd's
  automatic pre-removal snapshot runs `sudo`, which fails under NixOS PAM. The
  reconciler now removes with `--purge`: the data is deleted as before, only
  the (impossible) snapshot is skipped. The README says so, and the test stub
  refuses a remove without `--purge`.

## Steps

Each step is one commit on `feat/1-flatpak-snap-menu`.

1. **`flake.nix` + `flake.lock`:** add the inputs `nixpkgs` (nixos-unstable) and `nix-snapd`
   (follows nixpkgs). Stub out the outputs `packages.<sys>.{default,cli}`, `nixosModules.default`
   and `checks.<sys>`, following the `forAll` pattern of `nixarchy-pkg/flake.nix`.
   → Verify with `nix flake show` and `nix flake lock`.
2. **`bin/nixarchy-flatsnap` (the classification and validation part):** add
   `resolve` in offline mode (`NIXARCHY_FLATSNAP_OFFLINE=<fixture dir>`
   serves the API responses from files).
   → Verify with `tests/cli.sh`, which covers every row of the input table plus
   the hostile inputs `$(id)`, `"; rm -rf ~`, `${x}`, `http://flathub.org/apps/a.b.c`,
   `https://evil.example/apps/a.b.c`, and a non-Flathub `.flatpakref`, all of which must be refused.
3. **`bin/nixarchy-flatsnap` (online, search, list, add, rm):** add the real curl
   calls and the file generator.
   → Verify with `tests/cli.sh`: `add` then `rm` round-trips, every intermediate
   file passes `nix-instantiate --parse`, and an injected parse failure restores
   the backup. Then run one manual online check, `nixarchy-flatsnap resolve https://flathub.org/apps/org.gnome.Calculator`.
4. **`module.nix`:** add the options, the Flatpak mapping, `services.snap`, the reconciler
   script (`writeShellApplication`, JSON list in the store, `managed` state
   file), and the unit.
   → Verify with `checks.module`, a NixOS VM test that declares one Flatpak and one snap
   next to a stand-in curated `services.flatpak.packages` entry. It asserts that
   both packages are present, that Flathub is in `remotes`, that `snapd.service` is active, and that
   `nixarchy-flatsnap-snaps.service` is loaded. The network-dependent install is not tested in CI.
5. **`bin/nixarchy-flatsnap apply`:** add the option-exists check and the streamed
   `nixarchy-apply` call.
   → Verify with `tests/cli.sh`, using a stub `nixarchy-apply` on PATH, that JSON lines
   come out and that a missing module gives the import-line message.
6. **`manifest.json`, `Menu.qml`, `FlatsnapModel.qml`:** add the panel per the UI decisions,
   and the plugin package (`runCommand` with a plain copy and no symlinks).
   → Verify with `checks.plugin` (`omarchy plugin validate` on the built folder) and
   `checks.no-hardcoded-colours` (the grep from nixarchy-pkg). Then a manual check on the host:
   summon the panel, paste a URL, then queue, cycle the channel, and remove, all by keyboard.
7. **`README.md`:** add install instructions (flake input, NixOS import, Home Manager
   `programs.nixarchy.plugins.flatsnap.src`, `home.packages` cli), the keys,
   and a security section on nix-snapd's confinement and classic snaps.
   → Verify by rendering it on GitHub.
8. **`docs/`:** copy `_config.yml` (retitled, with `baseurl: /nixarchy-flatsnap`),
   `_layouts`, `_includes` and `assets` from nixarchy-pkg, then write `index.md`
   from the README plus a screenshot. Enable Pages from `main:/docs` after the merge.
   → Verify that `jekyll build` succeeds locally (`nix run nixpkgs#jekyll -- build -s docs`)
   and that the URL returns 200 with the nixarchy stylesheet after the merge.
9. **nixarchy PR (in the other repo):** open an issue there, then make the one-word
   `for part in … flatsnap` change and add the `install.flatsnap` row.
   → Verify with nixarchy's own `nix flake check` (`tests/menu-verbs.nix` covers the menu rows), and
   check that `nixarchy-apply` with no `flatsnap.nix` behaves as before.
10. **End-to-end on this host:** wire the flake input and the module into the user's
    flake, then in the panel:
    1. queue `org.gnome.Calculator` and `hello-world`, then apply;
    2. check that both run;
    3. un-declare both, then apply;
    4. check that both are gone and that a snap installed by hand beforehand is still there.
    → Record the result in the PR.
11. **PR:** open it with links to the intent, spec and plan, and the verification evidence.

## Tests

```bash
nix flake check                                 # cli, module VM test, plugin validate, colours, shellcheck
bash tests/cli.sh                               # fast loop, offline fixtures
nix run nixpkgs#jekyll -- build -s docs -d /tmp/site
```

These all pass with no warnings. The VM test takes about 3 minutes.

## Rollback

- **This repo:** revert the merge commit. Users drop the input and the import.
- **On a host:** remove the import and `~/.config/nixarchy/flatsnap.nix`, then apply.
  - Flatpaks installed through this path stay unless `uninstallUnmanaged` is on,
    because nix-flatpak only removes what it manages.
  - Snaps stay installed but snapd stops. To wipe them, run `snap remove` for each
    snap first, while the service still runs.
  - `nixos-rebuild switch --rollback` restores which apps were declared, not their versions.
- **nixarchy PR:** revert it. With no `flatsnap.nix` present, the loop change
  is a no-op, so reverting only removes the menu row.
