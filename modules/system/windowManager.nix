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

  options.internal.windowManager = lib.mkOption {
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
    (lib.mkIf (builtins.elem "hyprland" config.internal.windowManager) {
      programs.hyprland = {
        enable = true;
        xwayland.enable = true;
        # Match the cached nixpkgs package instead of rebuilding without UWSM.
        withUWSM = true;
      };
    })

    (lib.mkIf (builtins.elem "umbriel" config.internal.windowManager) {
      programs.umbriel.enable = true;
    })
  ];
}
