# Test resolution directly against dnscrypt-proxy on 127.0.0.1,
# bypassing /etc/resolv.conf entirely. Tiers 1-3 all depend on
# dnscrypt-proxy listening on loopback, not on resolv.conf being
# correct — testing via the system resolver (getent) would report
# a false failure any time resolv.conf itself is stale/wrong, even
# though dnscrypt-proxy is healthy.
_dns_query_local() {
  # Use highly available domains to prevent false failures if a single domain is down.
  local domains=("cloudflare.com" "dns.google" "nixos.org")

  if command -v dig >/dev/null 2>&1; then
    for d in "${domains[@]}"; do
      if dig +time=2 +tries=1 +short @127.0.0.1 "$d" >/dev/null 2>&1; then
        return 0
      fi
    done
    return 1
  fi
  # dig unavailable: can't bypass resolv.conf reliably, fall back to
  # the system resolver (may misreport if resolv.conf is stale).
  for d in "${domains[@]}"; do
    if getent ahostsv4 "$d" >/dev/null 2>&1; then
      return 0
    fi
  done
  return 1
}

dns() {
  case "$1" in
    fix)
      # Refresh sudo ticket upfront to prevent timeouts during long benchmark loops (e.g. Tier 3).
      if ! sudo -v; then
        echo "Root privileges required to fix DNS. Aborting." >&2
        return 1
      fi

      echo "Checking local DNS service..."
      # Force resolv.conf to loopback before testing/using dnscrypt-proxy.
      # Without this, dig-based checks can pass (dnscrypt-proxy itself
      # is healthy) while the system's actual resolver stays broken,
      # because getent/normal apps read /etc/resolv.conf, not 127.0.0.1
      # directly.
      printf "nameserver 127.0.0.1\nnameserver ::1\n" | sudo tee /etc/resolv.conf >/dev/null

      # Tier 1: local DNS already works
      if _dns_query_local; then
        echo "Local DNS (dnscrypt-proxy) is working. No changes made."
        return 0
      fi

      # Tier 2: restart the service as-is
      echo "Local DNS failed. Restarting dnscrypt-proxy..."
      # CRITICAL FIX: Clear any start-limit-hit before restarting, otherwise systemd rejects it.
      sudo systemctl reset-failed dnscrypt-proxy 2>/dev/null
      sudo systemctl restart dnscrypt-proxy
      sleep 2
      if _dns_query_local; then
        echo "dnscrypt-proxy restarted. Resolution restored."
        return 0
      fi

      # Tier 3: relax to DoH + no-relay, still encrypted, still loopback.
      # No resolv.conf change here — dnscrypt-proxy keeps listening on
      # 127.0.0.1, we just widen which servers it's allowed to use.
      # This changes the server pool/verification posture, so confirm
      # with the user before applying it rather than doing it silently.
      echo "Restart failed."
      echo -n "Relax dnscrypt-proxy to DoH fallback (still encrypted, wider server pool)? [y/N] " > /dev/tty
      local confirm_t3
      read -r -k 1 confirm_t3 < /dev/tty
      echo ""
      if [[ "$confirm_t3" != [yY] ]]; then
        echo "Aborted at tier 3. DNS remains unresolved. Run 'dns fix' again to retry, or fix manually."
        return 1
      fi
      echo "Relaxing dnscrypt-proxy to DoH fallback (still encrypted)..."

      local orig_config bin_path

      # Get the active dnscrypt-proxy command from systemd.
      # On NixOS the unit usually lives in /nix/store rather than
      # /etc/systemd/system/, so query systemd directly instead of
      # looking for a unit file on disk.
      local argv
      argv=$(systemctl show -p ExecStart --value dnscrypt-proxy | grep -oP 'argv\[\]=\K[^;]+')
      bin_path=$(echo "$argv" | awk '{print $1}')
      orig_config=$(echo "$argv" | grep -oP -- '-config \K\S+')

      if [[ -z "$bin_path" || -z "$orig_config" || ! -f "$orig_config" ]]; then
        echo "Could not reliably determine dnscrypt-proxy binary or config path. Aborting tier 3." >&2
      else
        sudo mkdir -p /run/dns-fallback
        sudo sed -e 's/^doh_servers = false/doh_servers = true/' \
                  -e 's/^skip_incompatible = true/skip_incompatible = false/' \
                  "$orig_config" | sudo tee /run/dns-fallback/dnscrypt-proxy.toml >/dev/null

        sudo systemctl edit --runtime --drop-in=fallback --stdin dnscrypt-proxy <<EOF
