let
  username = "nullflake";
in
{
  system = "x86_64-linux";
  inherit username;

  modules = [
    ./hardware.nix

    ../../modules/system/audio.nix
    ../../modules/system/bluetooth.nix
    ../../modules/system/boot.nix
    ../../modules/system/ddcutil.nix
    ../../modules/system/diskServices.nix
    ../../modules/system/fonts.nix
    ../../modules/system/greeter.nix
    ../../modules/system/locale.nix
    ../../modules/system/memory.nix
    ../../modules/system/network.nix
    ../../modules/system/nh.nix
    ../../modules/system/nix.nix
    ../../modules/system/nvidia.nix
    ../../modules/system/ptt.nix
    ../../modules/system/security.nix
    ../../modules/system/shell.nix
    ../../modules/system/steam.nix
    ../../modules/system/unfree.nix
    ../../modules/system/user.nix
    ../../modules/system/wayland.nix
    ../../modules/system/windowManager.nix
    ../../modules/system/xdgPortal.nix
    ../../modules/system/zapret.nix
  ];

  configuration = {
    networking.hostName = "wakizashi";

    custom = {
      greeter.backend = "noctalia";
      unfree.mode = "all";
      user.shell = "zsh";
      windowManager = [
        "umbriel"
        "hyprland"
      ];

      ptt = {
        enable = true;
        device = "/dev/input/by-id/usb-Logitech_Gaming_Mouse_G502_0D7C36763738-event-mouse";
        button = 276;
      };
    };

    home-manager.users.${username} = import ./home.nix;

    system.stateVersion = "26.05";
  };
}
