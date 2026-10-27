{
  config,
  lib,
  pkgs,
  username,
  ...
}:

let
  cfg = config.modules.backup;
  metadataNames = [
    ".backup-manifest.json"
    ".backup-complete"
    ".backup-owner"
  ];

  settings = pkgs.writeText "usb-backup.json" (
    builtins.toJSON {
      inherit (cfg)
        label
        paths
        unmountedPaths
        containerPaths
        ;
      home = config.users.users.${username}.home;
      destination = "${config.networking.hostName}/${username}";
      legacyDestination = "backups/${config.networking.hostName}/${username}";
      timezone = if config.time.timeZone == null then "UTC" else config.time.timeZone;
    }
  );

  backup = pkgs.writeShellApplication {
    name = "usb-backup";
    runtimeInputs = [
      pkgs.python3
      pkgs.util-linux
      pkgs.libnotify
      pkgs.coreutils
    ];
    text = ''
      export PYTHONTZPATH=${pkgs.tzdata}/share/zoneinfo
      exec python3 ${../../scripts/backup.py} --config ${settings} "$@"
    '';
  };
in
{
  options.modules.backup = {
    enable = lib.mkEnableOption "unencrypted USB backups";

    label = lib.mkOption {
      type = lib.types.str;
      default = "Backup";
      description = "Exact, case-sensitive filesystem label of the backup volume.";
    };

    paths = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Distinct, non-overlapping files and directories to back up, relative to the user's home.";
    };

    unmountedPaths = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Home-relative mountpoints that must remain unmounted while backing up.";
    };

    containerPaths = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Selected home-relative encrypted container files that must not be loop-mounted.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.label != "" && cfg.paths != [ ];
        message = "modules.backup requires a nonempty label and at least one path.";
      }
      {
        assertion = lib.all (
          path:
          path != ""
          && !(lib.hasPrefix "/" path)
          && lib.all (part: part != "" && part != "." && part != "..") (lib.splitString "/" path)
          && !(lib.elem (builtins.head (lib.splitString "/" path)) metadataNames)
        ) (cfg.paths ++ cfg.unmountedPaths ++ cfg.containerPaths);
        message = "modules.backup paths must be relative to home without empty, '.' or '..' components or reserved metadata roots.";
      }
      {
        assertion =
          lib.length cfg.paths == lib.length (lib.unique cfg.paths)
          && lib.all (parent: lib.all (child: !(lib.hasPrefix "${parent}/" child)) cfg.paths) cfg.paths;
        message = "modules.backup.paths must not contain duplicates or nested selections.";
      }
      {
        assertion = lib.all (path: lib.elem path cfg.paths) cfg.containerPaths;
        message = "modules.backup.containerPaths must also be selected in modules.backup.paths.";
      }
    ];

    environment.systemPackages = [ backup ];

    /*
      udiskie mounts removable media in the desktop session. Polling also
      handles media that was already connected before the session started.
    */
    systemd.user.timers.usb-backup = {
      description = "Check for the backup USB volume";
      wantedBy = [ "timers.target" ];
      unitConfig.ConditionUser = username;
      timerConfig = {
        OnStartupSec = "15s";
        OnUnitInactiveSec = "30s";
        AccuracySec = "5s";
      };
    };

    systemd.user.services.usb-backup = {
      description = "Back up selected home files to USB";
      unitConfig.ConditionUser = username;
      serviceConfig = {
        Type = "oneshot";
        ExecStart = lib.getExe backup;
        StateDirectory = "usb-backup";
        StateDirectoryMode = "0700";
        UMask = "0077";
        TimeoutStartSec = "30min";
        Nice = 10;
        IOSchedulingClass = "idle";
        NoNewPrivileges = true;
        RestrictSUIDSGID = true;
        LockPersonality = true;
        RestrictAddressFamilies = [ "AF_UNIX" ];
      };
    };
  };
}
