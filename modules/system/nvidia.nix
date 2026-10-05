{ config, pkgs, ... }:
{
  # Enable OpenGL / Vulkan graphic drivers, both 64-bit and 32-bit
  hardware.graphics = {
    enable = true;
    enable32Bit = true;

    # VA-API -> NVDEC bridge; LIBVA_DRIVER_NAME=nvidia below needs it
    extraPackages = [ pkgs.nvidia-vaapi-driver ];
  };

  # Load Nvidia driver for X11 and Wayland sessions
  services.xserver.videoDrivers = [ "nvidia" ];

  hardware.nvidia = {
    # Required for Wayland compositors/sessions (Hyprland, GNOME Wayland, etc.)
    modesetting.enable = true;
    # NixOS power management integration (handles system suspend/resume)
    powerManagement.enable = true;
    powerManagement.finegrained = false;
    powerManagement.kernelSuspendNotifier = true;
    # Keeps the driver initialized without a client attached
    nvidiaPersistenced = true;
    # Disable GUI settings app
    nvidiaSettings = false;
    # Use open-source kernel modules (Turing and newer)
    open = true;
    # Newest stable driver branch in nixpkgs (paired with linuxPackages_latest)
    package = config.boot.kernelPackages.nvidiaPackages.latest;
  };

  # Hardware acceleration and display settings for Nvidia
  environment.sessionVariables = {
    # Makes libva load nvidia-vaapi-driver for hardware video decoding
    LIBVA_DRIVER_NAME = "nvidia";
    # Forces OpenGL applications to use the Nvidia vendor library
    __GLX_VENDOR_LIBRARY_NAME = "nvidia";
    # Sets the Generic Buffer Management backend
    GBM_BACKEND = "nvidia-drm";
    # nvidia-vaapi-driver backend (direct is already the default)
    NVD_BACKEND = "direct";
    # G-Sync/VRR for Xwayland OpenGL/Vulkan apps (games). Wayland-native
    # VRR is controlled by the compositor (Hyprland misc.vrr), not these.
    __GL_GSYNC_ALLOWED = "1";
    __GL_VRR_ALLOWED = "1";
  };
}
