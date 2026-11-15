{ lib, pkgs, ... }:
let
  tools = pkgs.callPackage ../../pkgs/sourceTools.nix { };
  notificationIcon =
    pkgs.runCommand "nix-package-search-icon.png"
      {
        nativeBuildInputs = [ pkgs.imagemagick ];
      }
      ''
        magick ${../../assets/images/nixosLogo1.webp} -resize 128x128 PNG:$out
      '';
  packageIndex = tools.packageIndex;
  channels = {
    package-search-refresh = {
      label = "nixos-unstable";
      arguments = "";
      schedule = "daily";
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
        NoNewPrivileges = true;
        PrivateUsers = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = "tmpfs";
        CacheDirectory = "nix-package-search";
        CacheDirectoryMode = "0700";
        BindPaths = [ "%C/nix-package-search" ];
        Environment = [ "XDG_CACHE_HOME=%C" ];
        WorkingDirectory = "%C/nix-package-search";
        UMask = "0077";
        MemoryMax = "6G";
        SystemCallFilter = [ "~@mount" ];
      };
    }) channels)
    // (lib.mapAttrs' (
      name: channel:
      lib.nameValuePair "${name}-notify" {
        Unit = {
          Description = "Manually refresh ${channel.label} and notify on completion";
        };
        Service = {
          Type = "oneshot";
          TimeoutStartSec = "16min";
          # A missing notification server must not fail a successful refresh.
          ExecStart = "-${pkgs.writeShellScript "${name}-notify" ''
            # Wait for the shared refresh, including an already running timer job.
            if ${pkgs.systemd}/bin/systemctl --user start ${name}.service; then
              exec ${lib.getExe pkgs.libnotify} --app-name=nixctl --icon=${notificationIcon} \
                "Package index updated" "${channel.label} is ready to search."
            else
              exec ${lib.getExe pkgs.libnotify} --app-name=nixctl --urgency=critical --icon=${notificationIcon} \
                "Package index refresh failed" \
                "${channel.label}: run nixctl search --logs${channel.arguments} for details."
            fi
          ''}";
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
