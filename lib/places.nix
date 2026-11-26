{ config, lib }:
let
  inherit (config.home) homeDirectory;
  inherit (config.xdg) userDirs;
  fileUri = path: "file://${lib.concatMapStringsSep "/" lib.escapeURL (lib.splitString "/" path)}";
  bookmark = path: {
    uri = fileUri path;
    label = baseNameOf path;
  };
in
{
  home = {
    uri = fileUri homeDirectory;
    label = "Home";
  };

  folders =
    map bookmark [
      userDirs.download
      userDirs.documents
      userDirs.pictures
      userDirs.videos
    ]
    ++ [ ((bookmark userDirs.extraConfig.PRIVATE) // { icon = "lock"; }) ];

  configDirs = map bookmark [
    "${homeDirectory}/.config"
    "${homeDirectory}/.local"
  ];
}
