{ flakeDir, ... }:
{
  programs.nh = {
    enable = true;
    /*
      nh writes to flake.lock and operates on the git checkout,
      so it needs the real directory, not the store copy.
    */
    flake = flakeDir;
    clean.enable = true;
    clean.extraArgs = "--keep-since 3d --keep 10";
  };
}
