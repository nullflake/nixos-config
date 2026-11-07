{
  flakeDir,
  osConfig,
  pkgs,
  ...
}:
let
  hostConfig =
    "(builtins.getFlake ${builtins.toJSON flakeDir})"
    + ".nixosConfigurations.${builtins.toJSON osConfig.networking.hostName}";
in
{
  programs.zed-editor = {
    enable = true;

    # FHS package so dynamically linked extension binaries work on NixOS
    package = pkgs.zed-editor-fhs;

    mutableUserSettings = true;
    mutableUserKeymaps = true;

    extensions = [
      "nix"
      "lua"
      "luau"
      "toml"
    ];

    extraPackages = with pkgs; [
      nixd
      nixfmt
    ];

    userSettings = {
      format_on_save = "off";
      telemetry = {
        diagnostics = false;
        metrics = false;
      };
      vim_mode = false;
      autosave = "on_focus_change";
      languages.Nix.language_servers = [ "nixd" ];
      lsp = {
        nixd.binary.path = "${pkgs.nixd}/bin/nixd";
        nixd.settings = {
          nixpkgs.expr = "${hostConfig}.pkgs";
          options = {
            nixos.expr = "${hostConfig}.options";
            home-manager.expr = "${hostConfig}.options.home-manager.users.type.getSubOptions []";
          };
        };
        # Register Hyprland's 'hl' as a recognized global for Lua LSP
        lua-language-server.settings.Lua.diagnostics.globals = [ "hl" ];
      };
    };
  };
}
