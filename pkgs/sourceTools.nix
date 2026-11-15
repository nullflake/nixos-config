{
  python3,
  runCommand,
  writeShellApplication,
  brotli,
  systemd,
  git,
  libnotify,
  imagemagick,
}:
let
  python = python3.withPackages (ps: [ ps.wcwidth ]);
  notificationIcon =
    runCommand "nix-livecheck-icon.png"
      {
        nativeBuildInputs = [ imagemagick ];
      }
      ''
        magick ${../assets/images/nixosLogo1.webp} -resize 128x128 PNG:$out
      '';
  # Keep module filenames together so all entry points import the same code.
  scripts = runCommand "nix-source-tools" { } ''
    mkdir -p $out
    cp ${../scripts/upstream.py} $out/upstream.py
    cp ${../scripts/livecheck.py} $out/livecheck.py
    cp ${../scripts/packageIndex.py} $out/packageIndex.py
  '';
  command =
    name: script: dependencies: arguments:
    writeShellApplication {
      inherit name;
      runtimeInputs = [ python ] ++ dependencies;
      text = ''
        exec python3 ${scripts}/${script} ${arguments} "$@"
      '';
    };
in
{
  packageIndex = command "package-index" "packageIndex.py" [ brotli systemd ] "";
  livecheck = command "nix-livecheck" "livecheck.py" [
    git
    libnotify
  ] "--notify-icon ${notificationIcon}";
  upstream = command "nix-upstream" "upstream.py" [ ] "";
}
