{ flakeDir, ... }:
{
  programs.nh = {
    enable = true;
    flake = flakeDir;
    clean.enable = true;
    clean.extraArgs = "--keep-since 3d --keep 10";
  };
}
