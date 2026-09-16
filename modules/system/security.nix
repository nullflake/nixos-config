{
  # Enable Polkit for privilege management
  security.polkit.enable = true;

  # Enable GNOME Keyring daemon
  services.gnome.gnome-keyring.enable = true;

  # Auto-unlock GNOME Keyring on login via greetd
  security.pam.services.greetd.enableGnomeKeyring = true;
}
