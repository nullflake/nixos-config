zsh() {
  if [[ "$1" == "history" ]]; then
    micro ~/.zsh_history
  else
    command zsh "$@"
  fi
}
