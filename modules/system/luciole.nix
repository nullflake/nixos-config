{
  config,
  inputs,
  lib,
  ...
}:
let
  cfg = config.programs.luciole;
in
{
  imports = [ inputs.luciole.nixosModules.default ];

  programs.luciole.enable = true;

  xdg.portal.extraPortals = lib.optional (cfg.enable && cfg.package != null) cfg.package;
}
