{
  programs.kitty = {
    enable = true;
    settings = {
      confirm_os_window_close = 0;
    };
    /*
      Both includes live in ~/.config/kitty and are generated outside Nix:
      - themes/noctalia.conf is written by Noctalia's kitty template
        (colors follow the shell theme).
      - opacity.conf is written by `kitty opacity` (scripts/kitty.zsh).
    */
    extraConfig = ''
      include themes/noctalia.conf
      include opacity.conf
    '';
  };
}
