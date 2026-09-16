{ lib, ... }:
let
  zshDir = ../../scripts;
  zshFiles = builtins.attrNames (builtins.readDir zshDir);

  # Concatenate the content of all .zsh files into a single string
  combinedZsh = lib.concatStringsSep "\n" (
    map (file: builtins.readFile (zshDir + "/${file}")) zshFiles
  );
in
{
  programs.zsh = {
    enable = true;
    autosuggestion.enable = true;
    syntaxHighlighting.enable = true;
    historySubstringSearch.enable = true;

    history = {
      size = 50000;
      save = 50000;
      ignoreDups = true;
      ignoreSpace = true;
      extended = true;
      share = true;
    };

    initContent = ''
      # Prevent paste errors with '#' comments
      setopt INTERACTIVE_COMMENTS

      # Automatically loaded modules from dotfiles/zsh/
      ${combinedZsh}
    '';
  };
}
