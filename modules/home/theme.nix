{
  config,
  osConfig,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.custom.theme;
in
{
  options.custom.theme.icon = {
    name = lib.mkOption {
      type = lib.types.str;
      description = "Icon theme name as GTK sees it (gtk.iconTheme.name).";
    };

    package = lib.mkOption {
      type = lib.types.package;
      description = "Package providing the icon theme.";
    };
  };

  config = {
    home.pointerCursor = {
      name = osConfig.custom.theme.cursor.name;
      package = osConfig.custom.theme.cursor.package;
      size = osConfig.custom.theme.cursor.size;
      gtk.enable = true;
      x11.enable = true;
    };

    gtk = {
      enable = true;

      theme = {
        name = "adw-gtk3";
        package = pkgs.adw-gtk3;
      };

      iconTheme = {
        name = cfg.icon.name;
        package = cfg.icon.package;
      };

      font = {
        name = "Inter";
        size = 11;
      };

      gtk3.bookmarks = [
        "file://${config.xdg.userDirs.download}"
        "file://${config.xdg.userDirs.documents}"
        "file://${config.xdg.userDirs.pictures}"
        "file://${config.xdg.userDirs.music}"
        "file://${config.xdg.userDirs.videos}"
      ];
    };

    qt = {
      enable = true;
      platformTheme.name = "gtk3";

      style = {
        name = "adwaita";
        package = pkgs.adwaita-qt;
      };
    };

    dconf.settings = {
      "org/gnome/desktop/wm/preferences" = {
        button-layout = "";
      };
    };
  };
}
