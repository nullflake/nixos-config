vault() {
  local src=~/Documents/veracrypt/veracrypt
  local dst=~/Documents/veracrypt/vault
  case "$1" in
    mount)
      if [[ ! -f "$src" ]]; then
        echo "vault: container not found -> $src" >&2
        return 1
      fi
      mkdir -p "$dst"
      veracrypt -t "$src" "$dst" 2> >(sed -e '/Gtk-WARNING/d' -e '/^$/d' >&2)
      ;;
    unmount)
      veracrypt -t -d "$dst" 2> >(sed -e '/Gtk-WARNING/d' -e '/^$/d' >&2) || { echo "vault: unmount failed" >&2; return 1; }
      ;;
    *)
      echo "Usage: vault mount | vault unmount"
      ;;
  esac
}
