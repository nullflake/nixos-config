cfg() {
  local cfg_dir="$FLAKE"

  case "$1" in
    copy)
      local output_file="/tmp/nixos-config.txt"

      if [[ "$2" == "raw" ]]; then
        # Raw: copies file contents without adding display-name headers.
        find -L "$cfg_dir" -type f \
          -not -path '*/.*' \
          -print0 |
          sort -z |
          while IFS= read -r -d '' f; do
            case "$f" in
              *.webp|*.png|*.jpg|*.jpeg|*.ico|*.svg)
                echo "[binary/image file, content omitted]"
                ;;
              *)
                cat "$f"
                ;;
            esac
            echo
          done > "$output_file"
      else
        # AI-friendly: adds file paths as headers for easier context.
        find -L "$cfg_dir" -type f \
          -not -path '*/.*' \
          -print0 |
          sort -z |
          while IFS= read -r -d '' f; do
            local display_name="~/nixos${f#$cfg_dir}"
            echo "### $display_name"

            case "$f" in
              *.webp|*.png|*.jpg|*.jpeg|*.ico|*.svg)
                echo "[binary/image file, content omitted]"
                ;;
              *)
                cat "$f"
                ;;
            esac

            echo
          done > "$output_file"
      fi

      if [[ "$2" == "raw" ]]; then
        wl-copy -t text/plain < "$output_file"
        echo "Copied to clipboard as text: $output_file"
      else
        printf 'file://%s\n' "$output_file" |
          wl-copy -t text/uri-list
        echo "Copied to clipboard as file: $output_file"
      fi
      ;;

    discard)
      echo "This will discard ALL local changes (reset --hard + clean -fd)."
      printf "Are you sure? [y/N] "
      read -r confirm

      if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        echo "Aborted."
        return 1
      fi

      if ! git -C "$cfg_dir" reset --hard HEAD; then
        echo "Error: git reset failed." >&2
        return 1
      fi

      if ! git -C "$cfg_dir" clean -fd; then
        echo "Error: git clean failed." >&2
        return 1
      fi
      ;;

    diff)
      git -C "$cfg_dir" diff HEAD
      ;;

    edit)
      yazi "$cfg_dir"
      ;;

    fmt)
      echo "Formatting Nix files..."

      if [[ ! -f "$cfg_dir/flake.nix" ]]; then
        echo "Error: flake.nix not found: $cfg_dir/flake.nix" >&2
        return 1
      fi

      # nix fmt must be run from the flake directory;
      # passing $cfg_dir directly does not work reliably.
      (
        cd "$cfg_dir" || exit 1
        command nix fmt .
      ) || {
        echo "Error: nix fmt failed." >&2
        return 1
      }

      echo "Done."
      ;;

    log)
      git -C "$cfg_dir" log --oneline
      ;;

    push)
      # Stage all new and modified files.
      if ! git -C "$cfg_dir" add .; then
        echo "Error: Failed to stage changes." >&2
        return 1
      fi

      local upstream
      upstream=$(git -C "$cfg_dir" \
        rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null)

      # Check whether there are staged changes compared to HEAD.
      if git -C "$cfg_dir" diff-index --quiet HEAD --; then

        # No working-tree changes.
        if [[ -z "$upstream" ]]; then

          # No upstream and no commit yet.
          if ! git -C "$cfg_dir" rev-parse --verify HEAD >/dev/null 2>&1; then
            echo "No commits yet. Push skipped."
            return 0
          fi

          echo "No upstream configured. Pushing and setting upstream..."

        else

          # No working-tree changes, but check for unpushed commits.
          if ! git -C "$cfg_dir" rev-list --count "$upstream"..HEAD |
            grep -q '[1-9]'; then
            echo "No changes detected. Push skipped."
            return 0
          fi

          echo "No new changes, but found unpushed commit(s). Continuing to push..."
        fi

      else

        # New changes exist -> Open default editor for commit message
        if ! git -C "$cfg_dir" commit; then
          echo "Error: Failed to create commit." >&2
          return 1
        fi
      fi

      if [[ -n "$upstream" ]]; then

        echo "Fetching remote updates and applying rebase..."

        if ! git -C "$cfg_dir" pull --rebase --autostash; then
          echo "Error: Conflict encountered during pull --rebase." >&2
          echo "Manual resolution is required inside $cfg_dir before proceeding." >&2
          return 1
        fi

        if ! git -C "$cfg_dir" push; then
          echo "Error: Push failed." >&2
          return 1
        fi

      else

        if ! git -C "$cfg_dir" push -u origin HEAD; then
          echo "Error: Push failed." >&2
          return 1
        fi
      fi
      ;;

    rewind)
      if [[ -z "$2" ]]; then
        echo "Usage: cfg rewind <commit>"
        return 1
      fi

      echo "This will hard reset to '$2' and FORCE PUSH to origin/main, rewriting remote history."
      printf "Type the commit hash again to confirm: "
      read -r confirm_hash

      if [[ "$confirm_hash" != "$2" ]]; then
        echo "Confirmation did not match. Aborted."
        return 1
      fi

      # Reset local history.
      if ! git -C "$cfg_dir" reset --hard "$2"; then
        echo "Error: Invalid commit." >&2
        return 1
      fi

      # Rewrite remote history only if the remote has not changed.
      if ! git -C "$cfg_dir" push origin main --force-with-lease; then
        echo "Error: Remote history was not rewritten." >&2
        echo "The remote may have changed since your last fetch." >&2
        return 1
      fi
      ;;

    status)
      git -C "$cfg_dir" status
      ;;

    track)
      if ! git -C "$cfg_dir" add .; then
        echo "Error: Failed to stage changes." >&2
        return 1
      fi
      ;;

    tree)
      eza --tree --icons=always "$cfg_dir"
      ;;

    "")
      return 0
      ;;

    *)
      echo "Usage: cfg <command> [arguments]"
      echo
      echo "Commands:"
      echo "  copy"
      echo "  copy raw"
      echo "  discard"
      echo "  diff"
      echo "  edit"
      echo "  fmt"
      echo "  log"
      echo "  push \"msg\""
      echo "  rewind <commit>"
      echo "  status"
      echo "  track"
      echo "  tree"
      ;;
  esac
}


# Autocompletion for cfg.
_cfg_completion() {
  local -a subcommands
  subcommands=(
    copy
    discard
    diff
    edit
    fmt
    log
    push
    rewind
    status
    track
    tree
  )

  compadd -- $subcommands
}

compdef _cfg_completion cfg
