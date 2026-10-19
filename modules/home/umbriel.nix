{
  config,
  flakeDir,
  lib,
  ...
}:
let
  srcDir = ../../assets/umbriel;
  liveDir = "${flakeDir}/assets/umbriel";

  files = lib.attrNames (
    lib.filterAttrs (
      name: type: type == "regular" && lib.hasSuffix ".toml" name && name != "noctalia.toml"
    ) (builtins.readDir srcDir)
  );

in
{
  xdg.configFile = lib.listToAttrs (
    map (
      name:
      lib.nameValuePair "umbriel/${name}" {
        source = config.lib.file.mkOutOfStoreSymlink "${liveDir}/${name}";
      }
    ) files
  );
}
