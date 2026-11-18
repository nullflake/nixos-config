{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.internal.veracrypt;
  home = config.home.homeDirectory;
in
{
  options.internal.veracrypt.directory = lib.mkOption {
    type = lib.types.str;
    description = "Directory relative to the user's home containing .hc files and their mount directories.";
  };

  config = {
    home.packages = [ pkgs.veracrypt ];
    programs.zsh.initContent = ''
      VC_DIRECTORY=${lib.escapeShellArg "${home}/${cfg.directory}"}
    '';
  };
}
