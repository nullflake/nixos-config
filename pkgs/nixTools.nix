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
  # Keep the entry points next to their Python modules.
  scripts = runCommand "nix-tools" { } ''
    mkdir -p $out
    cp ${../scripts/nixTools/upstream.py} $out/upstream.py
    cp ${../scripts/nixTools/livecheck.py} $out/livecheck.py
    cp -r ${../scripts/nixTools/search} $out/search
  '';
  command =
    name: entryPoint: dependencies: arguments: environment:
    writeShellApplication {
      inherit name;
      runtimeInputs = [ python ] ++ dependencies;
      text = ''
        ${environment}
        exec python3 ${entryPoint} ${arguments} "$@"
      '';
    };
in
{
  packageIndex = command "package-index" "-P -m search.cli" [ brotli systemd ] "" (
    ''
      export PYTHONPATH=${scripts}
    ''
    + lib.optionalString (homeManagerOptions != null) ''
      export NIXCTL_HOME_MANAGER_OPTIONS=${lib.escapeShellArg homeManagerOptions.catalog}
      export NIXCTL_HOME_MANAGER_REVISIONS=${lib.escapeShellArg (builtins.toJSON homeManagerOptions.revisions)}
    ''
  );
  livecheck = command "nix-livecheck" "${scripts}/livecheck.py" [
    git
    libnotify
  ] "--notify-icon ${notificationIcon}" "";
  upstream = command "nix-upstream" "${scripts}/upstream.py" [ ] "" "";
}
