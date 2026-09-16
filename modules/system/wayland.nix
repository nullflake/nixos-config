{
  environment.sessionVariables = {
    # Native Wayland for Electron apps
    NIXOS_OZONE_WL = "1";
    # Auto-detect Wayland/X11 per app
    ELECTRON_OZONE_PLATFORM_HINT = "auto";
  };
}
