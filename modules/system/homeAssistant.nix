{
  config,
  lib,
  pkgs,
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
  options.modules.homeAssistant.enable = lib.mkEnableOption "Home Assistant";

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

      customComponents = [
        pkgs.home-assistant-custom-components.xiaomi_home
      ];

      /*
        Provides integration dependencies; this list does not activate them.
        default_config loads zeroconf, which makes HA discoverable on the LAN
        independently of Avahi.
      */
      extraComponents = [
        "roborock"
        "ffmpeg"
        "zeroconf"
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

    # xiaomi_home hardcodes its OAuth redirect to homeassistant.local:8123
    networking.hosts."127.0.0.1" = [ "homeassistant.local" ];
  };
}
