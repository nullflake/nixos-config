{
  stdenvNoCC,
  desktop-icons-src,
}:

stdenvNoCC.mkDerivation {
  pname = "desktop-icons";
  version = "unstable";

  src = desktop-icons-src;

  installPhase = ''
    mkdir -p $out/icons/applications
    cp icons/applications/*.svg $out/icons/applications/
  '';

  meta = {
    description = "Custom desktop icons";
    homepage = "https://github.com/nullflake/desktop-icons";
  };
}
