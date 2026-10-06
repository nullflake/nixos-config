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
    Don't read config in a top-level let here — this option is defined
    by this same module, so early evaluation causes infinite recursion.
    mkIf/mkMerge are lazy, so reading config.custom inside them is safe.
  */
  config = lib.mkMerge [
    (lib.mkIf (config.custom.greeter.backend == "tuigreet") {
      /*
        tuigreet has no session picker: it always runs a single fixed
        command, so exactly one window manager must be selected.
      */
      assertions = [
        {
          assertion = builtins.length config.custom.windowManager == 1;
          message = "tuigreet has no session picker; custom.windowManager must contain exactly one entry when using the tuigreet backend.";
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
          cursor = {
            theme = "Bibata-Modern-Classic";
            size = 24;
            path = "${pkgs.bibata-cursors}/share/icons";
          };
          keyboard.layout = "tr";
        };
      };
    })
  ];
}
