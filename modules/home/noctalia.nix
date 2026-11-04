{ config, pkgs, ... }:
let
  launcherConfig = (pkgs.formats.toml { }).generate "noctalia-launcher.toml" {
    /*
      This base selection restores our current plugins on a fresh installation.
      GUI selections in ~/.local/state/noctalia/settings.toml replace this list
      and survive rebuilds; they are intentionally left writable by Noctalia.
    */
    plugins.enabled = [
      "noctalia/notes"
      "noctalia/screen_recorder"
      "noctalia/translator"
      "nullflake/youtube-explorer"
    ];
    plugins.source = [
      {
        name = "official";
        kind = "git";
        location = "https://github.com/noctalia-dev/official-plugins";
        enabled = true;
      }
      {
        name = "community";
        kind = "git";
        location = "https://github.com/noctalia-dev/community-plugins";
        enabled = true;
      }
      {
        name = "nullflake";
        kind = "path";
        /*
          YouTube Explorer is developed in a separate local checkout.
          Load it directly during development so plugin code changes do not
          require a NixOS rebuild. The checkout must exist at this path.
        */
        location = "${config.home.homeDirectory}/Projects/youtube-explorer";
        enabled = true;
      }
    ];
  };

in
{
  xdg.configFile."noctalia/launcher.toml".source = launcherConfig;
}
