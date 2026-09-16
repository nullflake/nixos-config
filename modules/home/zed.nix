{ pkgs, ... }:
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
      "toml"
    ];

    extraPackages = with pkgs; [
      nil
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
      lsp = {
        nixd = {
          binary = {
            path = "${pkgs.nixd}/bin/nixd";
          };
        };
        nil = {
          binary = {
            path = "${pkgs.nil}/bin/nil";
          };
        };
        # Register Hyprland's 'hl' as a recognized global for Lua LSP
        lua-language-server = {
          settings = {
            Lua = {
              diagnostics = {
                globals = [ "hl" ];
              };
            };
          };
        };
      };
    };
  };
}
