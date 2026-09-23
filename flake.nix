{
  description = "nixarchy.flatsnap -- install Flatpak and Snap apps from the Omarchy menu, declaratively";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nix-snapd.url = "github:nix-community/nix-snapd";
    nix-snapd.inputs.nixpkgs.follows = "nixpkgs";
    # Only for checks.module. On nixarchy the module uses nixarchy's own copy
    # (same pin as nixarchy's flake.nix).
    nix-flatpak.url = "github:gmodena/nix-flatpak/v0.7.0";
  };

  outputs = { self, nixpkgs, nix-snapd, nix-flatpak }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAll = nixpkgs.lib.genAttrs systems;
    in
    {
      nixosModules.default = import ./module.nix nix-snapd;

      packages = forAll (system: { });

      checks = forAll (system:
        let pkgs = nixpkgs.legacyPackages.${system};
        in {
          shellcheck = pkgs.runCommand "nixarchy-flatsnap-shellcheck"
            { nativeBuildInputs = [ pkgs.shellcheck ]; }
            ''
              shellcheck ${./bin/nixarchy-flatsnap} ${./bin/nixarchy-flatsnap-reconcile} ${./tests/cli.sh}
              touch "$out"
            '';

          # Offline: every API answer is a fixture in tests/fixtures.
          cli = pkgs.runCommand "nixarchy-flatsnap-cli"
            { nativeBuildInputs = with pkgs; [ bash jq nix ]; }
            ''
              # nix-instantiate wants a writable state dir, and the sandbox has none.
              export HOME=$TMPDIR NIX_STATE_DIR=$TMPDIR/nix-state NIX_REMOTE=local?root=$TMPDIR/nix-root
              cp -r ${./bin} bin; cp -r ${./tests} tests; chmod -R u+w .
              bash tests/cli.sh
              touch "$out"
            '';

          # snapd -- and its setuid snap-confine -- only exists while there is
          # a snap to run or one still to remove. Pure evaluation, no VM.
          module-gating =
            let
              snapdWith = fs: (nixpkgs.lib.nixosSystem {
                inherit system;
                modules = [
                  self.nixosModules.default
                  nix-flatpak.nixosModules.nix-flatpak
                  { boot.isContainer = true; system.stateVersion = "26.05"; programs.nixarchy.flatsnap = fs; }
                ];
              }).config.services.snap.enable;
              lib = nixpkgs.lib;
            in
            assert lib.assertMsg (!snapdWith { }) "snapd on with nothing declared";
            assert lib.assertMsg (snapdWith { snaps = [ { name = "hello-world"; } ]; }) "snapd off with a snap declared";
            assert lib.assertMsg (snapdWith { pendingRemoval = [ "hello-world" ]; }) "snapd off while a removal is pending";
            pkgs.runCommand "nixarchy-flatsnap-gating" { } "touch $out";

          # The declarations merge rather than replace, Flathub survives, and
          # snapd plus the reconciler come up. Installing needs the network,
          # so that part is the manual check in the plan, not this.
          module = pkgs.testers.runNixOSTest {
            name = "nixarchy-flatsnap-module";
            nodes.machine = { pkgs, ... }: {
              imports = [ self.nixosModules.default nix-flatpak.nixosModules.nix-flatpak ];
              # Stand-in for nixarchy's curated catalogue.
              services.flatpak.enable = true;
              services.flatpak.packages = [ { appId = "com.valvesoftware.Steam"; origin = "flathub"; } ];
              programs.nixarchy.flatsnap = {
                flatpaks = [ { appId = "org.gnome.Calculator"; overrides.Context.filesystems = [ "xdg-pictures:ro" ]; } ];
                snaps = [ { name = "hello-world"; } ];
              };
              # nixarchy's desktop provides this; a bare test VM does not.
              xdg.portal = { enable = true; extraPortals = [ pkgs.xdg-desktop-portal-gtk ]; config.common.default = "*"; };
              virtualisation.memorySize = 2048;
            };
            testScript = { nodes, ... }:
              let
                cfg = nodes.machine.services.flatpak;
                ids = map (p: p.appId) cfg.packages;
                lib = nixpkgs.lib;
              in
              assert lib.assertMsg (lib.elem "com.valvesoftware.Steam" ids && lib.elem "org.gnome.Calculator" ids)
                "flatpak packages were replaced, not merged: ''${toString ids}";
              assert lib.assertMsg (lib.any (r: r.name == "flathub") cfg.remotes) "flathub dropped from remotes";
              assert lib.assertMsg (cfg.overrides."org.gnome.Calculator".Context.filesystems == [ "xdg-pictures:ro" ]) "override lost";
              ''
                machine.wait_for_unit("snapd.service")
                machine.succeed("systemctl cat nixarchy-flatsnap-snaps.service")
                machine.succeed("grep -q hello-world $(systemctl show -P ExecStart nixarchy-flatsnap-snaps.service | grep -o '/nix/store/[^ ]*-nixarchy-flatsnap-snaps.json')")
              '';
          };
        });
    };
}
