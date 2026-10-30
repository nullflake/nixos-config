{
  services.gvfs.enable = true;
  services.udisks2.enable = true;
  services.fstrim.enable = true;

  services.smartd = {
    enable = true;
    autodetect = true;

    notifications = {
      # Forward SMART alerts to the desktop notification service.
      systembus-notify.enable = true;
      /*
        Keep wall enabled: nixpkgs currently gates the notification hook on
        mail, wall or X11, overlooking systembus-notify alone.
      */
      wall.enable = true;
      x11.enable = false;
      mail.enable = false;
    };
  };
}
