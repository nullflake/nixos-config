{ pkgs, ... }:
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
      "nullflake/youtube-search"
    ];
  };

in
{
  home.packages = [ pkgs.python3 ];
  xdg.configFile."noctalia/launcher.toml".source = launcherConfig;
  # Store-backed files deploy the launcher and playback profile together.
  xdg.dataFile."noctalia/plugins/youtube-search".source =
    ../../assets/noctalia/plugins/youtube-search;
}
