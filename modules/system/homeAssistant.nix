{ config, pkgs, ... }:
{
  services.home-assistant = {
    enable = true;

    customComponents = [
      pkgs.home-assistant-custom-components.xiaomi_home
    ];

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

  # xiaomi_home hardcodes its OAuth redirect to homeassistant.local:8123
  networking.hosts."127.0.0.1" = [ "homeassistant.local" ];
}
