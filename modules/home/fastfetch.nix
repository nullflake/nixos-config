{ ... }:
let
  /*
    Copied into the store on its own, so the logo path is tracked as a
    dependency and only changes when the assets directory changes.
  */
  assets = builtins.path {
    path = ../../assets;
    name = "nixos-assets";
  };
in
{
  programs.fastfetch = {
    enable = true;
  };

  # @assets@ in the jsonc is replaced with the store path of the assets directory.
  home.file.".config/fastfetch/config.jsonc".text =
    builtins.replaceStrings [ "@assets@" ] [ "${assets}" ]
      (builtins.readFile ../../assets/fastfetch.jsonc);
}
