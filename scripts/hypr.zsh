hypr() {
  local hypr_dir="$HOME/.config/hypr"
  case "$1" in
    edit)
      yazi "$hypr_dir"
      ;;
    tree)
      if command -v eza >/dev/null 2>&1; then
        eza --tree --icons=always "$hypr_dir"
      else
        find -L "$hypr_dir" -not -path '*/.*' | sort
      fi
      ;;
    copy)
      find -L "$hypr_dir" -type f \( -name '*.lua' \) | sort | while read -r f; do
        local display_name="~/.config/hypr${f#$hypr_dir}"
        echo "### $display_name"
        cat "$f"
        echo
      done | wl-copy
      ;;
    reload)
      hyprctl reload
      ;;
    clients)
      hyprctl clients
      ;;
    *)
      echo "Usage: hypr <command> [arguments]"
      echo ""
      echo "Commands:"
      echo "  edit"
      echo "  tree"
      echo "  copy"
      echo "  reload"
      echo "  clients"
      ;;
  esac
}

# Autocompletion for hypr
_hypr_completion() {
  local -a subcommands
  subcommands=(edit tree copy reload clients)
  compadd $subcommands
}
compdef _hypr_completion hypr
