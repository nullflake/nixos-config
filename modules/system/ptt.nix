{
  config,
  lib,
  pkgs,
  username,
  ...
}:

let
  cfg = config.modules.ptt;

  /*
    Convert to string so that an unset (null) value does not cause a
    type error during evaluation; the assertions below report it instead.
  */
  device = toString cfg.device;
  button = toString cfg.button;

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
      device=${lib.escapeShellArg device}
      button=${button}

      state_file="$RUNTIME_DIRECTORY/held"
      source_file="$RUNTIME_DIRECTORY/source"
      applied_file="$RUNTIME_DIRECTORY/applied"
      override_file="$RUNTIME_DIRECTORY/override"
      lock_file="$RUNTIME_DIRECTORY/lock"

      # Include object.serial because PipeWire can reuse a removed node's ID.
      # Resolve the default once so mute reads/writes target the same node.
      get_source() {
        local out line id="" serial=""
        out=$(wpctl inspect @DEFAULT_AUDIO_SOURCE@ 2>/dev/null) || return 1

        local id_pattern='^id ([0-9]+),'
        local serial_pattern='^[[:space:]*]*object\.serial[[:space:]]*=[[:space:]]*"([0-9]+)"$'

        while IFS= read -r line; do
          if [[ "$line" =~ $id_pattern ]]; then
            id="''${BASH_REMATCH[1]}"
          elif [[ "$line" =~ $serial_pattern ]]; then
            serial="''${BASH_REMATCH[1]}"
          fi
        done <<< "$out"

        [ -n "$id" ] && [ -n "$serial" ] || return 1
        printf '%s %s\n' "$id" "$serial"
      }

      # Reads the *actual* current mute state of the resolved source,
      # independent of what we think we last set. Prints
      # "0"/"1", or nothing if the source is unavailable.
      get_actual_mute() {
        local out
        out=$(wpctl get-volume "$1" 2>/dev/null) || {
          printf ""
          return
        }

        case "$out" in
          *MUTED*)
            printf '1'
            ;;
          *)
            printf '0'
            ;;
        esac
      }

      sync_state() {
        # Explicit calls (button events, startup, device
        # (re)connect) always force the state. Periodic watchdog
        # calls (no argument) instead check whether the mute state
        # was changed manually (e.g. from the sound control
        # center) and, if so, leave it alone.
        local explicit=0
        local requested_state=""

        if [ $# -ge 1 ]; then
          explicit=1
          requested_state="$1"
        fi

        (
          flock -x 200

          if [ "$explicit" = "1" ]; then
            # A button event (or any other explicit call) always
            # wins: leave override mode and force the requested
            # state.
            printf '0\n' > "$override_file"
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

          local source last_source
          if ! source=$(get_source); then
            # Do not carry a manual override or mute baseline across an
            # observed outage, even if PipeWire later reuses the IDs.
            rm -f "$source_file" "$applied_file"
            printf '0\n' > "$override_file"
            return 0
          fi

          last_source=$(cat "$source_file" 2>/dev/null || printf "")
          if [ "$source" != "$last_source" ]; then
            # A different/recreated source is not a manual mute change.
            # Apply the held-button state before establishing its baseline.
            printf '0\n' > "$override_file"
            rm -f "$applied_file"
            printf '%s\n' "$source" > "$source_file"
          fi

          local source_id="''${source%% *}"

          local override
          override=$(cat "$override_file" 2>/dev/null || printf '0\n')

          local skip=0

          if [ "$explicit" != "1" ] && [ "$override" = "1" ]; then
            # We're already respecting a manual change from the
            # sound control center. Stay out of it entirely until
            # the next button press/release or source change.
            skip=1
          elif [ "$explicit" != "1" ]; then
            local actual_mute
            actual_mute=$(get_actual_mute "$source_id")

            local last_applied
            last_applied=$(cat "$applied_file" 2>/dev/null || printf "")

            if [ -n "$actual_mute" ] && [ -n "$last_applied" ] \
              && [ "$actual_mute" != "$last_applied" ]
            then
              # Manual override just happened: remember it and
              # back off persistently, not just for this one tick.
              printf '1\n' > "$override_file"
              printf '%s\n' "$actual_mute" > "$applied_file"
              skip=1
            fi
          fi

          if [ "$skip" != "1" ]; then
            # PipeWire/WirePlumber may be temporarily unavailable
            # while starting, restarting, or recreating an audio
            # source. Retry locally, then let the watchdog retry
            # later.
            for _ in 1 2 3 4 5; do
              if wpctl set-mute \
                "$source_id" "$target_mute" \
                >/dev/null 2>&1
              then
                printf '%s\n' "$target_mute" > "$applied_file"
                break
              fi

              sleep 0.2
            done
          fi
        ) 200>"$lock_file"
      }

      # Start with the button released and request mute.
      rm -f "$source_file" "$applied_file"
      printf '0\n' > "$state_file"
      printf '0\n' > "$override_file"
      sync_state 0

      # Re-apply the desired state periodically, unless the mute
      # state was changed manually in the meantime. This matters
      # when WirePlumber recreates the default source or changes it
      # after a device/profile transition.
      (
        while true; do
          sleep 3
          sync_state
        done
      ) &

      watchdog_pid=$!

      # Attempt mute on shell exit without waiting for the state lock.
      # Give wpctl a one-second timeout; ExecStopPost also attempts mute
      # when the process exits unexpectedly or this trap cannot run.
      cleanup() {
        trap - EXIT INT TERM
        kill "$watchdog_pid" 2>/dev/null || true
        timeout 1 wpctl set-mute @DEFAULT_AUDIO_SOURCE@ 1 \
          >/dev/null 2>&1 || true
      }

      # Exit on INT/TERM so the EXIT trap runs cleanup instead of
      # returning to the event loop.
      trap 'exit 0' INT TERM
      trap cleanup EXIT

      while true; do
        if [ -e "$device" ]; then
          # Treat a new/reconnected input device as released and request mute.
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

          # Request mute after input-device loss or an evtest failure.
          sync_state 0
        fi

        # Interruptible sleep: bash runs traps immediately during
        # the builtin wait, but not while a foreground sleep runs.
        sleep 2 &
        wait $! || true
      done
    '';
  };
