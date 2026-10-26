network() {
  emulate -L zsh

  local info curl_rc
  info=$(curl --silent --show-error --fail \
    --connect-timeout 5 --max-time 15 \
    https://1.1.1.1/cdn-cgi/trace) || {
    curl_rc=$?
    print -u2 -- "network: failed to fetch network information (curl exit $curl_rc)."
    return "$curl_rc"
  }

  local key value ip="" loc="" colo=""
  while IFS='=' read -r key value; do
    case "$key" in
      ip) ip="$value" ;;
      loc) loc="$value" ;;
      colo) colo="$value" ;;
    esac
  done <<< "$info"

  if [[ -z "$ip" || -z "$loc" || -z "$colo" ]]; then
    print -u2 -- "network: response is missing ip, loc, or colo."
    return 1
  fi

  local dns
  if ! dns=$(awk '$1 == "nameserver" {print $2; exit}' /etc/resolv.conf) || [[ -z "$dns" ]]; then
    print -u2 -- "network: could not read a DNS resolver from /etc/resolv.conf."
    return 1
  fi

  local connections
  if ! connections=$(LC_ALL=C timeout 5s nmcli --terse --escape no \
    --fields TYPE,STATE,DEVICE,NAME connection show --active); then
    print -u2 -- "network: could not read active connections from NetworkManager."
    return 1
  fi

  local connection_type connection_state device name
  local -a interfaces=() vpns=()
  while IFS=':' read -r connection_type connection_state device name; do
    case "$connection_type" in
      vpn|wireguard|tun)
        case "$connection_state" in
          activated) connection_state="connected" ;;
          activating) connection_state="connecting" ;;
          deactivating) connection_state="disconnecting" ;;
        esac
        vpns+=("$name ($connection_state)")
        ;;
      loopback|dummy) ;;
      *)
        if [[ "$connection_state" == activated && -n "$device" && "$device" != -- ]]; then
          interfaces+=("$device")
        fi
        ;;
    esac
  done <<< "$connections"

  local interface_summary="${(j:, :)interfaces}"
  local vpn_summary="${(j:, :)vpns}"
  [[ -n "$interface_summary" ]] || interface_summary="Not connected"
  [[ -n "$vpn_summary" ]] || vpn_summary="Not connected"

  printf '%-9s : %s\n' \
    IP "$ip" \
    Location "$colo, $loc" \
    DNS "$dns" \
    Interface "$interface_summary" \
    VPN "$vpn_summary"
}
