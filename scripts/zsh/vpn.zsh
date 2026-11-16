vpn() {
  case "$1" in
    up)
      protonvpn connect --country "${2:-CH}"
      ;;
    down)
      protonvpn disconnect
      ;;
    status)
      protonvpn status
      ;;
    *)
      echo "Usage: vpn up [COUNTRY] | vpn down | vpn status"
      ;;
  esac
}
# Autocompletion for vpn
_vpn_completion() {
  local -a subcommands
  subcommands=(up down status)
  compadd $subcommands
}
compdef _vpn_completion vpn