in
{
  options.modules.ptt = {
    enable = lib.mkEnableOption "Push-to-Talk";

    device = lib.mkOption {
      type = lib.types.nullOr (lib.types.strMatching "/dev/input/by-id/.+");
      default = null;

      description = ''
        Stable /dev/input/by-id/... evdev device path used for PTT.
        Required when `modules.ptt.enable` is true.
      '';

      example = "/dev/input/by-id/usb-Vendor_Mouse_SERIAL-event-mouse";
    };

    button = lib.mkOption {
      type = lib.types.nullOr (lib.types.ints.between 0 767);
      default = null;

      description = ''
        Evdev EV_KEY code used for Push-to-Talk.
        Required when `modules.ptt.enable` is true.
        Example: 276 = BTN_EXTRA.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.device != null;
        message = "modules.ptt.device must be set when modules.ptt.enable is true.";
      }
      {
        assertion = cfg.button != null;
        message = "modules.ptt.button must be set when modules.ptt.enable is true.";
      }
    ];

    users.groups.ptt = { };

    users.users.${username}.extraGroups = [
      "ptt"
    ];

    # Restrict access to the configured event device only.
    services.udev.extraRules = ''
      SUBSYSTEM=="input", KERNEL=="event*", \
      SYMLINK=="${lib.removePrefix "/dev/" device}", \
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

        /*
          Request mute after service exit, including failed starts.
          Use a one-second timeout because PipeWire may be unavailable.
        */
        ExecStopPost = "-${pkgs.coreutils}/bin/timeout 1 ${wpctl} set-mute @DEFAULT_AUDIO_SOURCE@ 1";

        TimeoutStopSec = "3s";

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
