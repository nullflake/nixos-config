{
  config,
  lib,
  pkgs,
  username,
  ...
}:

let
  cfg = config.custom.ptt;

  wpctl = lib.getExe' pkgs.wireplumber "wpctl";

  pttScript = pkgs.writeShellApplication {
    name = "ptt";

    runtimeInputs = [
      pkgs.coreutils
      pkgs.evtest
      pkgs.util-linux
      pkgs.wireplumber
    ];

    text = ''
      device=${lib.escapeShellArg cfg.device}
      button=${toString cfg.button}

      state_file="$RUNTIME_DIRECTORY/held"
      lock_file="$RUNTIME_DIRECTORY/lock"

      sync_state() {
        local requested_state="''${1:-}"

        (
          flock -x 200

          if [ -n "$requested_state" ]; then
            printf '%s\n' "$requested_state" > "$state_file"
          fi

          local held
          held=$(cat "$state_file" 2>/dev/null || printf '0\n')

          case "$held" in
            0|1)
              ;;
            *)
              held=0
              printf '0\n' > "$state_file"
              ;;
          esac

          local target_mute=$((1 - held))

          # PipeWire/WirePlumber may be temporarily unavailable while
          # starting, restarting, or recreating an audio source.
          # Retry locally, then let the watchdog retry later.
          for _ in 1 2 3 4 5; do
            if wpctl set-mute \
              @DEFAULT_AUDIO_SOURCE@ "$target_mute" \
              >/dev/null 2>&1
            then
              break
            fi

            sleep 0.2
          done
        ) 200>"$lock_file"
      }

      # Fail closed from the beginning.
      printf '0\n' > "$state_file"
      sync_state 0

      # Re-apply the desired state periodically. This matters when
      # WirePlumber recreates the default source or changes it after
      # a device/profile transition.
      (
        while true; do
          sleep 3
          sync_state
        done
      ) &

      watchdog_pid=$!

      cleanup() {
        kill "$watchdog_pid" 2>/dev/null || true
        sync_state 0
      }

      trap cleanup EXIT INT TERM

      while true; do
        if [ -e "$device" ]; then
          # A newly appeared/reappeared input device always starts
          # in the safe state.
          sync_state 0

          # evtest terminates when the device disappears or fails.
          # Process substitution keeps the event loop independent
          # from pipeline/subshell semantics.
          while read -r line; do
            case "$line" in
              *"(EV_KEY)"*"code $button ("*"value 1")
                sync_state 1
                ;;

              *"(EV_KEY)"*"code $button ("*"value 0")
                sync_state 0
                ;;
            esac
          done < <(
            stdbuf -oL evtest "$device" 2>/dev/null
          )

          # Device disappeared or evtest terminated:
          # never leave the microphone unmuted.
          sync_state 0
        fi

        sleep 2
      done
    '';
  };
in
{
  options.custom.ptt = {
    enable = lib.mkEnableOption "Push-to-Talk";

    device = lib.mkOption {
      type = lib.types.strMatching "/dev/input/by-id/.+";

      description = ''
        Stable /dev/input/by-id/... evdev device path used for PTT.
      '';

      example = "/dev/input/by-id/usb-Vendor_Mouse_SERIAL-event-mouse";
    };

    button = lib.mkOption {
      type = lib.types.ints.between 0 767;

      description = ''
        Evdev EV_KEY code used for Push-to-Talk.
        Example: 276 = BTN_EXTRA.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    users.groups.ptt = { };

    users.users.${username}.extraGroups = [
      "ptt"
    ];

    # Restrict access to the configured event device only.
    services.udev.extraRules = ''
      SUBSYSTEM=="input", KERNEL=="event*", \
      SYMLINK=="${lib.removePrefix "/dev/" cfg.device}", \
      GROUP="ptt", MODE="0660"
    '';

    systemd.user.services.ptt = {
      description = "Push-to-Talk";

      wantedBy = [
        "default.target"
      ];

      after = [
        "pipewire.service"
        "wireplumber.service"
      ];

      startLimitIntervalSec = 0;

      serviceConfig = {
        ExecStart = lib.getExe pttScript;

        # Fail closed when systemd stops the service for any reason.
        ExecStopPost = "-${wpctl} set-mute @DEFAULT_AUDIO_SOURCE@ 1";

        Restart = "on-failure";
        RestartSec = "2s";

        RuntimeDirectory = "ptt";

        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = "read-only";

        RestrictAddressFamilies = [
          "AF_UNIX"
        ];

        RestrictNamespaces = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        LockPersonality = true;
      };
    };
  };
}
