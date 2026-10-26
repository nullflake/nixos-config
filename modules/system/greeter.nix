{
  config,
  lib,
  pkgs,
  inputs,
  username,
  ...
}:
{
  imports = [
    inputs.noctalia-greeter.nixosModules.default
  ];

  options.custom.greeter.backend = lib.mkOption {
    type = lib.types.enum [
      "tuigreet"
      "noctalia"
    ];
    # No default — every host must pick one explicitly.
    description = "Login greeter backend running on this host.";
  };

  /*
    mkIf delays backend conditions until individual option definitions
    are evaluated; mkMerge combines the backend definitions.
  */
  config = lib.mkMerge [
    (lib.mkIf (config.custom.greeter.backend == "tuigreet") {
      /*
        This module derives tuigreet's --cmd default from one selected
        window manager. tuigreet itself also supports session selection.
      */
      assertions = [
        {
          assertion = builtins.length config.custom.windowManager == 1;
          message = "The tuigreet backend derives --cmd from one window manager; custom.windowManager must contain exactly one entry.";
        }
      ];

      services.greetd = {
        enable = true;
        settings.default_session = {
          command =
            let
              wm = builtins.elemAt config.custom.windowManager 0;
            in
            "${pkgs.tuigreet}/bin/tuigreet --time --remember --cmd ${wm}";
        };
      };

      systemd.services.greetd.serviceConfig = {
        Type = "idle";
        StandardInput = "tty";
        StandardOutput = "tty";
        StandardError = "journal";
        TTYReset = true;
        TTYVHangup = true;
        TTYVTDisallocate = true;
      };
    })

    (lib.mkIf (config.custom.greeter.backend == "noctalia") {
      /*
        noctalia lists every installed session and lets you pick one
        interactively, so no --session is forced here.
      */
      services.displayManager.noctalia-greeter = {
        enable = true;

        /*
          Lets the noctalia shell sync wallpaper/colors/theme to the
          greeter without a pkexec password prompt.
        */
        passwordless-sync-users = [ username ];

        settings = {
          /*
            Single source of truth is custom.theme.cursor, matching the
            rest of the desktop environment.
          */
          cursor = {
            theme = config.custom.theme.cursor.name;
            size = config.custom.theme.cursor.size;
            path = "${config.custom.theme.cursor.package}/share/icons";
          };

          /*
            Single source of truth is locale.nix (services.xserver.xkb),
            so the login screen can't drift from the system layout.
            An empty variant is omitted instead of written as "".
          */
          keyboard =
            let
              xkb = config.services.xserver.xkb;
            in
            {
              inherit (xkb) layout;
            }
            // lib.optionalAttrs (xkb.variant != "") { inherit (xkb) variant; };
        };
      };
    })
  ];
}
