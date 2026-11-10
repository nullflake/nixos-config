{
  config,
  inputs,
  lib,
  ...
}:

{
  imports = [
    inputs.umbriel.nixosModules.default
  ];

  options.custom.windowManager = lib.mkOption {
    type = lib.types.listOf (
      lib.types.enum [
        "hyprland"
        "umbriel"
      ]
    );
    # No default on purpose — every host must pick explicitly.
    description = "Window managers installed and offered at the greeter.";
  };

  config = lib.mkMerge [
    (lib.mkIf (builtins.elem "hyprland" config.custom.windowManager) {
      programs.hyprland = {
        enable = true;
        xwayland.enable = true;
        # Match the cached nixpkgs package instead of rebuilding without UWSM.
        withUWSM = true;
      };
    })

    (lib.mkIf (builtins.elem "umbriel" config.custom.windowManager) {
      programs.umbriel.enable = true;
    })
  ];
}
