{ pkgs, ... }:
{
  xdg.portal = {
    enable = true;
    xdgOpenUsePortal = true; # Force apps to use XDG portals instead of standalone xdg-open scripts

    extraPortals = [
      pkgs.xdg-desktop-portal-gtk # Shared fallback backend for portals not handled elsewhere
      pkgs.xdg-desktop-portal-gnome # Provides the GNOME GTK4 file chooser
    ];

    config = {
      /*
        Fallback for sessions with an unrecognized XDG_CURRENT_DESKTOP.
      */
      common = {
        default = [ "gtk" ];
        "org.freedesktop.impl.portal.FileChooser" = [ "gnome" ];
      };

      /*
        Umbriel and Hyprland ship their own <desktop>-portals.conf files,
        which take precedence over the generic portals.conf. Override the
        file chooser in both so the GNOME picker is used while keeping the
        compositor portal first for its own interfaces.
      */
      umbriel = {
        default = [ "umbriel" "gtk" ];
        "org.freedesktop.impl.portal.FileChooser" = [ "gnome" ];
      };

      hyprland = {
        default = [ "hyprland" "gtk" ];
        "org.freedesktop.impl.portal.FileChooser" = [ "gnome" ];
      };
    };
  };
}
