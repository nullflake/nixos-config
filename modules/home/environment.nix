{ flakeDir, ... }:
{
  home.sessionVariables = {
    EDITOR = "micro";
    VISUAL = "micro";
    MICRO_TRUECOLOR = "1";
    /*
      cfg.zsh uses this checkout for Git operations; nixctl.zsh updates
      flake.lock here. Both need the writable checkout at runtime.
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
