play() {
  if [[ $# -ne 1 || -z "$1" ]]; then
    echo "Usage: play 'URL'" >&2
    return 2
  fi

  command setsid mpv --profile=youtube -- "$1" </dev/null >/dev/null 2>&1 &
  disown
  exit
}
