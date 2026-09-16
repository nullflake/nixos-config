network() {
  local info=$(curl -s https://1.1.1.1/cdn-cgi/trace)
  local ip=$(echo "$info" | awk -F= '/^ip=/{print $2}')
  local loc=$(echo "$info" | awk -F= '/^loc=/{print $2}')
  local colo=$(echo "$info" | awk -F= '/^colo=/{print $2}')
  local dns=$(awk '/nameserver/{print $2; exit}' /etc/resolv.conf)
  echo "IP:       $ip"
  echo "Location: $colo, $loc"
  echo "DNS:      $dns"
}
