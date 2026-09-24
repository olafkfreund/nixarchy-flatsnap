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
      # The module and the snap daemon. A host that already imports nix-snapd
      # imports "${inputs.nixarchy-flatsnap}/module.nix" instead: importing
      # nix-snapd twice declares services.snap twice.
      nixosModules.default = { imports = [ ./module.nix nix-snapd.nixosModules.default ]; };

      formatter = forAll (system: nixpkgs.legacyPackages.${system}.nixfmt);

      packages = forAll (system:
        let pkgs = nixpkgs.legacyPackages.${system};
        in rec {
          default = plugin;

          # runCommand and a plain copy: omarchy-plugin-validate refuses ANY
          # symlink inside a plugin folder. The CLI rides along in bin/, where
          # FlatsnapModel.qml finds it; it uses curl, jq and nix from the
          # nixarchy system, as nixarchy-pkg's adapter does.
          plugin = pkgs.runCommand "nixarchy-flatsnap-plugin"
            {
              meta = with pkgs.lib; {
                description = "Omarchy plugin: install Flatpak and Snap apps declaratively on nixarchy";
                homepage = "https://github.com/olafkfreund/nixarchy-flatsnap";
                license = licenses.mit;
                platforms = platforms.linux;
              };
            }
            ''
              mkdir -p "$out/bin"
              cp ${./manifest.json} "$out/manifest.json"
              cp ${./Menu.qml} "$out/Menu.qml"
              cp ${./FlatsnapModel.qml} "$out/FlatsnapModel.qml"
              cp ${./bin/nixarchy-flatsnap} "$out/bin/nixarchy-flatsnap"
              chmod +x "$out/bin/nixarchy-flatsnap"
            '';

          # The same CLI on PATH, with its tools pinned, for a terminal.
          cli = pkgs.writeShellApplication {
            name = "nixarchy-flatsnap";
            runtimeInputs = with pkgs; [ curl jq gawk coreutils gnused gnugrep nix util-linux ];
            text = builtins.readFile ./bin/nixarchy-flatsnap;
            meta = with pkgs.lib; {
              description = "Declare Flatpak and Snap apps for nixarchy from a terminal";
              homepage = "https://github.com/olafkfreund/nixarchy-flatsnap";
              license = licenses.mit;
              platforms = platforms.linux;
              mainProgram = "nixarchy-flatsnap";
            };
          };
        });

      checks = forAll (system:
        let pkgs = nixpkgs.legacyPackages.${system};
        in {
          shellcheck = pkgs.runCommand "nixarchy-flatsnap-shellcheck"
            { nativeBuildInputs = [ pkgs.shellcheck ]; }
            ''
              shellcheck ${./bin/nixarchy-flatsnap} ${./bin/nixarchy-flatsnap-reconcile} ${./tests/cli.sh} \
                ${./tests/model.sh} ${./docs/record.sh}
              touch "$out"
            '';

          # Offline: every API answer is a fixture in tests/fixtures.
          cli = pkgs.runCommand "nixarchy-flatsnap-cli"
            { nativeBuildInputs = with pkgs; [ bash jq nix util-linux ]; }
            ''
              # nix-instantiate wants a writable state dir, and the sandbox has none.
              export HOME=$TMPDIR NIX_STATE_DIR=$TMPDIR/nix-state NIX_REMOTE=local?root=$TMPDIR/nix-root
              cp -r ${./bin} bin; cp -r ${./tests} tests; chmod -R u+w .
              bash tests/cli.sh
              touch "$out"
            '';

          # The manifest is what the shell validates at load; a typo in it is
          # a plugin that silently never appears.
          manifest = pkgs.runCommand "nixarchy-flatsnap-manifest"
            { nativeBuildInputs = [ pkgs.jq ]; }
            ''
              jq -e '.schemaVersion == 1 and .id == "nixarchy.flatsnap"
                     and (.kinds | index("menu")) and .entryPoints.menu == "Menu.qml"' ${./manifest.json} >/dev/null
              touch "$out"
            '';

          # A literal colour survives a theme switch and looks wrong.
          no-hardcoded-colours = pkgs.runCommand "nixarchy-flatsnap-colours" { } ''
            if grep -nE '"#[0-9a-fA-F]{3,8}"|Qt\.rgba|"(red|white|black|yellow|orange)"' ${./Menu.qml} ${./FlatsnapModel.qml}; then
              echo "hardcoded colour above; use a Color.* token" >&2
              exit 1
            fi
            touch "$out"
          '';

          # A fixed multiplier on a font token stops text following the
          # shell's text size (#9). Every size is a Style.font.* token.
          no-text-multiplier = pkgs.runCommand "nixarchy-flatsnap-text-size" { } ''
            if grep -nE 'textScale|uiScale|px\(' ${./Menu.qml} \
              || grep -n 'pixelSize:' ${./Menu.qml} \
                 | grep -vE 'pixelSize: Style\.font\.[A-Za-z]+([;}[:space:]]|$)'; then
              echo "fixed text multiplier above; use a Style.font token" >&2
              exit 1
            fi
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
            # A host that already imports nix-snapd, like nixos_config: the
            # module alone must compose with it, not redeclare it.
            assert lib.assertMsg ((nixpkgs.lib.nixosSystem {
              inherit system;
              modules = [
                nix-snapd.nixosModules.default
                nix-flatpak.nixosModules.nix-flatpak
                ./module.nix
                { boot.isContainer = true; system.stateVersion = "26.05"; programs.nixarchy.flatsnap.snaps = [ { name = "hello-world"; } ]; }
              ];
            }).config.systemd.services.nixarchy-flatsnap-snaps.path != [ ]) "module.nix does not compose with an existing nix-snapd import";
            # nixarchy owns the Install -> Flatpak & Snap row (olafkfreund/nixarchy#914);
            # this module must not add a second one through extraEntries.
            assert lib.assertMsg (!((nixpkgs.lib.nixosSystem {
              inherit system;
              modules = [
                self.nixosModules.default
                nix-flatpak.nixosModules.nix-flatpak
                { options.programs.nixarchy.menu.extraEntries = lib.mkOption { type = lib.types.attrsOf (lib.types.attrsOf lib.types.anything); default = { }; }; }
                { boot.isContainer = true; system.stateVersion = "26.05"; }
              ];
            }).config.programs.nixarchy.menu.extraEntries ? "install.flatsnap")) "the module still adds its own menu row";
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
                # The hardened unit reaches snapd and fails only on the missing
                # network (no store here), never on its own sandbox.
                machine.wait_until_succeeds("systemctl show -P ActiveState nixarchy-flatsnap-snaps.service | grep -Eqx 'active|failed'", timeout=300)
                machine.fail("journalctl -u nixarchy-flatsnap-snaps | grep -Ei 'permission denied|read-only file system|operation not permitted'")
                machine.succeed("journalctl -u nixarchy-flatsnap-snaps | grep -q 'install hello-world'")
                # Measured 1.8 with the hardening; --threshold counts tenths (20 = 2.0).
                machine.succeed("systemd-analyze security --threshold=20 nixarchy-flatsnap-snaps.service")
              '';
          };
        });
    };
}
