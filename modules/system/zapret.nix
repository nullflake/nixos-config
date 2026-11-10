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

  guardPython = pkgs.python3.withPackages (python: [ python.dbus-fast ]);
  vpnGuard = pkgs.writeShellScript "zapretVpnMonitor" ''
    exec ${guardPython}/bin/python3 ${../../scripts/zapretVpnMonitor.py} "$@"
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

  # The guard owns automatic starts. Binding its lifetime also makes manual down
  # and guard crashes stop zapret, without a retry loop undoing a manual stop.
  systemd.services.zapret = {
    wantedBy = lib.mkForce [ ];
    bindsTo = [ "zapret-vpn-monitor.service" ];
    after = [ "zapret-vpn-monitor.service" ];
    serviceConfig = {
      ExecCondition = "${vpnGuard} --check";
      RestartSec = 2;
      TimeoutStartSec = 15;
      TimeoutStopSec = 5;
    };
  };

  systemd.services.zapret-vpn-monitor = {
    description = "Reconcile zapret with NetworkManager VPN state";
    wantedBy = [ "multi-user.target" ];
    wants = [ "NetworkManager.service" ];
    after = [ "NetworkManager.service" ];
    # A transient NM/bus outage must not permanently exhaust the guard's retries.
    startLimitIntervalSec = 0;
    serviceConfig = {
      Type = "exec";
      ExecStart = vpnGuard;
      Restart = "always";
      RestartSec = 2;
      WatchdogSec = 20;
      NotifyAccess = "main";
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      RestrictAddressFamilies = [ "AF_UNIX" ];
    };
  };

  # Allow toggling zapret without a password prompt
  security.sudo.extraRules = [
    {
      users = [ username ];
      commands = [
        {
          command = "/run/current-system/sw/bin/systemctl start zapret-vpn-monitor.service";
          options = [ "NOPASSWD" ];
        }
        {
          command = "/run/current-system/sw/bin/systemctl stop zapret-vpn-monitor.service";
          options = [ "NOPASSWD" ];
        }
      ];
    }
  ];
}
