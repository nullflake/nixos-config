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
    copy) (
      emulate -L zsh
      setopt pipe_fail

      local output_file="/tmp/hyprland-config.txt" tmp_output
      tmp_output=$(mktemp "${output_file}.XXXXXX") || return 1
      trap 'rm -f -- "$tmp_output"' EXIT
      trap 'exit 130' INT
      trap 'exit 143' TERM
      trap 'exit 129' HUP

      # Finish collecting every file before changing the clipboard.
      if ! (
        find -L "$hypr_dir" -type f -name '*.lua' -print0 |
          sort -z |
          while IFS= read -r -d '' f; do
            printf '### ~/.config/hypr%s\n' "${f#"$hypr_dir"}" || exit 1
            command cat -- "$f" || exit 1
            printf '\n' || exit 1
          done
      ) > "$tmp_output"; then
        print -u2 -- "hypr copy: could not collect all files; clipboard unchanged."
        return 1
      fi
      mv -fT -- "$tmp_output" "$output_file" || return 1

      if [[ "$2" == "raw" ]]; then
        wl-copy -t text/plain < "$output_file" || {
          local copy_rc=$?
          print -u2 -- "hypr copy: wl-copy failed (exit $copy_rc)."
          return "$copy_rc"
        }
        echo "Copied to clipboard as text: $output_file"
      else
        printf 'file://%s\n' "$output_file" |
          wl-copy -t text/uri-list || {
            local copy_rc=$?
            print -u2 -- "hypr copy: wl-copy failed (exit $copy_rc)."
            return "$copy_rc"
          }
        echo "Copied to clipboard as file: $output_file"
      fi
    ) ;;
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
      echo "  copy [raw]"
      echo "  reload"
      echo "  clients"
      ;;
  esac
}

# Autocompletion for hypr
_hypr_completion() {
  local -a subcommands
  subcommands=(edit tree copy reload clients)
  if (( CURRENT == 2 )); then
    compadd -- $subcommands
  elif (( CURRENT == 3 )) && [[ "$words[2]" == "copy" ]]; then
    compadd -- raw
  fi
}
compdef _hypr_completion hypr
