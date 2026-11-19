{ pkgs, ... }:
{
  home.packages = [
    (pkgs.nautilus.overrideAttrs (old: {
      postPatch = (old.postPatch or "") + ''
        substituteInPlace src/nautilus-window-slot.c \
          --replace-fail 'ltr ? "<alt>Left|Back" : "<alt>Right|Back"' \
                         'ltr ? "<alt>Left|Back|BackSpace" : "<alt>Right|Back|BackSpace"'
      '';
    }))
  ];

  dconf.settings."org/gnome/nautilus/list-view".use-tree-view = true;
}
