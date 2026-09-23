{
  description = "nixarchy.flatsnap -- install Flatpak and Snap apps from the Omarchy menu, declaratively";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nix-snapd.url = "github:nix-community/nix-snapd";
    nix-snapd.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { self, nixpkgs, nix-snapd }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAll = nixpkgs.lib.genAttrs systems;
    in
    {
      nixosModules.default = { imports = [ nix-snapd.nixosModules.default ]; };

      packages = forAll (system: { });

      checks = forAll (system:
        let pkgs = nixpkgs.legacyPackages.${system};
        in {
          shellcheck = pkgs.runCommand "nixarchy-flatsnap-shellcheck"
            { nativeBuildInputs = [ pkgs.shellcheck ]; }
            ''
              shellcheck ${./bin/nixarchy-flatsnap} ${./tests/cli.sh}
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
        });
    };
}
