{ pkgs, ... }:
{
  programs.steam = {
    enable = true;

    # Local network features are kept disabled to minimize open ports on a single-PC setup
    remotePlay.openFirewall = false;
    dedicatedServer.openFirewall = false;
    localNetworkGameTransfers.openFirewall = false;

    protontricks.enable = true;
    extraCompatPackages = with pkgs; [
      proton-ge-bin
    ];
  };
}
