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
    ++ lib.optional (config.custom.windowManager == "hyprland") pkgs.xdg-desktop-portal-hyprland;
    # umbriel provides its own xdg-desktop-portal-umbriel automatically,
    # no need to add it here

    config.common = {
      default = [
        (if config.custom.windowManager == "hyprland" then "hyprland" else "umbriel")
      ]
      ++ [ "gtk" ];
      "org.freedesktop.impl.portal.FileChooser" = [ "gtk" ];
      "org.freedesktop.impl.portal.AppChooser" = [ "gtk" ];
      "org.freedesktop.impl.portal.Settings" = [ "gtk" ];
    };
  };
}
