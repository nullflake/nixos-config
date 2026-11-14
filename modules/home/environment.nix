{ flakeDir, ... }:
{
  home.sessionVariables = {
    /*
      cfg.zsh uses this checkout for Git operations; nixctl.zsh updates
      flake.lock here. Both need the writable checkout at runtime.
    */
    FLAKE = flakeDir;
    NH_FLAKE = flakeDir;
  };
}
