{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (import ../../lib/places.nix { inherit config lib; }) folders configDirs;
  bookmarks = pkgs.writeText "gtk-bookmarks" (
    lib.concatMapStrings (bookmark: "${bookmark.uri}\n") (folders ++ configDirs)
  );
  resetBookmarks = import ../../lib/resetHomeFiles.nix { inherit lib pkgs; } {
    name = "gtk-bookmarks-reset";
    marker = "${config.xdg.stateHome}/gtk-3.0/.home-manager-generation";
    files = [
      {
        source = bookmarks;
        target = "${config.xdg.configHome}/gtk-3.0/bookmarks";
      }
    ];
  };
in
{
  home.activation.gtkBookmarksReset = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
    if ! run ${lib.getExe resetBookmarks} "$newGenPath" "''${oldGenPath-}"; then
      warnEcho "Could not reset shared GTK bookmarks."
    fi
  '';
}
