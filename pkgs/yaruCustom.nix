{
  stdenvNoCC,
  desktop-icons,
  yaru-theme,
}:

stdenvNoCC.mkDerivation {
  pname = "yaru-custom";
  version = "1.0.0";

  dontUnpack = true;

  installPhase = ''
        mkdir -p $out/share/icons/Yaru-Custom/apps/scalable

        cp ${desktop-icons}/icons/applications/proton-mail.svg \
          $out/share/icons/Yaru-Custom/apps/scalable/proton-mail.svg

        cp ${desktop-icons}/icons/applications/proton-pass.svg \
          $out/share/icons/Yaru-Custom/apps/scalable/proton-pass.svg

        cp ${desktop-icons}/icons/applications/protontricks.svg \
          $out/share/icons/Yaru-Custom/apps/scalable/protontricks.svg

        cp ${desktop-icons}/icons/applications/protonvpn.svg \
          $out/share/icons/Yaru-Custom/apps/scalable/protonvpn.svg

        cp ${desktop-icons}/icons/applications/veracrypt.svg \
          $out/share/icons/Yaru-Custom/apps/scalable/veracrypt.svg

        cp ${desktop-icons}/icons/applications/vesktop.svg \
          $out/share/icons/Yaru-Custom/apps/scalable/vesktop.svg

        cat > $out/share/icons/Yaru-Custom/index.theme <<EOF
    [Icon Theme]
    Name=Yaru-Custom
    Comment=Yaru with custom application icons
    Inherits=Yaru-purple,Adwaita,hicolor
    Directories=apps/scalable

    [apps/scalable]
    Size=48
    MinSize=16
    MaxSize=256
    Type=Scalable
    Context=Applications
    EOF
  '';

  propagatedBuildInputs = [ yaru-theme ];
}
