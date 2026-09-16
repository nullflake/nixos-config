zapret() {
  case "$1" in
    up)
      sudo systemctl start zapret
      ;;
    down)
      sudo systemctl stop zapret
      ;;
    status)
      systemctl status zapret
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
