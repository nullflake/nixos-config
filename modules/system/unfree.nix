{ config, lib, ... }:
let
  cfg = config.custom.unfree;
in
{
  options.custom.unfree = {
    mode = lib.mkOption {
      type = lib.types.enum [
        "all"
        "none"
        "selected"
      ];

      # No default on purpose — every host must pick one explicitly.
      description = ''
        Unfree package policy:
        - "all": allow all unfree packages
        - "none": disallow unfree packages entirely
        - "selected": allow only packages listed in custom.unfree.packages
      '';
    };

    packages = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];

      description = ''
        Package names allowed when custom.unfree.mode is "selected".
        Matched against the package's pname.
      '';

      example = [
        "spotify"
        "steam"
      ];
    };
  };

  config = {
    assertions = [
      {
        assertion = cfg.mode != "selected" || cfg.packages != [ ];
        message = "custom.unfree.packages must not be empty when custom.unfree.mode is \"selected\".";
      }
    ];

    nixpkgs.config.allowUnfree = cfg.mode == "all";

    nixpkgs.config.allowUnfreePredicate = lib.mkIf (cfg.mode == "selected") (
      pkg: builtins.elem (lib.getName pkg) cfg.packages
    );
  };
}
