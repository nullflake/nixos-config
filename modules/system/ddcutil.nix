{ username, ... }:
{
  # Loads i2c-dev, creates the "i2c" group and installs the udev rule
  hardware.i2c.enable = true;

  # Keeps access working outside a local seat (e.g. SSH)
  users.users."${username}".extraGroups = [ "i2c" ];
}
