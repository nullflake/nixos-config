zapret() {
  case "$1" in
    up)
      sudo systemctl start zapret-vpn-monitor.service
      ;;
    down)
      sudo systemctl stop zapret-vpn-monitor.service
      ;;
    status)
      systemctl status zapret-vpn-monitor.service zapret.service
      ;;
    *)
      echo "Usage: zapret up | down | status"
      ;;
  esac
}

# Autocompletion for zapret
_zapret_completion() {
  local -a subcommands
  subcommands=(up down status)
  compadd $subcommands
}
compdef _zapret_completion zapret
