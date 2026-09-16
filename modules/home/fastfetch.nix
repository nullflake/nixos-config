{ flakeDir, ... }:
{
  programs.fastfetch = {
    enable = true;
  };

  home.file.".config/fastfetch/config.jsonc".text =
    builtins.replaceStrings [ "/etc/nixos" ] [ flakeDir ]
      (builtins.readFile ../../assets/fastfetch.jsonc);
}
