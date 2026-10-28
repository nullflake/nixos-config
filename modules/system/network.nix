{
  networking.networkmanager.enable = true;
  networking.firewall.enable = true;

  /*
    Encrypted DNS to bypass ISP-level DNS blocking
    No fallback in the system resolver list: if the proxy stops,
    system DNS resolution fails instead of switching to plaintext DNS.
  */
  networking.nameservers = [
    "127.0.0.1"
    "::1"
  ];
  networking.networkmanager.dns = "none";

  /*
    Avahi is disabled to limit system-level mDNS hostname announcements.
    When Home Assistant is enabled, its own zeroconf can still announce
    the instance on the LAN via default_config, independently of Avahi.
    Its module separately blocks non-loopback TCP access to port 8123;
    that restriction does not disable discovery or announcements.
  */
  services.avahi.enable = false;

  services.dnscrypt-proxy = {
    enable = true;
    settings = {
      listen_addresses = [
        "127.0.0.1:53"
        "[::1]:53"
      ];
      ipv6_servers = false;

      /*
        Explicit names bypass require_* filters. Both selected stamps
        declare DNSSEC, no logging and no filtering; check these properties
        when changing the selection.
      */
      server_names = [
        "dnscry.pt-paris-ipv4"
        "dnscry.pt-oradea-ipv4"
      ];

      /*
        DNSCrypt only, no DoH: Anonymized DNSCrypt (below) only works
        with the DNSCrypt protocol, not DoH. Mixing in DoH servers
        would let the proxy silently pick one that bypasses the relay.
      */
      dnscrypt_servers = true;
      doh_servers = false;
      # Work around the PQ large-response failures observed with proxy 2.1.18.
      pqdnscrypt = false;

      # Use a fresh key pair for each DNSCrypt query to reduce linkability.
      dnscrypt_ephemeral_keys = true;
      # Disable TLS session resumption for HTTPS resolver/relay list downloads.
      tls_disable_session_tickets = true;

      /*
        Anonymized DNSCrypt: route queries through a relay so the
        resolver itself never sees client IP + query together.
        Only dnscry.pt resolvers are selected. Their fixed relays are run
        by Frank Denis and CryptoStorm, respectively, keeping the two
        roles with different operators. No wildcard relay selection.
      */
      anonymized_dns = {
        routes = [
          {
            server_name = "dnscry.pt-paris-ipv4";
            via = [ "anon-kama" ];
          }
          {
            server_name = "dnscry.pt-oradea-ipv4";
            via = [ "anon-cs-london" ];
          }
        ];
        skip_incompatible = true;
        # Keep certificate retrieval behind the relay as well.
        direct_cert_fallback = false;
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

  /*
    NOTE: systemd hardening (ProtectSystem=strict, DynamicUser,
    CacheDirectory, NoNewPrivileges, etc.) is already applied by the
    nixpkgs dnscrypt-proxy module by default. No need to re-add it here.
  */
}
