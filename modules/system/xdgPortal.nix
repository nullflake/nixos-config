{ pkgs, ... }:
{
  xdg.portal = {
    enable = true;
    xdgOpenUsePortal = true; # Forces apps to use portals instead of standalone scripts

    /*
      programs.hyprland and programs.umbriel register their own portal
      backends and ship their own <desktop>-portals.conf, which
      xdg-desktop-portal prefers over portals.conf. Only the shared gtk
      backend is listed here.
    */
    extraPortals = [ pkgs.xdg-desktop-portal-gtk ];

    # Fallback for sessions with an unrecognized XDG_CURRENT_DESKTOP
    config.common.default = [ "gtk" ];
  };
}
