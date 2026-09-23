**Findings**

1. [Problem framing](/mnt/data/Source-home/GitHub/nixarchy-flatsnap/intent/2026-09-23-1-flatpak-snap-menu.md:46) overclaims rollback behavior. Flatpaks/Snaps live outside the Nix store; rollback can restore declarations, but exact app versions are mutable unless Flatpak commits are pinned, and Snap channels are inherently moving.

2. [Open Q1](/mnt/data/Source-home/GitHub/nixarchy-flatsnap/intent/2026-09-23-1-flatpak-snap-menu.md:88): recommend `nix-community/nix-snapd`, pinned as a flake input. Do not write a local snapd module unless this project wants to own `/snap`, snapd units, AppArmor integration, and breakage. If that dependency feels too large, make v1 Flatpak-only.

3. [Open Q2](/mnt/data/Source-home/GitHub/nixarchy-flatsnap/intent/2026-09-23-1-flatpak-snap-menu.md:93): “tracked but imperative” contradicts the stated intent. Either add a nixarchy-owned declarative Snap reconciler, or remove Snap from v1. If included, show the exact install/remove diff before apply.

4. [Open Q3](/mnt/data/Source-home/GitHub/nixarchy-flatsnap/intent/2026-09-23-1-flatpak-snap-menu.md:97): use a new generated `~/.config/nixarchy/flatsnap.nix` copied/imported by `nixarchy-apply`. Avoid `advanced.nix`; mixing generated store state with hand-written config is asking for ugly merges.

5. [Open Q4](/mnt/data/Source-home/GitHub/nixarchy-flatsnap/intent/2026-09-23-1-flatpak-snap-menu.md:100): put it under `Install` first. A dedicated chord is optional later; the intent should not require another global binding for v1.

6. [Open Q5](/mnt/data/Source-home/GitHub/nixarchy-flatsnap/intent/2026-09-23-1-flatpak-snap-menu.md:102): system-wide only for v1. Home Manager `nix-flatpak` has separate user-target semantics, including `uninstallUnmanaged`, and doubles the edge cases.

7. [Flatpak merge constraint](/mnt/data/Source-home/GitHub/nixarchy-flatsnap/intent/2026-09-23-1-flatpak-snap-menu.md:68) is directionally right. For arbitrary Flatpaks, append to `services.flatpak.packages`; for extra remotes, preserve Flathub explicitly or use `lib.mkOptionDefault`, because declaring `services.flatpak.remotes` can replace nix-flatpak’s default remote.

8. Missing risks to add: pasted URLs must be `https` only with size/time limits; `.flatpakref` needs a `sha256` to stay pure; permission overrides can overwrite/prune user override files; Snap `classic` confinement is effectively unsandboxed and should require explicit confirmation; `uninstallUnmanaged = true` can delete existing system Flatpaks/remotes not in the generated config.

Sources checked: NixOS live options, `nix-flatpak` README, `nix-community/nix-snapd` README/NixOS wiki, and Snap classic confinement docs. No files changed.
