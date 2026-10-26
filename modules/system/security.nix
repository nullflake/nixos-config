{
  security.polkit.enable = true;

  services.gnome.gnome-keyring.enable = true;

  # Auto-unlock GNOME Keyring on login via greetd
  security.pam.services.greetd.enableGnomeKeyring = true;
}
