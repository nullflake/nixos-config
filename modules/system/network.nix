{ pkgs, username, ... }:
{
  networking.networkmanager.enable = true;
  networking.firewall.enable = true;

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

  # Encrypted DNS to bypass ISP-level DNS blocking
  # No fallback resolver on purpose. If this service dies, DNS stops
  # entirely instead of leaking queries.
  networking.nameservers = [
    "127.0.0.1"
    "::1"
  ];
  networking.networkmanager.dns = "none";

  # Disable mDNS: local-network hostname resolution that can leak
  # device names to the LAN outside the encrypted DNS path.
  services.avahi.enable = false;

  # Allow restarting dnscrypt-proxy without a password prompt
  security.sudo.extraRules = [
    {
      users = [ username ];
      commands = [
        {
          command = "/run/current-system/sw/bin/systemctl restart dnscrypt-proxy";
          options = [ "NOPASSWD" ];
        }
      ];
    }
  ];

  services.dnscrypt-proxy = {
    enable = true;
    settings = {
      listen_addresses = [
        "127.0.0.1:53"
        "[::1]:53"
      ];
      ipv6_servers = false;
      require_dnssec = true;
      require_nolog = true;
      require_nofilter = true;

      # DNSCrypt only, no DoH: Anonymized DNSCrypt (below) only works
      # with the DNSCrypt protocol, not DoH. Mixing in DoH servers
      # would let the proxy silently pick one that bypasses the relay.
      dnscrypt_servers = true;
      doh_servers = false;

      # Ephemeral keys per query + no TLS session resumption, to reduce
      # the fingerprint a passive observer can correlate across queries.
      dnscrypt_ephemeral_keys = true;
      tls_disable_session_tickets = true;

      # Anonymized DNSCrypt: route queries through a relay so the
      # resolver itself never sees client IP + query together.
      # Wildcard route: let the proxy pick a working relay for whatever
      # server it ends up using, instead of hardcoding a relay name
      # that may go stale or unreliable when the resolvers list updates.
      anonymized_dns = {
        routes = [
          {
            server_name = "*";
            via = [ "*" ];
          }
        ];
        skip_incompatible = true;
      };

      sources.public-resolvers = {
        urls = [
          "https://raw.githubusercontent.com/DNSCrypt/dnscrypt-resolvers/master/v3/public-resolvers.md"
          "https://download.dnscrypt.info/resolvers-list/v3/public-resolvers.md"
        ];
        cache_file = "/var/cache/dnscrypt-proxy/public-resolvers.md";
        minisign_key = "RWQf6LRCGA9i53mlYecO4IzT51TGPpvWucNSCh1CBM0QTaLn73Y7GFO3";
      };

      sources.relays = {
        urls = [
          "https://raw.githubusercontent.com/DNSCrypt/dnscrypt-resolvers/master/v3/relays.md"
        ];
        cache_file = "/var/cache/dnscrypt-proxy/relays.md";
        minisign_key = "RWQf6LRCGA9i53mlYecO4IzT51TGPpvWucNSCh1CBM0QTaLn73Y7GFO3";
      };
    };
  };

  # NOTE: systemd hardening (ProtectSystem=strict, DynamicUser,
  # CacheDirectory, NoNewPrivileges, etc.) is already applied by the
  # nixpkgs dnscrypt-proxy module by default. No need to re-add it here.
}
