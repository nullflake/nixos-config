{ lib, pkgs, ... }:
let
  python = pkgs.python3.withPackages (ps: [ ps.wcwidth ]);
  notificationIcon =
    pkgs.runCommand "nix-package-search-icon.png"
      {
        nativeBuildInputs = [ pkgs.imagemagick ];
      }
      ''
        magick ${../../assets/images/nixosLogo1.webp} -resize 128x128 PNG:$out
      '';
  packageIndex = pkgs.writeShellApplication {
    name = "package-index";
    runtimeInputs = [
      python
      pkgs.brotli
    ];
    text = ''
      exec python3 ${../../scripts/packageIndex.py} "$@"
    '';
  };
  channels = {
    package-search-refresh = {
      label = "nixos-unstable";
      arguments = "";
      schedule = "hourly";
    };
    package-search-refresh-stable = {
      label = "nixos-26.05";
      arguments = " --stable";
      schedule = "daily";
    };
  };
in
{
  home.packages = [ packageIndex ];

  systemd.user.services =
    (lib.mapAttrs (_: channel: {
      Unit.Description = "Refresh the local ${channel.label} package index";
      Service = {
        Type = "oneshot";
        ExecStart = "${lib.getExe packageIndex} refresh${channel.arguments}";
        TimeoutStartSec = "15min";
        Nice = 10;
        IOSchedulingClass = "idle";
      };
    }) channels)
    // (lib.mapAttrs' (
      name: channel:
      lib.nameValuePair "${name}-notify" {
        Unit = {
          Description = "Manually refresh ${channel.label} and notify on success";
          Requires = [ "${name}.service" ];
          After = [ "${name}.service" ];
        };
        Service = {
          Type = "oneshot";
          # A missing notification server must not fail a successful refresh.
          ExecStart = "-${lib.getExe pkgs.libnotify} --app-name=nixctl --icon=${notificationIcon} \"Package index updated\" \"${channel.label} is ready to search.\"";
        };
      }
    ) channels);

  systemd.user.timers = lib.mapAttrs (_: channel: {
    Unit.Description = "Refresh the ${channel.label} package index ${channel.schedule}";
    Timer = {
      OnStartupSec = "2min";
      OnCalendar = channel.schedule;
      Persistent = true;
      RandomizedDelaySec = "5min";
    };
    Install.WantedBy = [ "timers.target" ];
  }) channels;
}
