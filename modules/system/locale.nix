{
  # Set the system time zone
  time.timeZone = "Europe/Istanbul";

  # Set the primary system language and locale settings
  i18n.defaultLocale = "en_US.UTF-8";

  # Regional formatting settings (currency, time, numbers, etc.)
  i18n.extraLocaleSettings = {
    LC_ADDRESS = "tr_TR.UTF-8";
    LC_IDENTIFICATION = "tr_TR.UTF-8";
    LC_MEASUREMENT = "tr_TR.UTF-8";
    LC_MONETARY = "tr_TR.UTF-8";
    LC_NAME = "tr_TR.UTF-8";
    LC_NUMERIC = "tr_TR.UTF-8";
    LC_PAPER = "tr_TR.UTF-8";
    LC_TELEPHONE = "tr_TR.UTF-8";
    LC_TIME = "en_US.UTF-8";
  };

  # Keyboard layout configuration for graphical environments (X11 / Wayland)
  services.xserver.xkb = {
    layout = "tr";
    variant = "";
  };

  # Keyboard layout for the virtual console (TTY)
  console.keyMap = "trq";
}
