{ config, ... }:
{
  # Enable OpenGL / Vulkan graphic drivers, both 64-bit and 32-bit
  hardware.graphics = {
    enable = true;
    enable32Bit = true;
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
    # Keeps GPU power state active to prevent stuttering when opening apps
    nvidiaPersistenced = true;
    # Disable GUI settings app
    nvidiaSettings = false;
    # Use open-source kernel modules (recommended for GTX 16xx / RTX / Turing+ cards)
    open = true;
    # Always use the latest production driver
    package = config.boot.kernelPackages.nvidiaPackages.latest;
  };

  # Hardware acceleration and display settings for Nvidia
  environment.sessionVariables = {
    # Forces VA-API driver to use Nvidia for hardware video decoding
    LIBVA_DRIVER_NAME = "nvidia";
    # Forces OpenGL applications to use the Nvidia vendor library
    __GLX_VENDOR_LIBRARY_NAME = "nvidia";
    # Sets the Generic Buffer Management backend
    GBM_BACKEND = "nvidia-drm";
    # Direct backend for the modern nvidia-vaapi-driver
    NVD_BACKEND = "direct";
    # Enable G-Sync and Variable Refresh Rate (VRR) support for compatible monitors
    __GL_GSYNC_ALLOWED = "1";
    __GL_VRR_ALLOWED = "1";
  };
}
