{ pkgs, ... }:
{
  xdg.configFile = {
    "noctalia/settings.toml".source = pkgs.replaceVars ../../assets/noctalia/settings.toml {
      wallpaper = ../../assets/images/wallpaper;
    };
    "noctalia/palettes/tomorrow.json".source = ../../assets/noctalia/palettes/tomorrow.json;
    "noctalia/palettes/nullflake.json".source = ../../assets/noctalia/palettes/nullflake.json;
    "noctalia/palettes/nullflake-dark-red.json".source = ../../assets/noctalia/palettes/nullflake-dark-red.json;
    "noctalia/templates/obsidian.css".source = ../../assets/noctalia/templates/obsidian.css;
  };
}
