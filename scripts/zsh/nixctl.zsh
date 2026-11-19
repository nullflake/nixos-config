nixctl() {

  case "$1" in
    boot)
      nh os boot
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

      nh clean all --keep "$keep_count"
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
    list)
      sudo nix-env --list-generations --profile /nix/var/nix/profiles/system
      ;;
    livecheck)
      if [[ -n "$FLAKE" ]]; then
        nix-livecheck --flake "$FLAKE" "${@:2}"
      else
        nix-livecheck "${@:2}"
      fi
      ;;
    rollback)
      sudo nixos-rebuild switch --rollback
      ;;
    search)
      if [[ "$2" == "--options" ]]; then
        package-index options "${@:3}"
        return $?
      fi

      local search_action="$2"
      [[ "$search_action" == "--stable" ]] && search_action="$3"
      if [[ "$search_action" == "--status" || "$search_action" == "--logs" ]]; then
        local search_service='package-search-refresh@*.service'
        if (( $# == 3 )) && [[ "$2" == "--stable" || "$3" == "--stable" ]]; then
          search_service='package-search-refresh-stable@*.service'
        elif (( $# != 2 )) || [[ "$2" != "$search_action" ]]; then
          echo "Usage: nixctl search <--status | --logs> [--stable]" >&2
          return 1
        fi
        case "$search_action" in
          --status)
            systemctl --user list-units --all --no-pager "$search_service"
            ;;
          --logs)
            journalctl --user -u "$search_service" -n 20 --no-pager
            ;;
        esac
      else
        package-index search "${@:2}"
      fi
      ;;
    switch)
      nh os switch
      ;;
    update)
      echo "Updating flake inputs..."
      if ! nix flake update --flake "$FLAKE"; then
        echo "Error: flake update failed." >&2
        return 1
      fi

      # Helium is pinned in pkgs/helium.json, outside flake.lock. A failed update
      # is not fatal: the current pin keeps working.
      echo "Updating Helium pin..."
      if ! helium update; then
        echo "Warning: Helium update failed; continuing with the current pin." >&2
      fi

      echo "Validating configuration (nix flake check)..."
      if ! nix flake check "$FLAKE" --no-build; then
        echo "Error: flake check failed. Not switching." >&2
        echo "Run 'cfg diff' to review the flake.lock and pkgs/helium.json changes." >&2
        return 1
      fi

      echo "Building and switching..."
      local rc
      if nh os switch; then
        :
      else
        rc=$?
        echo "Error: switch failed (exit $rc). Run 'cfg diff' to review the flake.lock and pkgs/helium.json changes." >&2
        return $rc
      fi
      ;;
    verify)
      echo "Verifying and repairing nix store..."
      sudo nix-store --verify --check-contents --repair
      ;;
    *)
      echo "Usage: nixctl <command> [arguments]"
      echo ""
      echo "Commands:"
      echo "  boot"
      echo "  clean | clean keep <N>"
      echo "  diff"
      echo "  find <query> [-fzf]"
      echo "  list"
      echo "  livecheck [--details]"
      echo "    Check flake inputs and independent pins without updating"
      echo "  rollback"
      echo "  search <query> [--offline] [--stable] [--details] [--limit N] [--all | --set <set> | --top-level]"
      echo "    Default scope: top-level packages + kdePackages"
      echo "  search --options <query> [--nixos | --home-manager] [--stable] [--offline] [--details] [--limit N]"
      echo "  search <--status | --logs> [--stable]"
      echo "  switch"
      echo "  update"
      echo "  verify"
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
    livecheck)
      [[ "$words[CURRENT-1]" == --flake ]] && { _files -/; return; }
      compadd -- --help --flake --details
      ;;
    search)
      if (( CURRENT == 3 )); then
        compadd -- --options --offline --status --logs --stable --details --limit --all --set --top-level
      elif [[ "$words[3]" == "--options" ]]; then
        [[ "$words[CURRENT-1]" == "--limit" ]] && return
        compadd -- --help --limit --stable --offline --details --channel --json --nixos --home-manager
      elif (( ${words[(Ie)--status]} || ${words[(Ie)--logs]} )); then
        compadd -- --stable
      else
        case "$words[CURRENT-1]" in
          --set|--limit) return ;;
        esac
        if [[ "$words[3]" == "--stable" && CURRENT -eq 4 ]]; then
          compadd -- --offline --status --logs --details --limit --all --set --top-level
        else
          compadd -- --offline --stable --details --limit --all --set --top-level
        fi
      fi
      ;;
    *)
      subcommands=(boot clean diff find list livecheck rollback search switch update verify)
      compadd $subcommands
      ;;
  esac
}
compdef _nixctl_completion nixctl
