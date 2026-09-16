{ pkgs, ... }:

{
  # Bootloader
  boot.loader.systemd-boot = {
    enable = true;
    configurationLimit = 10;
  };

  boot.loader.efi.canTouchEfiVariables = true;

  # Kernel
  boot.kernelPackages = pkgs.linuxPackages_latest;
}
