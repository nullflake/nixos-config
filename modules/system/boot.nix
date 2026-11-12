{ pkgs, ... }:

let
  # Convert the wallpaper to PNG for Limine and crop to 16:9 without stretching.
  bootWallpaper = pkgs.runCommand "limine-wallpaper.png" {
    nativeBuildInputs = [ pkgs.imagemagick ];
  } ''
    magick ${../../assets/images/wallpaper} \
      -auto-orient -resize '2560x1440^' -gravity center -extent 2560x1440 \
      -background black -alpha remove -alpha off -strip \
      -define png:color-type=2 "PNG:$out"
  '';

  tomorrow = (builtins.fromJSON (builtins.readFile ../../assets/noctalia/palettes/tomorrow.json)).dark;
  hex = color: builtins.substring 1 6 color;
  palette = colors: builtins.concatStringsSep ";" (
    map (name: hex colors.${name}) [
      "black" "red" "green" "yellow" "blue" "magenta" "cyan" "white"
    ]
  );
in
{
  boot.loader = {
    limine = {
      enable = true;
      efiSupport = true;
      biosSupport = false;
      efiInstallAsRemovable = false;
      maxGenerations = 10;

      # Hand Windows boot back to firmware via its existing EFI entry.
      extraEntries = ''
        /Windows
          protocol: efi_boot_entry
          entry: Windows Boot Manager
      '';

      # Disable NixOS-managed signing; this does not change firmware Secure Boot.
      secureBoot.enable = false;

      style = {
        wallpapers = [ bootWallpaper ];
        wallpaperStyle = "centered";
        backdrop = hex tomorrow.mSurface;

        interface = {
          resolution = "2560x1440";
          branding = "NixOS";
          brandingColor = hex tomorrow.mPrimary;
          helpColor = hex tomorrow.mOnSurfaceVariant;
          helpColorBright = hex tomorrow.terminal.normal.yellow;
        };

        graphicalTerminal = {
          font.scale = "1x1";
          foreground = hex tomorrow.terminal.foreground;
          # Limine's first byte is transparency: 0xff shows the wallpaper underneath.
          background = "ff${hex tomorrow.mSurface}";
          brightForeground = hex tomorrow.terminal.bright.white;
          brightBackground = hex tomorrow.mOutline;
          palette = palette tomorrow.terminal.normal;
          brightPalette = palette tomorrow.terminal.bright;
          margin = 112;
          marginGradient = 4;
        };
      };
    };

    timeout = 8;
    efi.canTouchEfiVariables = true;
  };

  # Kernel
  boot.kernelPackages = pkgs.linuxPackages_latest;
}
