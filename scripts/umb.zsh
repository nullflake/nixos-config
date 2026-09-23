umb() {
  local cfg_dir="$HOME/.config/umbriel"
  local output_file="/tmp/umbriel-config.txt"

  case "$1" in
    copy)
      find -L "$cfg_dir" -type f \
        -name '*.toml' \
        -print0 |
        sort -z |
        while IFS= read -r -d '' f; do
          local display_name="~/.config/umbriel${f#$cfg_dir}"

          echo "### $display_name"
          cat "$f"
          echo
        done > "$output_file"

      if [[ "$2" == "raw" ]]; then
        wl-copy -t text/plain < "$output_file"
        echo "Copied to clipboard as text: $output_file"
      else
        wl-copy -t text/uri-list "file://$output_file"
        echo "Copied to clipboard as file: $output_file"
      fi
      ;;

    edit)
      yazi "$cfg_dir"
      ;;

    keybinds)
      umbriel msg cheatsheet-open
      ;;

    reload)
      umbriel msg config-reload
      ;;

    tree)
      if command -v eza >/dev/null 2>&1; then
        eza --tree --icons=always "$cfg_dir"
      else
        find -L "$cfg_dir" -type f | sort
      fi
      ;;

    windows)
      umbriel windows
      ;;

    *)
      echo "Usage: umb <command> [arguments]"
      echo ""
      echo "Commands:"
      echo "  copy"
      echo "  copy raw"
      echo "  edit"
      echo "  keybinds"
      echo "  reload"
      echo "  tree"
      echo "  windows"
      ;;
  esac
}

# Autocompletion for umb
_umb_completion() {
  local -a subcommands
  subcommands=(
    copy
    edit
    keybinds
    reload
    tree
    windows
  )

  compadd -- $subcommands
}

compdef _umb_completion umb
