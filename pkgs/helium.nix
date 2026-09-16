{
  lib,
  stdenv,
  fetchurl,
  dpkg,
  patchelf,
  wrapGAppsHook3,
  makeWrapper,

  # Desktop integration
  glib,
  gsettings-desktop-schemas,
  gtk3,
  gtk4,
  adwaita-icon-theme,

  # Chromium security and runtime
  nss,
  nspr,
  expat,
  zlib,
  libxml2,
  libuuid,
  libkrb5,
  snappy,

  # Graphics
  libGL,
  libgbm,
  libdrm,
  libxkbcommon,
  libX11,
  libXcomposite,
  libXdamage,
  libXext,
  libXfixes,
  libXrandr,
  libXrender,
  libxcb,
  libxshmfence,
  libXi,
  libXcursor,
  libXft,
  libXScrnSaver,
  libXtst,
  libSM,
  libICE,
  libXt,

  # Audio and video
  alsa-lib,
  ffmpeg,
  libva,
  pipewire,

  # Wayland and system integration
  wayland,
  vulkan-loader,
  dbus,
  cups,
  udev,
  systemd,

  # GTK rendering
  pango,
  cairo,
  gdk-pixbuf,
  atk,
  at-spi2-atk,
  at-spi2-core,
  freetype,
  fontconfig,

  # Runtime command-line utilities
  xdg-utils,
  coreutils,

  flags ? [ ],
}:

let
  pname = "helium";

  # Version and hashes are maintained by the helium bump helper.
  sources = builtins.fromJSON (builtins.readFile ./helium.json);
  version = sources.version;

  # Helium publishes separate Debian packages for each supported Linux architecture.
  suffix =
    {
      x86_64-linux = "amd64";
      aarch64-linux = "arm64";
    }
    .${stdenv.hostPlatform.system} or (throw "Unsupported system: ${stdenv.hostPlatform.system}");

  hash =
    if stdenv.hostPlatform.system == "x86_64-linux" then
      sources.hash
    else if stdenv.hostPlatform.system == "aarch64-linux" then
      sources.aarch64Hash
    else
      throw "Unsupported system: ${stdenv.hostPlatform.system}";

  src = fetchurl {
    url = "https://github.com/imputnet/helium-linux/releases/download/${version}/helium-bin_${version}-1_${suffix}.deb";
    inherit hash;
  };

  inherit (lib) makeLibraryPath makeSearchPathOutput;

  runtimeLibs = [
    # Graphics and GPU acceleration
    libGL
    libgbm
    libdrm
    libxkbcommon
    libX11
    libXcomposite
    libXdamage
    libXext
    libXfixes
    libXrandr
    libXrender
    libxcb
    libxshmfence
    libXi
    libXcursor
    libXft
    libXScrnSaver
    libXtst
    libSM
    libICE
    libXt

    # Audio and video
    alsa-lib
    ffmpeg
    libva
    pipewire

    # Wayland
    wayland
    vulkan-loader

    # GTK and desktop rendering
    glib
    gtk3
    gtk4
    pango
    cairo
    gdk-pixbuf
    atk
    at-spi2-atk
    at-spi2-core

    # Font and text rendering
    freetype
    fontconfig

    # Chromium runtime and security
    nss
    nspr
    expat
    zlib
    libxml2
    libuuid
    libkrb5
    snappy

    # Desktop and system services
    dbus
    cups
    udev
    systemd
  ];

  runtimeLibPath =
    makeLibraryPath runtimeLibs
    + lib.optionalString stdenv.hostPlatform.is64bit (
      ":" + makeSearchPathOutput "lib" "lib64" runtimeLibs
    )
    + ":$out/opt/helium";

