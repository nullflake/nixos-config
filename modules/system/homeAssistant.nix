{
  config,
  lib,
  ...
}:
let
  cfg = config.modules.homeAssistant;

  /*
    Port protected by the firewall rule below; this does not configure HA.
    Since HA 2026.8, HTTP server settings are UI state (.storage/http).
    Update this value if the port is changed there.
  */
  port = 8123;
in
{
  options.modules.homeAssistant = {
    enable = lib.mkEnableOption "Home Assistant";

    devices = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options.name = lib.mkOption {
            type = lib.types.str;
            description = "Device display name.";
          };
        }
      );
      default = { };
      description = "Local Yeelight devices indexed by IP address.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = config.networking.firewall.enable;
        message = "modules.homeAssistant: blocking remote access to port ${toString port} requires networking.firewall.enable.";
      }
      {
        assertion = config.networking.firewall.backend == "iptables";
        message = "modules.homeAssistant: the port ${toString port} restriction requires the iptables firewall backend. Adapt the rule before changing backends.";
      }
    ];

    services.home-assistant = {
      enable = true;
      openFirewallForComponents = false;

      /*
        Dependencies for UI-configured integrations and onboarding defaults.
        NixOS infers dependencies for YAML-configured integrations automatically.
      */
      extraComponents = [
        "roborock"
        "met"
        "radio_browser"
      ];

      config = {
        default_config = { };

        homeassistant = {
          name = "Home";
          unit_system = "metric";
          time_zone = config.time.timeZone;
        };
      }
      // lib.optionalAttrs (cfg.devices != { }) {
        yeelight.devices = cfg.devices;
      };
    };

    /*
      The UI is used only on this PC. Even if HA listens on all interfaces,
      refuse non-loopback TCP traffic to its port over IPv4 and IPv6.

      Insert ahead of trusted-interface and established-connection accepts.
      mkAfter runs this after default-order extraCommands, placing this insert
      ahead of their rules. Outbound cloud connections remain unaffected.
    */
    networking.firewall.extraCommands = lib.mkAfter ''
      ip46tables -I nixos-fw 1 ! -i lo -p tcp --dport ${toString port} -j nixos-fw-refuse
    '';

    # The Home Assistant desktop launcher uses this local hostname.
    networking.hosts."127.0.0.1" = [ "homeassistant.local" ];
  };
}
