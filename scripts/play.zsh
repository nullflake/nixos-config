play() {
  if [[ $# -ne 1 || -z "$1" ]]; then
    echo "Usage: play 'URL'" >&2
    return 2
  fi

  local plugin_dir="$HOME/Projects/youtube-explorer/youtube-explorer"
  if [[ ! -r "$plugin_dir/mpv.conf" || ! -r "$plugin_dir/youtube-resume.lua" ]]; then
    echo "YouTube Explorer is missing: $plugin_dir" >&2
    return 1
  fi

  command setsid mpv --include="$plugin_dir/mpv.conf" --profile=youtube-explorer \
    --script="$plugin_dir/youtube-resume.lua" -- "$1" </dev/null >/dev/null 2>&1 &
  disown
  exit
}
