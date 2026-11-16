kitty() {
  if [[ "$1" == "opacity" ]]; then
    local conf_dir="$HOME/.config/kitty"
    local conf_file="$conf_dir/opacity.conf"

    if [[ -z "$2" ]]; then
      [[ -f "$conf_file" ]] && cat "$conf_file"
      return 0
    fi

    mkdir -p "$conf_dir"
    echo "background_opacity $2" > "$conf_file"
  else
    command kitty "$@"
  fi
}
