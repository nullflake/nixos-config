{ pkgs, username, ... }:
{
  # Set the user's login shell to Zsh.
  users.users."${username}".shell = pkgs.zsh;

  programs.zsh.enable = true;
}
