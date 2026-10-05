{
  stdenvNoCC,
  desktop-icons-src,
  yaru-theme,
}:

stdenvNoCC.mkDerivation {
  pname = "yaru-custom";
  version = "1.0.0";

  dontUnpack = true;

  installPhase = ''
    runHook preInstall

    mkdir -p $out/share/icons/Yaru-Custom/apps/scalable

    for icon in proton-mail proton-pass protontricks protonvpn veracrypt vesktop; do
      cp ${desktop-icons-src}/icons/applications/$icon.svg \
        $out/share/icons/Yaru-Custom/apps/scalable/
    done

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

    runHook postInstall
  '';

  propagatedBuildInputs = [ yaru-theme ];
}
