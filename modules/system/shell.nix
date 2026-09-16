{
  config,
  lib,
  pkgs,
  username,
  ...
}:
{
  options.custom.user.shell = lib.mkOption {
    type = lib.types.enum [
      "zsh"
      "bash"
      "fish"
    ];
    description = "User default login shell.";
  };

  config = {
    users.users."${username}".shell = pkgs.${config.custom.user.shell};

    programs.zsh.enable = config.custom.user.shell == "zsh";
    programs.fish.enable = config.custom.user.shell == "fish";
  };
}
