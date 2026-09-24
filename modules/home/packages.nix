{ pkgs, inputs, ... }:
{
  home.packages = with pkgs; [
    # GUI
    android-studio
    brave
    ente-auth
    gnome-calculator
    helium
    heroic
    hyprpicker
    libreoffice
    nautilus
    obsidian
    papers
    proton-pass
    satty
    spotify
    stremio-linux-shell
    tor-browser
    veracrypt
    vesktop

    # CLI
    android-tools
    bat
    btop
    cava
    claude-code
    ddcutil
    dnsutils
    ente-cli
    evtest
    file
    fzf
    git
    glib
    jq
    micro
    nvd
    ookla-speedtest
    proton-vpn-cli
    python3
    rclone
    ripgrep
    scrcpy
    (tesseract.override {
      enableLanguages = [
        "tur"
        "eng"
      ];
    })
    trash-cli
    trippy
    wl-clipboard

    # Desktop
    adwaita-icon-theme
    bibata-cursors
    gpu-screen-recorder
    grim
    hyprshot
    inputs.noctalia.packages.${pkgs.stdenv.hostPlatform.system}.default
    libnotify
    slurp
    yaru-theme
  ];
}
