{ username, ... }:
{
  imports = [
    # CLI modules
    ../../modules/home/cli/aliases.nix
    ../../modules/home/cli/eza.nix
    ../../modules/home/cli/fastfetch.nix
    ../../modules/home/cli/fd.nix
    ../../modules/home/cli/micro.nix
    ../../modules/home/cli/starship.nix
    ../../modules/home/cli/yazi.nix
    ../../modules/home/cli/zoxide.nix
    ../../modules/home/cli/zsh.nix

    ../../modules/home/desktopEntries.nix
    ../../modules/home/environment.nix
    ../../modules/home/kitty.nix
    ../../modules/home/mangohud.nix
    ../../modules/home/mpv.nix
    ../../modules/home/nautilus.nix
    ../../modules/home/noctalia.nix
    ../../modules/home/packages.nix
    ../../modules/home/nixTools.nix
    ../../modules/home/swayimg.nix
    ../../modules/home/theme.nix
    ../../modules/home/udiskie.nix
    ../../modules/home/umbriel.nix
    ../../modules/home/veracrypt.nix
    ../../modules/home/xdg.nix
    ../../modules/home/zed.nix
  ];

  # User identity
  home.username = username;

  # Home Manager settings
  programs.home-manager.enable = true;
  home.enableNixpkgsReleaseCheck = false;
  home.stateVersion = "26.05";
}
