{ lib, pkgs, ... }:
let
  tools = pkgs.callPackage ../../pkgs/nixTools.nix { };
  packageIndex = tools.packageIndex;
  channels = {
    "package-search-refresh@" = {
      label = "nixos-unstable";
      arguments = "";
    };
    "package-search-refresh-stable@" = {
      label = "nixos-26.05";
      arguments = " --stable";
    };
  };
in
{
  home.packages = [ packageIndex ];

  systemd.user.services = lib.mapAttrs (_: channel: {
    Unit.Description = "Refresh the local ${channel.label} package index";
    Service = {
      Type = "oneshot";
      ExecStart = "${lib.getExe packageIndex} refresh${channel.arguments} --release %i";
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
  }) channels;
}