in
stdenv.mkDerivation {
  inherit pname version src;

  # Modern Nix practices
  __structuredAttrs = true;
  strictDeps = true;

  dontConfigure = true;
  dontBuild = true;
  dontStrip = true;
  dontPatchELF = true;

  nativeBuildInputs = [
    dpkg
    patchelf
    wrapGAppsHook3
    makeWrapper
  ];

  buildInputs = [
    glib
    gsettings-desktop-schemas
    gtk3
    gtk4
    adwaita-icon-theme
  ];

  unpackPhase = ''
    runHook preUnpack

    ar x "$src"
    tar -xf data.tar.xz

    runHook postUnpack
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p "$out/bin" "$out/opt" "$out/share"

    # Install upstream Helium application.
    cp -r opt/helium "$out/opt/helium"
    cp -r usr/share/* "$out/share/"

    # Patch main Chromium executable.
    patchelf \
      --set-interpreter "$(cat "$NIX_CC/nix-support/dynamic-linker")" \
      --set-rpath "${runtimeLibPath}" \
      "$out/opt/helium/chrome"

    # Crashpad is a separate ELF executable and needs the same runtime setup.
    if [ -f "$out/opt/helium/helium_crashpad_handler" ]; then
      patchelf \
        --set-interpreter "$(cat "$NIX_CC/nix-support/dynamic-linker")" \
        --set-rpath "${runtimeLibPath}" \
        "$out/opt/helium/helium_crashpad_handler"
    fi

    # Patch bundled ANGLE EGL/GLES libraries.
    for lib in \
      "$out/opt/helium/libEGL.so" \
      "$out/opt/helium/libGLESv2.so"
    do
      if [ -f "$lib" ]; then
        patchelf \
          --set-rpath "${runtimeLibPath}" \
          "$lib"
      fi
    done

    # Preserve the upstream launcher when available.
    if [ -f "$out/opt/helium/helium-wrapper" ]; then
      substituteInPlace "$out/opt/helium/helium-wrapper" \
        --replace-fail \
          '$HERE/helium' \
          "$out/opt/helium/chrome"

      ln -s "$out/opt/helium/helium-wrapper" "$out/bin/helium"
    else
      # Fallback for future upstream releases without helium-wrapper.
      makeWrapper "$out/opt/helium/chrome" "$out/bin/helium"
    fi

    # Restore XDG tool paths expected by upstream integration scripts.
    ln -sf "${xdg-utils}/bin/xdg-mime" "$out/opt/helium/xdg-mime"
    ln -sf "${xdg-utils}/bin/xdg-settings" "$out/opt/helium/xdg-settings"

    # Install all available upstream icons.
    for size in 16 24 32 48 64 128 256; do
      icon="$out/opt/helium/product_logo_''${size}.png"
      if [ -f "$icon" ]; then
        mkdir -p "$out/share/icons/hicolor/''${size}x''${size}/apps"
        ln -sf \
          "$icon" \
          "$out/share/icons/hicolor/''${size}x''${size}/apps/helium.png"
      fi
    done

    # Fallback when only the base product logo is available.
    if [ ! -e "$out/share/icons/hicolor/256x256/apps/helium.png" ] \
      && [ -f "$out/opt/helium/product_logo.png" ]; then
      mkdir -p "$out/share/icons/hicolor/256x256/apps"
      ln -sf \
        "$out/opt/helium/product_logo.png" \
        "$out/share/icons/hicolor/256x256/apps/helium.png"
    fi

    # Point the desktop entry to the Nix launcher.
    if [ -f "$out/share/applications/helium.desktop" ]; then
      substituteInPlace "$out/share/applications/helium.desktop" \
        --replace-fail \
          'Exec=helium' \
          "Exec=$out/bin/helium"
    fi

    # Patch GNOME default-application metadata when provided upstream.
    if [ -d "$out/share/gnome-control-center/default-apps" ]; then
      for xml in "$out/share/gnome-control-center/default-apps/"*.xml; do
        if [ -f "$xml" ]; then
          substituteInPlace "$xml" \
            --replace-fail \
              "/opt/helium" \
              "$out/opt/helium"
        fi
      done
    fi

    runHook postInstall
  '';

  preFixup = ''
    gappsWrapperArgs+=(
      --prefix LD_LIBRARY_PATH : "${runtimeLibPath}"
      --prefix PATH : "${
        lib.makeBinPath [
          xdg-utils
          coreutils
        ]
      }"
      --add-flags "\''${NIXOS_OZONE_WL:+\''${WAYLAND_DISPLAY:+--ozone-platform-hint=auto}}"
      --set-default CHROME_VERSION_EXTRA nix
      ${lib.concatMapStringsSep "\n " (flag: "--add-flags ${lib.escapeShellArg flag}") flags}
    )
  '';

  # Verify that the patched launcher and dynamic linker work in the build sandbox.
  doInstallCheck = stdenv.hostPlatform.isLinux;

  installCheckPhase = ''
    runHook preInstallCheck

    "$out/bin/helium" --version

    runHook postInstallCheck
  '';

  meta = {
    homepage = "https://helium.computer";
    description = "Private, fast, and honest web browser based on Chromium";
    license = lib.licenses.gpl3Only;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    platforms = [
      "x86_64-linux"
      "aarch64-linux"
    ];
    mainProgram = "helium";
  };
}
