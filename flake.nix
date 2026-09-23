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

      checks = forAll (system: { });
    };
}
