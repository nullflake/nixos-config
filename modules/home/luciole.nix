{
  config,
  lib,
  osConfig,
  pkgs,
  ...
}:
let
  inherit (import ../../lib/places.nix { inherit config lib; }) home folders configDirs;
  toml = pkgs.formats.toml { };

  settings = toml.generate "luciole-defaults.toml" {
    browser = {
      view_mode = "grid";
      chooser_view_mode = "grid";
      operations_button = "busy";
    };
  };
  folderViews = toml.generate "luciole-default-folder-views.toml" {
    schema_version = 1;
    folders = [ ];
  };

  folderPlaces = [ home ] ++ folders;
  localPlaces = folderPlaces ++ configDirs;
  places = toml.generate "luciole-initial-places.toml" {
    schema_version = 1;
    places_customized = true;
    bookmarks = localPlaces ++ [
      {
        uri = "trash:///";
        label = "Trash";
      }
    ];
    place_separators = [
      (builtins.length folderPlaces)
      (builtins.length localPlaces)
    ];
  };
  resetLuciole = import ../../lib/resetHomeFiles.nix { inherit lib pkgs; } {
    name = "luciole-reset";
    marker = "${config.xdg.stateHome}/luciole/.home-manager-generation";
    files = [
      {
        source = places;
        target = "${config.xdg.stateHome}/luciole/state.toml";
      }
      {
        source = folderViews;
        target = "${config.xdg.stateHome}/luciole/folder_views.toml";
      }
      {
        source = "/dev/null";
        target = "${config.xdg.configHome}/luciole/settings.toml";
      }
    ];
  };
in
{
  xdg.configFile."luciole/config.toml".source = pkgs.runCommand "luciole-config.toml" { } ''
    ${lib.getExe osConfig.programs.luciole.package} config validate ${settings}
    cp ${settings} "$out"
  '';

  # Publishing the shared GTK list after state.toml lets Luciole reload both.
  home.activation.lucioleReset =
    lib.hm.dag.entryBetween [ "gtkBookmarksReset" ] [ "linkGeneration" ]
      ''
        if ! run ${lib.getExe resetLuciole} "$newGenPath" "''${oldGenPath-}"; then
          warnEcho "Could not reset Luciole's configuration."
        fi
      '';
}
