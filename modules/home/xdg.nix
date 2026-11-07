{ config, lib, ... }:
let
  mimeDefaults = desktop: types: lib.genAttrs types (_: [ desktop ]);
in
{
  xdg.mimeApps = {
    enable = true;
    # Keep wildcard defaults from declaring support for every matching format.
    associations.added = lib.filterAttrs (
      mime: _: !(lib.hasSuffix "*" mime)
    ) config.xdg.mimeApps.defaultApplications;
    defaultApplications =
      # Text
      mimeDefaults "micro.desktop" [
        "application/x-zerosize"
        "inode/x-empty"
        "text/plain"
      ]
      # PDF
      // mimeDefaults "org.gnome.Papers.desktop" [
        "application/pdf"
      ]
      # Images
      // mimeDefaults "swayimg.desktop" [
        "image/*"
      ]
      # Media
      // mimeDefaults "mpv.desktop" [
        "audio/*"
        "video/*"
      ]
      # Browser
      // mimeDefaults "helium.desktop" [
        "text/html"
        "x-scheme-handler/about"
        "x-scheme-handler/http"
        "x-scheme-handler/https"
        "x-scheme-handler/unknown"
      ]
      # Mail
      // mimeDefaults "proton-mail.desktop" [
        "x-scheme-handler/mailto"
      ];
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
      SOURCES = "${config.home.homeDirectory}/Sources";
    };
  };

  # Nautilus "New Document" template
  home.activation.setupTemplates = lib.mkIf (config.xdg.userDirs.templates != null) (
    config.lib.dag.entryAfter [ "writeBoundary" ] ''
      run mkdir -p ${lib.escapeShellArg config.xdg.userDirs.templates}

      f=${lib.escapeShellArg "${config.xdg.userDirs.templates}/Empty File"}
      [ -e "$f" ] || run touch "$f"
    ''
  );
}
