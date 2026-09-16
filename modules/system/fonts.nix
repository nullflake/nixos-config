{ pkgs, ... }:
{
  fonts = {
    enableDefaultPackages = true;

    # Installed system fonts
    packages = with pkgs; [
      inter
      nerd-fonts.jetbrains-mono
      noto-fonts-color-emoji
      rubik
    ];

    fontconfig = {
      enable = true;

      # Text rendering optimizations
      antialias = true;
      hinting = {
        enable = true;
        style = "slight"; # Keeps letterforms natural at higher DPI
      };

      subpixel = {
        rgba = "rgb"; # Standard subpixel layout for desktop monitors
        lcdfilter = "default";
      };

      # Default system-wide font aliases
      defaultFonts = {
        sansSerif = [ "Inter" ];
        serif = [ "Inter" ];
        monospace = [ "JetBrainsMono Nerd Font" ];
        emoji = [ "Noto Color Emoji" ];
      };
    };
  };
}
