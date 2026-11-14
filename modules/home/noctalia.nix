{ lib, pkgs, ... }:
let
  configDir = ../../assets/noctalia;
in
{
  xdg.configFile =
    lib.listToAttrs (
      map (file: {
        name = "noctalia/${lib.removePrefix "${toString configDir}/" (toString file)}";
        value.source = file;
      }) (lib.filesystem.listFilesRecursive configDir)
    )
    // {
      "noctalia/settings.toml".source = pkgs.replaceVars (configDir + "/settings.toml") {
        wallpaper = ../../assets/images/wallpaper;
      };
    };
}
