{ pkgs, inputs, ... }:
{
  home.packages = with pkgs; [
    # Browsers
    brave-origin
    helium
    tor-browser

    # Communication
    protonmail-desktop
    vesktop

    # Security & privacy
    ente-auth
    proton-pass

    # Media & games
    cava
    heroic
    spotify
    stremio-linux-shell
    yt-dlp

    # Productivity
    gnome-calculator
    libreoffice
    obsidian
    papers

    # Development
    android-studio
    android-tools
    claude-code
    codex
    git
    just
    python3

    # Files & storage
    ente-cli
    file
    (nautilus.overrideAttrs (old: {
      postPatch = (old.postPatch or "") + ''
        substituteInPlace src/nautilus-window-slot.c \
          --replace-fail 'ltr ? "<alt>Left|Back" : "<alt>Right|Back"' \
                         'ltr ? "<alt>Left|Back|BackSpace" : "<alt>Right|Back|BackSpace"'
      '';
    }))
    trash-cli

    # Text & search
    bat
    fzf
    jq
    ripgrep
    (tesseract.override {
      enableLanguages = [
        "tur"
        "eng"
      ];
    })

    # System & hardware
    btop
    ddcutil
    evtest
    glib
    nvd

    # Network
    ookla-speedtest
    proton-vpn-cli
    trippy

    # Screen capture
    gpu-screen-recorder
    grim
    hyprpicker
    hyprshot
    slurp

    # Desktop integration
    inputs.noctalia.packages.${pkgs.stdenv.hostPlatform.system}.default
    libnotify
    wl-clipboard

    # Theming
    adwaita-icon-theme
    yaru-theme
  ];
}
