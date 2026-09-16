{ username, ... }:
{
  services.zapret = {
    enable = true;
    configureFirewall = true;
    httpSupport = true;
    httpMode = "first";
    udpSupport = true;
    udpPorts = [
      "443"
      "50000"
    ];
    params = [
      "--dpi-desync=fake"
      "--dpi-desync-ttl=8"
    ];
  };

  # Allow toggling zapret without a password prompt
  security.sudo.extraRules = [
    {
      users = [ username ];
      commands = [
        {
          command = "/run/current-system/sw/bin/systemctl start zapret";
          options = [ "NOPASSWD" ];
        }
        {
          command = "/run/current-system/sw/bin/systemctl stop zapret";
          options = [ "NOPASSWD" ];
        }
      ];
    }
  ];
}
