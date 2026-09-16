helium() {
  local json_file="$FLAKE/pkgs/helium.json"
  case "$1" in
    "")
      command helium
      ;;
    version)
      # Compare local version against latest GitHub release
      local current latest
      current=$(jq -r '.version' "$json_file")
      latest=$(curl --silent --fail "https://api.github.com/repos/imputnet/helium-linux/releases/latest" | grep -oP '"tag_name":\s*"\K[^"]+')

      if [[ -z "$latest" ]]; then
        echo "helium version: failed to fetch latest release" >&2
        return 1
      fi

      if [[ "$current" == "$latest" ]]; then
        echo "up to date: $current"
      else
        echo "update available: $current -> $latest"
      fi
      ;;
    bump)
      local VERSION="$2"

      # Fetch latest version if not specified
      if [[ -z "$VERSION" ]]; then
        echo "No version specified, fetching latest release..."
        local api_response=$(curl --silent --fail "https://api.github.com/repos/imputnet/helium-linux/releases/latest")

        if [[ -z "$api_response" ]]; then
          echo "Error: GitHub API unreachable or rate limit exceeded." >&2
          return 1
        fi

        VERSION=$(echo "$api_response" | grep -oP '"tag_name":\s*"\K[^"]+')
        if [[ -z "$VERSION" ]]; then
          echo "Error: Failed to extract version number from API response." >&2
          return 1
        fi
      fi

      # Skip if already on this version
      local current=$(jq -r '.version' "$json_file")
      if [[ "$VERSION" == "$current" ]]; then
        echo "Already up to date: $VERSION. Update skipped."
        return 0
      fi

      local URL="https://github.com/imputnet/helium-linux/releases/download/$VERSION/helium-bin_${VERSION}-1_amd64.deb"
      echo "Downloading and verifying integrity: $VERSION"

      # Download to temporary file
      local tmp_deb=$(mktemp)
      if ! curl --silent --show-error --location --fail "$URL" -o "$tmp_deb"; then
        echo "Error: Failed to download version $VERSION." >&2
        rm -f "$tmp_deb"
        return 1
      fi

      # Verify file type before trusting it
      if ! file "$tmp_deb" | grep -q "Debian binary package"; then
        echo "Error: Downloaded file is not a valid .deb package. Aborting." >&2
        rm -f "$tmp_deb"
        return 1
      fi

      # Calculate SRI hash
      local HASH=$(nix hash file --type sha256 --sri "$tmp_deb")
      rm -f "$tmp_deb"

      if [[ -z "$HASH" ]]; then
        echo "Error: Failed to calculate hash." >&2
        return 1
      fi

      # Atomically update helium.json
      local tmp_json=$(mktemp)
      jq --arg v "$VERSION" --arg h "$HASH" '.version = $v | .hash = $h' "$json_file" > "$tmp_json" && mv "$tmp_json" "$json_file"

      echo "Updated: $VERSION -> $HASH"
      ;;
    *)
      echo "Usage: helium [version|bump [version]]" >&2
      return 1
      ;;
  esac
}

# Autocompletion for helium
_helium_completion() {
  local -a subcommands
  subcommands=(version bump)
  compadd $subcommands
}
compdef _helium_completion helium