[Service]
ExecStart=
ExecStart=$bin_path -config /run/dns-fallback/dnscrypt-proxy.toml
EOF
        sudo systemctl daemon-reload
        sudo systemctl reset-failed dnscrypt-proxy 2>/dev/null
        sudo systemctl restart dnscrypt-proxy

        # Opening doh_servers roughly doubles the candidate pool
        # (174 -> 336+ observed), and dnscrypt-proxy benchmarks every
        # live server before it's usable. This has taken 40+ seconds
        # in practice, so give it real headroom instead of guessing
        # low and bailing into tier 4 while it's still warming up.
        local i ok=0
        for i in {1..40}; do
          sleep 2
          if _dns_query_local; then
            ok=1
            break
          fi
          # Every ~10s, reassure the user this hasn't hung.
          if (( i % 5 == 0 )); then
            echo "  ...still benchmarking DoH servers ($((i*2))s elapsed)"
          fi
        done

        if [[ "$ok" == "1" ]]; then
          echo "DoH fallback active (still encrypted, no relay). Run 'dns restore' to revert."
          return 0
        fi
      fi

      # Tier 4: last resort, plaintext, with self-expiry
      # This drops encryption entirely (plaintext DNS to 1.1.1.1/9.9.9.9),
      # so confirm with the user before applying it rather than doing it
      # silently.
      echo "Encrypted fallback also failed."
      echo -n "Fall back to PLAINTEXT DNS (1.1.1.1 & 9.9.9.9, auto-reverts in 30min)? [y/N] " > /dev/tty
      local confirm_t4
      read -r -k 1 confirm_t4 < /dev/tty
      echo ""
      if [[ "$confirm_t4" != [yY] ]]; then
        echo "Aborted at tier 4. DNS remains unresolved. Run 'dns fix' again to retry, or fix manually."
        return 1
      fi
      echo "Applying plaintext DNS (1.1.1.1 & 9.9.9.9)..."

      # Clear ALL runtime drop-ins (including broken.conf or fallback.conf) so Tier 4 plaintext can take over
      if [[ -n "$(systemctl show -p DropInPaths --value dnscrypt-proxy)" ]]; then
        sudo systemctl revert dnscrypt-proxy
        sudo rm -rf /run/dns-fallback
      fi

      printf "nameserver 1.1.1.1\nnameserver 9.9.9.9\n" | sudo tee /etc/resolv.conf >/dev/null

      # Defensive cleanup: a leftover transient timer from a previous
      # fix/restore cycle can still be "loaded" even after being
      # stopped, which makes systemd-run refuse to create a new one.
      # systemd-run --on-active creates BOTH a .timer and a .service;
      # the .timer is what stays "loaded" and blocks re-creation, so
      # both suffixes must be targeted explicitly (bare "dns-fallback-expire"
      # only resolves to .service).
      sudo systemctl stop dns-fallback-expire.timer dns-fallback-expire.service 2>/dev/null
      sudo systemctl reset-failed dns-fallback-expire.timer dns-fallback-expire.service 2>/dev/null

      sudo systemd-run --unit=dns-fallback-expire --on-active=30min --collect \
        /run/current-system/sw/bin/zsh -c 'printf "nameserver 127.0.0.1\nnameserver ::1\n" | tee /etc/resolv.conf >/dev/null; systemctl restart dnscrypt-proxy'
      echo "Plaintext fallback active — WILL AUTO-REVERT in 30 min. Run 'dns restore' to revert now."
      ;;

    restore)
      # Refresh sudo ticket upfront
      if ! sudo -v; then
        echo "Root privileges required to restore DNS. Aborting." >&2
        return 1
      fi

      echo "Restoring local DNS configuration..."
      sudo systemctl stop dns-fallback-expire.timer dns-fallback-expire.service 2>/dev/null
      sudo systemctl reset-failed dns-fallback-expire.timer dns-fallback-expire.service 2>/dev/null

      # Tear down ALL runtime overrides (fallback.conf, broken.conf, etc.)
      if [[ -n "$(systemctl show -p DropInPaths --value dnscrypt-proxy)" ]]; then
        sudo systemctl revert dnscrypt-proxy
        sudo rm -rf /run/dns-fallback
      fi

      # Clear any start-limit-hit state left over from a broken ExecStart
      # (e.g. tier 2's restart repeatedly failing during fix), so the
      # restart below isn't blocked by systemd's crash-loop protection.
      sudo systemctl reset-failed dnscrypt-proxy 2>/dev/null

      # Force resolv.conf back to loopback, covers tier 4 cleanup
      # unconditionally (no-op if it was already correct).
      printf "nameserver 127.0.0.1\nnameserver ::1\n" | sudo tee /etc/resolv.conf >/dev/null

      sudo systemctl daemon-reload
      sudo systemctl restart dnscrypt-proxy

      sleep 2
      if _dns_query_local; then
        echo "Local DNS restored successfully."
      else
        echo "Error: Local DNS resolution failed after restore." >&2
        echo "Hint: Run 'sudo /run/current-system/bin/switch-to-configuration switch'" >&2
      fi
      ;;

    status)
      echo "# Service status (dnscrypt-proxy)"
      systemctl status dnscrypt-proxy --no-pager -l -n 5
      echo ""
      echo "# Active override"
      if systemctl show -p DropInPaths --value dnscrypt-proxy | grep -q fallback; then
        echo "DoH fallback (tier 3) is ACTIVE"
      elif systemctl is-active --quiet dns-fallback-expire; then
        echo "Plaintext fallback (tier 4) is ACTIVE, will auto-expire"
      else
        echo "No override active"
      fi
      echo ""
      echo "# /etc/resolv.conf"
      cat /etc/resolv.conf
      echo ""
      echo "# DNS resolution test"

      # If plaintext fallback is active, test system resolver instead of broken 127.0.0.1
      if systemctl is-active --quiet dns-fallback-expire; then
        if getent ahostsv4 cloudflare.com >/dev/null 2>&1 || getent ahostsv4 nixos.org >/dev/null 2>&1; then
          echo "DNS status: OK (via Plaintext / resolv.conf)"
        else
          echo "DNS status: FAILED"
        fi
      else
        if _dns_query_local; then
          echo "DNS status: OK (via 127.0.0.1)"
        else
          echo "DNS status: FAILED"
        fi
      fi
      ;;

    *)
      echo "Usage: dns [fix|restore|status]"
      return 1
      ;;
  esac
}

# Autocompletion for dns command
_dns_completion() {
  local -a subcommands
  subcommands=(fix restore status)
  compadd $subcommands
}
compdef _dns_completion dns
