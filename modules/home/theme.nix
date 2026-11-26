{
  config,
  lib,
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
      name = builtins.head osConfig.fonts.fontconfig.defaultFonts.sansSerif;
      size = 11;
    };
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
      monospace-font-name = "${builtins.head osConfig.fonts.fontconfig.defaultFonts.monospace} 11";
    };

    "org/gnome/desktop/privacy" = {
      remember-recent-files = false;
    };

    "org/gnome/desktop/wm/preferences" = {
      button-layout = "";
    };
  };
}
