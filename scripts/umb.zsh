umb() {
local cfg_dir="$HOME/.config/umbriel"
local output_file="/tmp/umbriel-config.txt"

case "$1" in
edit)
yazi "$cfg_dir"
;;

tree)
  if command -v eza >/dev/null 2>&1; then
    eza --tree --icons=always "$cfg_dir"
  else
    find -L "$cfg_dir" -type f | sort
  fi
  ;;

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

reload)
  umbriel msg config-reload
  ;;

windows)
  umbriel windows
  ;;

keybinds)
  umbriel msg cheatsheet-open
  ;;

*)
  echo "Usage: umb <command> [arguments]"
  echo ""
  echo "Commands:"
  echo "  edit"
  echo "  tree"
  echo "  copy"
  echo "  copy raw"
  echo "  reload"
  echo "  windows"
  echo "  keybinds"
  ;;

esac
}

_umb_completion() {
local -a subcommands
subcommands=(
edit
tree
copy
reload
windows
keybinds
)

compadd -- $subcommands
}

compdef _umb_completion umb
