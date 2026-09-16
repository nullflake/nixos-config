{
  config,
  lib,
  pkgs,
  username,
  ...
}:

let
  cfg = config.ptt;

  pttScript = pkgs.writeShellScript "ptt" ''
    export XDG_RUNTIME_DIR="/run/user/$(id -u)"
    export DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"

    ${pkgs.coreutils}/bin/stdbuf -oL \
      ${pkgs.evtest}/bin/evtest ${cfg.device} |
    while read -r line; do
      case "$line" in
        *"code ${toString cfg.button} ("*"value 1"*)
          ${pkgs.wireplumber}/bin/wpctl \
            set-mute @DEFAULT_AUDIO_SOURCE@ 0
          ;;
        *"code ${toString cfg.button} ("*"value 0"*)
          ${pkgs.wireplumber}/bin/wpctl \
            set-mute @DEFAULT_AUDIO_SOURCE@ 1
          ;;
      esac
    done
  '';
in
{
  options.ptt = {
    enable = lib.mkEnableOption "Push-to-Talk";

    device = lib.mkOption {
      type = lib.types.str;
      description = ''
        Evdev input device used for Push-to-Talk.
        Must be an evdev device path, preferably /dev/input/by-id/...
      '';
    };

    button = lib.mkOption {
      type = lib.types.int;
      description = ''
        Evdev button code used for Push-to-Talk.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.ptt = {
      description = "Push-to-Talk";
      wantedBy = [ "multi-user.target" ];

      startLimitIntervalSec = 60;
      startLimitBurst = 5;

      serviceConfig = {
        User = username;
        SupplementaryGroups = [ "input" ];

        ExecStart = pttScript;

        Restart = "always";
        RestartSec = "2s";
      };
    };
  };
}
