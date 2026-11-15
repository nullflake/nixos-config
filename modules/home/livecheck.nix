{ pkgs, ... }:
let
  tools = pkgs.callPackage ../../pkgs/sourceTools.nix { };
in
{
  home.packages = [
    tools.livecheck
    tools.upstream
  ];
}
