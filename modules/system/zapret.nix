{
  config,
  lib,
  pkgs,
  username,
  ...
}:
let
  queueNum = toString config.services.zapret.qnum;
  cleanupFirewall = ''
    (
      for zapretTable in ${pkgs.iptables}/bin/iptables ${pkgs.iptables}/bin/ip6tables; do
        removeZapretRule() {
          while "$zapretTable" -w -t mangle -C POSTROUTING "$@" 2>/dev/null; do
            "$zapretTable" -w -t mangle -D POSTROUTING "$@"
          done
        }

        # Remove all copies of the automatic TCP rules, including disabled HTTP rules.
        for zapretPort in 80 443; do
          removeZapretRule -p tcp --dport "$zapretPort" \
            -m connbytes --connbytes-dir=original --connbytes-mode=packets --connbytes 1:6 \
            -m mark ! --mark 0x40000000/0x40000000 \
            -j NFQUEUE --queue-num ${queueNum} --queue-bypass
        done
        removeZapretRule -p tcp --dport 80 \
          -m mark ! --mark 0x40000000/0x40000000 \
          -j NFQUEUE --queue-num ${queueNum} --queue-bypass

        # Keep UDP traffic outside the queue when media processing is disabled.
        removeZapretRule -p udp -m multiport --dports 443,50000 \
          -m mark ! --mark 0x40000000/0x40000000 \
          -j NFQUEUE --queue-num ${queueNum} --queue-bypass
      done
    )
  '';

  canStart = pkgs.writeShellScript "zapret-can-start" ''
    export LC_ALL=C
    if ! devices="$(${pkgs.coreutils}/bin/timeout 5s ${pkgs.networkmanager}/bin/nmcli \
      --terse --escape no --fields DEVICE,STATE device status)"; then
      echo "Cannot determine VPN state; leaving zapret stopped." >&2
      exit 2
    fi

    while IFS=: read -r iface state; do
      case "$iface" in
        proton*|tun*)
          case "$state" in
            connected*|connecting*|disconnecting*) exit 1 ;;
          esac
          ;;
      esac
    done <<< "$devices"
    exit 0
  '';
in
{
  services.zapret = {
    enable = true;
    configureFirewall = true;
    httpSupport = false;
    udpSupport = false;
    params = [
      "--filter-tcp=443"
      "--filter-l7=tls"
      # Exclude private, shared, loopback, link-local, multicast and broadcast destinations.
      (
        "--ipset-exclude-ip="
        + builtins.concatStringsSep "," [
          "10.0.0.0/8"
          "100.64.0.0/10"
          "127.0.0.0/8"
          "169.254.0.0/16"
          "172.16.0.0/12"
          "192.168.0.0/16"
          "224.0.0.0/4"
          "255.255.255.255/32"
          "::1/128"
          "fc00::/7"
          "fe80::/10"
          "ff00::/8"
        ]
      )
      # Limit fake packets to nearby hops so DPI sees them before they expire en route to the server.
      "--dpi-desync=fake"
      "--dpi-desync-ttl=4"
    ];
  };

  # The upstream module inserts rules on each start; clean them before re-adding them.
  networking.firewall = {
    extraCommands = lib.mkBefore cleanupFirewall;
    extraStopCommands = cleanupFirewall;
  };

  # Check VPN state on every start, including boot and configuration switches.
  systemd.services.zapret = {
    after = [ "NetworkManager.service" ];
    serviceConfig.ExecCondition = canStart;
  };

  # Reconcile current VPN state instead of trusting potentially stale events.
  networking.networkmanager.dispatcherScripts = [
    {
      source = pkgs.writeShellScript "zapret-vpn-dispatcher" ''
        IFACE="$1"
        ACTION="$2"
        # protonX: ProtonVPN native iface, tunX: OpenVPN-based tunnels
        if [[ "$IFACE" == proton* ]] || [[ "$IFACE" == tun* ]]; then
          case "$ACTION" in
            up|vpn-up|down|vpn-down)
              if ${canStart}; then
                ${pkgs.systemd}/bin/systemctl start zapret.service
              else
                ${pkgs.systemd}/bin/systemctl stop zapret.service
              fi
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
