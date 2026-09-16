nixctl() {
  local host="$(hostname)"

  case "$1" in
    list)
      sudo nix-env --list-generations --profile /nix/var/nix/profiles/system | cat
      ;;
    update)
      echo "Updating flake inputs..."
      if ! nix flake update --flake "$FLAKE"; then
        echo "Error: flake update failed." >&2
        return 1
      fi

      echo "Validating configuration (nix flake check)..."
      if ! nix flake check "$FLAKE" --no-build; then
        echo "Error: flake check failed. Not switching." >&2
        echo "Fix the issue, or run 'cfg diff' to review flake.lock changes." >&2
        return 1
      fi

      echo "Building configuration (without activating)..."
      if ! sudo nixos-rebuild build --flake "$FLAKE#$host"; then
        echo "Error: build failed. Not switching." >&2
        return 1
      fi

      echo "Build succeeded. Switching..."
      if command -v nh >/dev/null 2>&1; then
        nh os switch
      else
        sudo nixos-rebuild switch --flake "$FLAKE#$host"
      fi
      ;;
    switch)
      if command -v nh >/dev/null 2>&1; then
        nh os switch
      else
        sudo nixos-rebuild switch --flake "$FLAKE#$host"
      fi
      ;;
    boot)
      if command -v nh >/dev/null 2>&1; then
        nh os boot
      else
        sudo nixos-rebuild boot --flake "$FLAKE#$host"
      fi
      ;;
    rollback)
      sudo nixos-rebuild switch --rollback
      ;;
    diff)
      local profile="/nix/var/nix/profiles/system"
      local current_gen
      local previous_gen
      local range="$2"

      if [[ -n "$range" ]]; then
        if [[ ! "$range" =~ ^[0-9]+-[0-9]+$ ]]; then
          echo "Usage: nixctl diff [<generation>-<generation>]"
          return 1
        fi

        previous_gen="${range%%-*}"
        current_gen="${range##*-}"
      else
        current_gen="$(
          sudo nix-env --list-generations --profile "$profile" |
            awk '$NF == "(current)" { print $1 }'
        )"

        previous_gen="$(
          sudo nix-env --list-generations --profile "$profile" |
            awk -v current="$current_gen" '$1 < current { gen = $1 } END { print gen }'
        )"

        if [[ -z "$current_gen" || -z "$previous_gen" ]]; then
          echo "Error: could not find current and previous system generations." >&2
          return 1
        fi
      fi

      if [[ ! -e "$profile-${previous_gen}-link" ]]; then
        echo "Error: generation $previous_gen does not exist." >&2
        return 1
      fi

      if [[ ! -e "$profile-${current_gen}-link" ]]; then
        echo "Error: generation $current_gen does not exist." >&2
        return 1
      fi

      sudo nvd diff \
        "$profile-${previous_gen}-link" \
        "$profile-${current_gen}-link"
      ;;
    find)
      if [ -z "$2" ]; then
        echo "Usage: nixctl find <query> [-fzf]"
        return 1
      fi
      if [ "$3" = "-fzf" ] || [ "$2" = "-fzf" ]; then
        local query="$2"
        [ "$query" = "-fzf" ] && query="$3"
        local target=$(find /nix/store -maxdepth 1 -name "*$query*" | fzf)
        [ -n "$target" ] && yazi "$target"
      else
        find /nix/store -maxdepth 1 -name "*$2*"
      fi
      ;;
    clean)
      local keep_count=1

      case "$2" in
        "")
          keep_count=1
          ;;
        keep)
          if [[ -z "$3" || ! "$3" =~ ^[0-9]+$ ]]; then
            echo "Usage: nixctl clean keep <N>"
            return 1
          fi
          keep_count="$3"
          ;;
        *)
          echo "Usage: nixctl clean | nixctl clean keep <N>"
          return 1
          ;;
      esac

      if command -v nh >/dev/null 2>&1; then
        nh clean all --keep "$keep_count"
      else
        if [ "$keep_count" -eq 1 ]; then
          sudo nix-collect-garbage -d
        else
          sudo nix-env --profile /nix/var/nix/profiles/system --delete-generations "+$keep_count"
          sudo nix-collect-garbage
        fi
      fi
      ;;
    *)
      echo "Usage: nixctl <command> [arguments]"
      echo ""
      echo "Commands:"
      echo "  list"
      echo "  update"
      echo "  switch"
      echo "  boot"
      echo "  rollback"
      echo "  diff"
      echo "  find <query> [-fzf]"
      echo "  clean | clean keep <N>"
      return 1
      ;;
  esac
}

# Autocompletion for nixctl
_nixctl_completion() {
  local -a subcommands
  case "$words[2]" in
    clean)
      local -a clean_opts
      clean_opts=(keep)
      compadd $clean_opts
      ;;
    find)
      local -a find_opts
      find_opts=(-fzf)
      compadd $find_opts
      ;;
    *)
      subcommands=(list update switch boot rollback diff find clean)
      compadd $subcommands
      ;;
  esac
}
compdef _nixctl_completion nixctl
