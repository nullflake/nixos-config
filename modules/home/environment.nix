{ flakeRoot, ... }:
{
  home.sessionVariables = {
    EDITOR = "micro";
    VISUAL = "micro";
    MICRO_TRUECOLOR = "1";
    /*
      scripts/cfg.zsh and nixctl.zsh run `git -C "$FLAKE" ...` against
      this path; the store copy has no .git, so it must be flakeRoot.
    */
    FLAKE = flakeRoot;
    NH_FLAKE = flakeRoot;
  };

  home.shellAliases = {
    cat = "bat --paging=never";
    grep = "rg";
    ns = "nixctl switch";
    rc = "rclone sync ~/Documents/rclone protondrive:rclone --copy-links --progress --transfers 4 --checkers 4 --protondrive-replace-existing-draft=true --update --size-only --retries 5 --retries-sleep 5s";

  };
}
