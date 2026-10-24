{
  config,
  lib,
  ...
}:

let
  cfg = config.custom.theme.cursor;
in
{
  options.custom.theme.cursor = {
    name = lib.mkOption {
      type = lib.types.str;
      /*
        No default on purpose.
        Every host must pick one explicitly.
      */
      description = "Cursor theme name.";
    };

    package = lib.mkOption {
      type = lib.types.package;
      /*
        No default on purpose.
        Every host must pick one explicitly.
      */
      description = "Package providing the cursor theme.";
    };

    size = lib.mkOption {
      type = lib.types.ints.positive;
      default = 24;
      description = "Cursor size in pixels.";
    };
  };

  config = {
    # Install the cursor theme package system-wide
    environment.systemPackages = [ cfg.package ];

    # Unified cursor environment variables for Wayland and X11 sessions
    environment.sessionVariables = {
      XCURSOR_THEME = cfg.name;
      XCURSOR_SIZE = toString cfg.size;
      HYPRCURSOR_THEME = cfg.name;
      HYPRCURSOR_SIZE = toString cfg.size;
    };
  };
}
