{
  python3,
  runCommand,
  writeShellApplication,
  brotli,
  systemd,
  git,
  libnotify,
  imagemagick,
  lib,
  homeManagerOptions ? null,
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
  scripts = runCommand "nix-tools" { } ''
    mkdir -p $out
    cp ${../scripts/nixTools/upstream.py} $out/upstream.py
    cp ${../scripts/nixTools/livecheck.py} $out/livecheck.py
    cp ${../scripts/nixTools/packageIndex.py} $out/packageIndex.py
  '';
  command =
    name: script: dependencies: arguments: environment:
    writeShellApplication {
      inherit name;
      runtimeInputs = [ python ] ++ dependencies;
      text = ''
        ${environment}
        exec python3 ${scripts}/${script} ${arguments} "$@"
      '';
    };
in
{
  packageIndex = command "package-index" "packageIndex.py" [ brotli systemd ] "" (
    lib.optionalString (homeManagerOptions != null) ''
      export NIXCTL_HOME_MANAGER_OPTIONS=${lib.escapeShellArg homeManagerOptions.catalog}
      export NIXCTL_HOME_MANAGER_REVISIONS=${lib.escapeShellArg (builtins.toJSON homeManagerOptions.revisions)}
    ''
  );
  livecheck = command "nix-livecheck" "livecheck.py" [
    git
    libnotify
  ] "--notify-icon ${notificationIcon}" "";
  upstream = command "nix-upstream" "upstream.py" [ ] "" "";
}
