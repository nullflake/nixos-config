fn() {
  local target_dir="${1:-$FLAKE/scripts}"
  if [[ ! -d "$target_dir" ]]; then
    echo "fn: directory not found -> $target_dir" >&2
    return 1
  fi
  grep -E -h '^[a-zA-Z0-9_-]+[[:space:]]*\(\)' "$target_dir"/*.zsh 2>/dev/null | cut -d'(' -f1 | grep -v '^_' | sort -u
}
