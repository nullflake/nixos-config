{ pkgs, inputs, ... }:
{
  home.packages = with pkgs; [
    # Browsers
    brave
    helium
    tor-browser

    # Communication
    protonmail-desktop
    vesktop

    # Security & privacy
    ente-auth
    proton-pass
    veracrypt

    # Media & games
    cava
    heroic
    spotify
    stremio-linux-shell

    # Productivity
    gnome-calculator
    libreoffice
    obsidian
    papers

    # Development
    android-studio
    android-tools
    claude-code
    git
    python3
    scrcpy

    # Files & storage
    ente-cli
    file
    nautilus
    rclone
    trash-cli

    # Text & search
    bat
    fzf
    jq
    micro
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
    dnsutils
    ookla-speedtest
    proton-vpn-cli
    trippy

    # Screen capture
    gpu-screen-recorder
    grim
    hyprpicker
    hyprshot
    satty
    slurp

    # Desktop integration
    inputs.noctalia.packages.${pkgs.stdenv.hostPlatform.system}.default
    libnotify
    wl-clipboard

    # Theming
    adwaita-icon-theme
    bibata-cursors
    yaru-theme
  ];
}
