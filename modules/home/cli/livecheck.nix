{ pkgs, ... }:
let
  tools = pkgs.callPackage ../../../pkgs/nixTools.nix { };
in
{
  home.packages = [
    tools.livecheck
    tools.upstream
  ];
}
