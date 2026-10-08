{ pkgs, username, ... }:
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

  # Auto stop/start zapret when a VPN interface goes up/down
  networking.networkmanager.dispatcherScripts = [
    {
      source = pkgs.writeShellScript "zapret-vpn-dispatcher" ''
        IFACE="$1"
        ACTION="$2"
        # protonX: ProtonVPN native iface, tunX: OpenVPN-based tunnels
        if [[ "$IFACE" == proton* ]] || [[ "$IFACE" == tun* ]]; then
          case "$ACTION" in
            up|vpn-up)
              ${pkgs.systemd}/bin/systemctl stop zapret.service
              ;;
            down|vpn-down)
              ${pkgs.systemd}/bin/systemctl start zapret.service
              ;;
          esac
        fi
      '';
      # "basic" covers both regular and vpn up/down events
      type = "basic";
    }
  ];

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
