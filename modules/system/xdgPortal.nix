{
  config,
  lib,
  pkgs,
  ...
}:
let
  fileChoosers = [
    "luciole"
    "gnome"
  ];
in
{
  xdg.portal = {
    enable = true;
    xdgOpenUsePortal = true; # Make xdg-open use the portal

    extraPortals = [
      pkgs.xdg-desktop-portal-gtk # Shared fallback backend for portals not handled elsewhere
      pkgs.xdg-desktop-portal-gnome # Provides the GNOME GTK4 file chooser
    ];

    config = {
      # Fallback for sessions with an unrecognized XDG_CURRENT_DESKTOP.
      common = {
        default = [ "gtk" ];
        "org.freedesktop.impl.portal.FileChooser" = [ "gnome" ];
      };

      # Keep each compositor first for its own interfaces.
      umbriel = {
        default = [
          "umbriel"
          "gtk"
        ];
        "org.freedesktop.impl.portal.FileChooser" = fileChoosers;
      };

      hyprland = {
        default = [
          "hyprland"
          "gtk"
        ];
        "org.freedesktop.impl.portal.FileChooser" = fileChoosers;
      };
    };
  };

  systemd.user.services.xdg-desktop-portal.restartTriggers = lib.mapAttrsToList (
    desktop: _:
    config.environment.etc."xdg/xdg-desktop-portal/${
      lib.optionalString (desktop != "common") "${desktop}-"
    }portals.conf".source
  ) (lib.filterAttrs (_: preferences: preferences != { }) config.xdg.portal.config);
}
