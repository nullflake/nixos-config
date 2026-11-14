{
  config,
  osConfig,
  pkgs,
  ...
}:

{
  home.pointerCursor = {
    enable = true;
    name = osConfig.internal.theme.cursor.name;
    package = osConfig.internal.theme.cursor.package;
    size = osConfig.internal.theme.cursor.size;
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
      name = "Yaru-Custom";
      package = pkgs.yaruCustom;
    };

    font = {
      name = "Inter";
      size = 11;
    };

    gtk3.bookmarks = [
      "file://${config.xdg.userDirs.download}"
      "file://${config.xdg.userDirs.documents}"
      "file://${config.xdg.userDirs.pictures}"
      "file://${config.xdg.userDirs.videos}"
      "file://${config.home.homeDirectory}/.config"
      "file://${config.home.homeDirectory}/.local"
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
    "org/gnome/desktop/interface" = {
      document-font-name = "${config.gtk.font.name} ${toString config.gtk.font.size}";
      monospace-font-name = "JetBrainsMono Nerd Font 11";
    };

    "org/gnome/desktop/privacy" = {
      remember-recent-files = false;
    };

    "org/gnome/desktop/wm/preferences" = {
      button-layout = "";
    };

    "org/gnome/nautilus/list-view" = {
      use-tree-view = true;
    };
  };
}
