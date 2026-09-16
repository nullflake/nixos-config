{ pkgs, username, ... }:
{
  imports = [
    ../../modules/home/desktopEntries.nix
    ../../modules/home/environment.nix
    ../../modules/home/eza.nix
    ../../modules/home/fastfetch.nix
    ../../modules/home/fd.nix
    ../../modules/home/kitty.nix
    ../../modules/home/lazygit.nix
    ../../modules/home/mangohud.nix
    ../../modules/home/mpv.nix
    ../../modules/home/packages.nix
    ../../modules/home/starship.nix
    ../../modules/home/swayimg.nix
    ../../modules/home/theme.nix
    ../../modules/home/udiskie.nix
    ../../modules/home/xdg.nix
    ../../modules/home/yazi.nix
    ../../modules/home/zed.nix
    ../../modules/home/zoxide.nix
    ../../modules/home/zsh.nix
  ];

  # User identity
  home.username = username;

  # Home Configuration
  custom = {
    theme.icon = {
      name = "MoreWaita";
      package = pkgs.morewaitaFiltered;
    };
  };

  # Home Manager settings
  programs.home-manager.enable = true;
  home.enableNixpkgsReleaseCheck = false;
  home.stateVersion = "26.05";
}
