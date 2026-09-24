# programs.nixarchy.flatsnap: the Flatpaks and Snaps declared in
# ~/.config/nixarchy/flatsnap.nix, which nixarchy-apply copies into the flake.
#
# services.flatpak.packages/overrides come from nix-flatpak, which nixarchy
# already imports. This module does not import it again: two copies from two
# flake inputs are two declarations of the same options, and eval fails.
#
# nix-snapd is not imported here either, for the same reason: a host that
# already imports it (nixos_config does, for every host) would get
# services.snap declared twice. flake.nix's `default` is this plus
# nix-snapd; a host with its own nix-snapd imports this file by path. The
# reconciler uses the host's own snap CLI, so it always matches the daemon
# that is actually running.
{ config, lib, pkgs, ... }:
let
  cfg = config.programs.nixarchy.flatsnap;

  # Same grammars as bin/nixarchy-flatsnap; a hand edit gets checked too.
  fpId = lib.types.strMatching "[A-Za-z_][A-Za-z0-9_-]*(\\.[A-Za-z_][A-Za-z0-9_-]*){2,}";
  snapName = lib.types.strMatching "[a-z0-9][a-z0-9-]{0,39}";

  # Snapd stays on while something is still waiting to be removed: turning
  # it off in the same rebuild that un-declares the last snap would take the
  # reconciler with it, and the snap would never go.
  snapdOn = cfg.snaps != [ ] || cfg.pendingRemoval != [ ];

  plan = pkgs.writeText "nixarchy-flatsnap-snaps.json" (builtins.toJSON { inherit (cfg) snaps; });

  reconcile = pkgs.writeShellApplication {
    name = "nixarchy-flatsnap-reconcile";
    # No snap here: it comes from /run/current-system/sw via the unit's path.
    runtimeInputs = [ pkgs.jq pkgs.gawk pkgs.coreutils pkgs.gnugrep ];
    text = builtins.readFile ./bin/nixarchy-flatsnap-reconcile;
  };
in
{
  options.programs.nixarchy.flatsnap = {
    flatpaks = lib.mkOption {
      type = lib.types.listOf (lib.types.submodule {
        options = {
          appId = lib.mkOption { type = fpId; description = "Flathub app ID."; };
          overrides = lib.mkOption {
            type = with lib.types; attrsOf (attrsOf (either str (listOf str)));
            default = { };
            description = "nix-flatpak overrides for this app, e.g. { Context.filesystems = [ \"xdg-pictures:ro\" ]; }.";
          };
        };
      });
      default = [ ];
      description = "Flatpaks installed system-wide from Flathub.";
    };

    snaps = lib.mkOption {
      type = lib.types.listOf (lib.types.submodule {
        options = {
          name = lib.mkOption { type = snapName; };
          channel = lib.mkOption {
            type = lib.types.enum [ "stable" "candidate" "beta" "edge" ];
            default = "stable";
          };
          classic = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "Classic confinement: the snap runs without a sandbox.";
          };
        };
      });
      default = [ ];
      description = ''
        Snaps kept installed by nixarchy-flatsnap-snaps.service. Snap
        confinement on NixOS (nix-snapd) has no AppArmor and is weaker than
        on Ubuntu.
      '';
    };

    pendingRemoval = lib.mkOption {
      type = lib.types.listOf snapName;
      default = [ ];
      internal = true;
      description = "Un-declared snaps not yet removed. Written and pruned by the CLI.";
    };
  };

  config = lib.mkMerge [
    (lib.mkIf (cfg.flatpaks != [ ]) {
      services.flatpak.enable = true;
      # A list option: this merges with nixarchy's curated flatpaks. `remotes`
      # is deliberately never set -- assigning it replaces nix-flatpak's
      # default and would drop Flathub (see nixarchy modules/flatpaks.nix).
      services.flatpak.packages = map (f: { inherit (f) appId; origin = "flathub"; }) cfg.flatpaks;
      services.flatpak.overrides = lib.listToAttrs (map (f: lib.nameValuePair f.appId f.overrides)
        (lib.filter (f: f.overrides != { }) cfg.flatpaks));
    })

    (lib.mkIf snapdOn {
      services.snap.enable = true;

      systemd.services.nixarchy-flatsnap-snaps = {
        description = "Install and remove the snaps declared in flatsnap.nix";
        requires = [ "snapd.service" ];
        after = [ "snapd.service" "network-online.target" ];
        wants = [ "network-online.target" ];
        wantedBy = [ "multi-user.target" ];
        path = [ "/run/current-system/sw" ];
        # ExecStart names the plan's store path, so a changed list is a changed
        # unit, and switch-to-configuration restarts it. No restartTriggers needed.
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          StateDirectory = "nixarchy-flatsnap";
          # A oneshot has no start timeout by default; a hung download would
          # sit there forever. Big snaps are slow, so this is generous.
          TimeoutStartSec = "30min";
          ExecStart = "${lib.getExe reconcile} ${plan}";

          # Hardening. This unit is only a snap *client*: snapd.service does
          # the downloads, mounts and snap-confine. snapd authorizes the
          # client by its peer UID on /run/snapd.socket, so it stays root,
          # but needs no capabilities and writes only its StateDirectory.
          NoNewPrivileges = true; # never `snap run`, so never snap-confine
          CapabilityBoundingSet = "";
          AmbientCapabilities = "";
          ProtectSystem = "strict"; # StateDirectory stays writable
          # tmpfs, not true: the client opens /root/.snap/auth.json, and a
          # hidden /root (EACCES) fails it where an empty one (ENOENT) means
          # anonymous, as the store has always been used here.
          ProtectHome = "tmpfs";
          PrivateTmp = true;
          PrivateDevices = true;
          ProtectKernelTunables = true;
          ProtectKernelModules = true;
          ProtectKernelLogs = true;
          ProtectControlGroups = true;
          ProtectClock = true;
          ProtectHostname = true;
          RestrictAddressFamilies = [ "AF_UNIX" ]; # snapd's socket; the daemon does the network
          RestrictNamespaces = true;
          LockPersonality = true;
          RestrictRealtime = true;
          RestrictSUIDSGID = true;
          MemoryDenyWriteExecute = true;
          SystemCallArchitectures = "native";
          SystemCallFilter = [ "@system-service" ];
          UMask = "0077";
        };
      };
    })
  ];
}
