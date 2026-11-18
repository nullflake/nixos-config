vc() {
  local usage='Usage: vc <mount|unmount> <name>'

  if (( $# == 0 )); then
    print -r -- "$usage"
    return 0
  fi

  if (( $# != 2 )) || [[ "$1" != mount && "$1" != unmount ]]; then
    print -ru2 -- "$usage"
    return 2
  fi

  if [[ -z "${VC_DIRECTORY:-}" ]]; then
    print -ru2 -- 'vc: container directory is not configured'
    return 1
  fi

  local name=$2
  if [[ -z "$name" || "$name" == . || "$name" == .. || "$name" == */* ]]; then
    print -ru2 -- 'vc: expected a container name without a directory'
    return 2
  fi

  local dst="$VC_DIRECTORY/$name"
  local src="$dst.hc"

  case "$1" in
    mount)
      if [[ ! -f "$src" ]]; then
        echo "vc: container not found -> $src" >&2
        return 1
      fi
      mkdir -p -- "$dst" || return
      veracrypt -t "$src" "$dst" 2> >(sed -e '/Gtk-WARNING/d' -e '/^$/d' >&2)
      ;;
    unmount)
      veracrypt -t -d "$src" 2> >(sed -e '/Gtk-WARNING/d' -e '/^$/d' >&2) || {
        echo "vc: unmount failed" >&2
        return 1
      }
      ;;
  esac
}
