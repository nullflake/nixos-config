{ config, ... }:
{
  xdg.mimeApps = {
    enable = true;
    defaultApplications = {
      # Mail
      "x-scheme-handler/mailto" = [ "Gmail.desktop" ];

      # Browser
      "text/html" = [ "helium.desktop" ];
      "x-scheme-handler/http" = [ "helium.desktop" ];
      "x-scheme-handler/https" = [ "helium.desktop" ];
      "x-scheme-handler/about" = [ "helium.desktop" ];
      "x-scheme-handler/unknown" = [ "helium.desktop" ];

      # Pdf
      "application/pdf" = [ "org.gnome.Papers.desktop" ];

      # Text
      "text/plain" = [ "micro.desktop" ];
      "application/x-zerosize" = [ "micro.desktop" ];
      "inode/x-empty" = [ "micro.desktop" ];

      # Images
      "image/jpeg" = [ "swayimg.desktop" ];
      "image/png" = [ "swayimg.desktop" ];
      "image/gif" = [ "swayimg.desktop" ];
      "image/webp" = [ "swayimg.desktop" ];

      # Videos
      "video/mp4" = [ "mpv.desktop" ];
      "video/x-matroska" = [ "mpv.desktop" ];
      "video/webm" = [ "mpv.desktop" ];

      # Audio
      "audio/mpeg" = [ "mpv.desktop" ];
      "audio/flac" = [ "mpv.desktop" ];
    };
  };

  xdg.userDirs = {
    enable = true;
    createDirectories = true;
    desktop = null;
    documents = "${config.home.homeDirectory}/Documents";
    download = "${config.home.homeDirectory}/Downloads";
    pictures = "${config.home.homeDirectory}/Pictures";
    music = "${config.home.homeDirectory}/Music";
    videos = "${config.home.homeDirectory}/Videos";
    extraConfig = {
      XDG_SOURCES_DIR = "${config.home.homeDirectory}/Sources";
    };
  };

  # Nautilus "New Document" template
  home.activation.setupTemplates = config.lib.dag.entryAfter [ "writeBoundary" ] ''
    mkdir -p "${config.home.homeDirectory}/Templates"

    f="${config.home.homeDirectory}/Templates/Empty File"
    [ -e "$f" ] || $DRY_RUN_CMD touch "$f"
  '';
}
