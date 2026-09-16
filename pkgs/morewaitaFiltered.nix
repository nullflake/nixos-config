{ morewaita-icon-theme }:

morewaita-icon-theme.overrideAttrs (oldAttrs: {
  postInstall = (oldAttrs.postInstall or "") + ''
    keep="$TMPDIR/morewaita-keep"

    # Preserve selected application icons.
    mkdir -p "$keep"

    for app in \
      dev.vencord.Vesktop \
      org.winehq.Wine \
      proton-pass \
      veracrypt \
      veracrypt.xpm \
      vesktop \
      wine \
      winetricks
    do
      find "$out/share/icons/MoreWaita"/*/apps \
        -name "$app.svg" \
        -exec cp --parents {} "$keep" \;
    done

    # Let all other application icons fall back to Yaru-purple.
    rm -rf "$out/share/icons/MoreWaita"/*/apps/*

    # Restore the selected MoreWaita application icons.
    if [ -d "$keep$out" ]; then
      cp -a "$keep$out"/. "$out"/
    fi

    # Remove broken symlinks left behind by stripping.
    find "$out/share/icons/MoreWaita" -xtype l -delete

    # Set fallback icon inheritance to Yaru-purple.
    sed -i 's/^Inherits=.*/Inherits=Yaru-purple,Adwaita,hicolor/g' "$out/share/icons/MoreWaita/index.theme"
  '';
})
