{ lib, pkgs, ... }:
let
  zshDir = ../../scripts;

  /*
    Only regular *.zsh files (skips directories, .swp, .md, etc.).
    attrNames returns names sorted alphabetically, so load order is deterministic.
  */
  zshFiles = lib.attrNames (
    lib.filterAttrs (name: type: type == "regular" && lib.hasSuffix ".zsh" name) (
      builtins.readDir zshDir
    )
  );

  /*
    Path to one script. Interpolating this copies only that file into the store,
    unlike "${zshDir}/${file}", which would copy the entire directory.
  */
  scriptPath = file: zshDir + "/${file}";

  /*
    Syntax-check every script in one derivation (zsh -n).
    A parse error fails the system build, so syntactically invalid shell
    scripts are never deployed.
  */
  checkedScripts = pkgs.runCommand "zsh-scripts-checked" { nativeBuildInputs = [ pkgs.zsh ]; } ''
    mkdir -p $out
    ${lib.concatMapStringsSep "\n" (file: ''
      zsh -f -n ${scriptPath file}
      cp ${scriptPath file} $out/${file}
    '') zshFiles}
  '';

  # Source checked store paths instead of embedding file contents in the config.
  sourceLines = lib.concatMapStringsSep "\n" (file: "source ${checkedScripts}/${file}") zshFiles;
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

      # Checked modules from /scripts (alphabetical order)
      ${sourceLines}
    '';
  };
}
