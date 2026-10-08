{ flakeDir, ... }:
{
  home.sessionVariables = {
    EDITOR = "micro";
    VISUAL = "micro";
    MICRO_TRUECOLOR = "1";
    /*
      scripts/cfg.zsh and nixctl.zsh run `git -C "$FLAKE" ...` against
      this path, so it must be the real checkout, not the store copy.
    */
    FLAKE = flakeDir;
    NH_FLAKE = flakeDir;
  };

  home.shellAliases = {
    cat = "bat --paging=never";
    grep = "rg";
    ns = "nixctl switch";

  };
}
