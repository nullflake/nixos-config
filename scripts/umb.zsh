umb() {
  local cfg_dir="$HOME/.config/umbriel"

  case "$1" in
    copy) (
      emulate -L zsh
      setopt pipe_fail

      local output_file="/tmp/umbriel-config.txt" tmp_output
      tmp_output=$(mktemp "${output_file}.XXXXXX") || return 1
      trap 'rm -f -- "$tmp_output"' EXIT
      trap 'exit 130' INT
      trap 'exit 143' TERM
      trap 'exit 129' HUP

      # Check every read/write; only publish a complete output file.
      if ! (
        find -L "$cfg_dir" -type f -name '*.toml' -print0 |
          sort -z |
          while IFS= read -r -d '' f; do
            printf '### ~/.config/umbriel%s\n' "${f#"$cfg_dir"}" || exit 1
            command cat -- "$f" || exit 1
            printf '\n' || exit 1
          done
      ) > "$tmp_output"; then
        print -u2 -- "umb copy: could not collect all files; clipboard unchanged."
        return 1
      fi
      mv -fT -- "$tmp_output" "$output_file" || return 1

      if [[ "$2" == "raw" ]]; then
        wl-copy -t text/plain < "$output_file" || {
          local copy_rc=$?
          print -u2 -- "umb copy: wl-copy failed (exit $copy_rc)."
          return "$copy_rc"
        }
        echo "Copied to clipboard as text: $output_file"
      else
        printf 'file://%s\n' "$output_file" |
          wl-copy -t text/uri-list || {
            local copy_rc=$?
            print -u2 -- "umb copy: wl-copy failed (exit $copy_rc)."
            return "$copy_rc"
          }
        echo "Copied to clipboard as file: $output_file"
      fi
    ) ;;

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
