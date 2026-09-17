{
  config,
  pkgs,
  lib,
  ...
}:
{
  xdg.portal = {
    enable = true;
    xdgOpenUsePortal = true; # Forces apps to use portals instead of standalone scripts

    extraPortals = [
      pkgs.xdg-desktop-portal-gtk
    ]
    ++ lib.optional (builtins.elem "hyprland" config.custom.windowManager) pkgs.xdg-desktop-portal-hyprland;
    /*
      umbriel provides its own xdg-desktop-portal-umbriel automatically,
      no need to add it here
    */

    config.common = {
      default =
        (lib.optional (builtins.elem "hyprland" config.custom.windowManager) "hyprland")
        ++ (lib.optional (builtins.elem "umbriel" config.custom.windowManager) "umbriel")
        ++ [ "gtk" ];
      "org.freedesktop.impl.portal.FileChooser" = [ "gtk" ];
      "org.freedesktop.impl.portal.AppChooser" = [ "gtk" ];
      "org.freedesktop.impl.portal.Settings" = [ "gtk" ];
    };
  };
}
