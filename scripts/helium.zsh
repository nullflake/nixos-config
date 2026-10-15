# helium: manages the helium package in the Nix flake, otherwise launches the browser.
#   helium                    -> launch the browser
#   helium version            -> compare local version against the latest release
#   helium update [version]   -> update version/hash in pkgs/helium.json
#   helium <anything else>    -> forwarded to the browser as-is
# To run the browser with these names, use: command helium version
# Optional environment variables:
#   GITHUB_TOKEN=...          avoid API rate limits
#   HELIUM_REQUIRE_DIGEST=1   abort update if GitHub publishes no sha256 digest

_helium_repo_api="https://api.github.com/repos/imputnet/helium-linux/releases"

# Print release JSON. Uses tag $1 if given, otherwise the latest release.
_helium_release_json() {
  local url="$_helium_repo_api/latest"
  [[ -n "$1" ]] && url="$_helium_repo_api/tags/$1"

  local -a hdr=(-H "Accept: application/vnd.github+json")
  [[ -n "${GITHUB_TOKEN:-}" ]] && hdr+=(-H "Authorization: Bearer $GITHUB_TOKEN")

  curl --silent --show-error --fail --location \
    --connect-timeout 10 --max-time 30 \
    "${hdr[@]}" "$url"
}

helium() {
  emulate -L zsh
  setopt local_options pipe_fail

  case "$1" in
    version)
      local json_file="${FLAKE:+$FLAKE/pkgs/helium.json}"
      if [[ -z "$json_file" || ! -r "$json_file" ]]; then
        echo "Error: \$FLAKE is unset or helium.json is not readable." >&2
        return 1
      fi
      if ! (( $+commands[jq] )); then
        echo "Error: jq is required." >&2
        return 1
      fi

      local current latest release
      current=$(jq -r '.version // empty' "$json_file")
      if [[ -z "$current" ]]; then
        echo "Error: no version found in $json_file" >&2
        return 1
      fi

      if ! release=$(_helium_release_json); then
        echo "Error: failed to fetch latest release (network or rate limit)." >&2
        return 1
      fi

      latest=$(jq -r '.tag_name // empty' <<<"$release")
      if [[ -z "$latest" ]]; then
        echo "Error: could not parse latest release tag." >&2
        return 1
      fi

      if [[ "$current" == "$latest" ]]; then
        echo "up to date: $current"
      else
        echo "update available: $current -> $latest"
      fi
      ;;

    update)
      local json_file="${FLAKE:+$FLAKE/pkgs/helium.json}"
      if [[ -z "$json_file" || ! -w "$json_file" ]]; then
        echo "Error: \$FLAKE is unset or helium.json is not writable." >&2
        return 1
      fi

      local dep
      for dep in jq curl nix sha256sum; do
        if ! (( $+commands[$dep] )); then
          echo "Error: required command not found: $dep" >&2
          return 1
        fi
      done

      local version="$2" release="" asset_url="" digest=""

      # Tags are plain dotted numbers (e.g. 0.15.6.1) and the same string is used in the .deb file name
      if [[ -n "$version" && ! "$version" =~ '^[0-9]+(\.[0-9]+)+$' ]]; then
        echo "Error: invalid version '$version' (expected e.g. 0.15.6.1)." >&2
        return 1
      fi

      # Fetch release metadata (latest if no version was given)
      if [[ -z "$version" ]]; then
        echo "No version specified, fetching latest release..."
        if ! release=$(_helium_release_json); then
          echo "Error: GitHub API unreachable or rate limit exceeded." >&2
          return 1
        fi
        version=$(jq -r '.tag_name // empty' <<<"$release")
        if [[ -z "$version" ]]; then
          echo "Error: failed to extract version from API response." >&2
          return 1
        fi
      else
        release=$(_helium_release_json "$version") ||
          echo "Warning: could not read release metadata for $version; using default URL pattern." >&2
      fi

      local current
      current=$(jq -r '.version // empty' "$json_file")
      if [[ "$version" == "$current" ]]; then
        echo "Already up to date: $version. Update skipped."
        return 0
      fi

      # Read asset URL and (if present) sha256 digest from the API; fall back to a fixed pattern
      if [[ -n "$release" ]]; then
        asset_url=$(jq -r '[.assets[]? | select(.name | endswith("_amd64.deb"))][0].browser_download_url // empty' <<<"$release")
        digest=$(jq -r '[.assets[]? | select(.name | endswith("_amd64.deb"))][0].digest // empty' <<<"$release")
      fi
      if [[ -z "$asset_url" ]]; then
        asset_url="https://github.com/imputnet/helium-linux/releases/download/$version/helium-bin_${version}-1_amd64.deb"
      fi

      local tmp_deb="" tmp_json=""
      {
        tmp_deb=$(mktemp) || { echo "Error: mktemp failed." >&2; return 1; }

        echo "Downloading: $asset_url"
        if ! curl --silent --show-error --location --fail \
             --connect-timeout 10 --max-time 600 \
             "$asset_url" -o "$tmp_deb"; then
          echo "Error: failed to download version $version." >&2
          return 1
        fi

        # File type check: .deb files are ar archives starting with "!<arch>"
        if [[ "$(head -c 7 "$tmp_deb")" != '!<arch>' ]]; then
          echo "Error: downloaded file is not a valid .deb package. Aborting." >&2
          return 1
        fi

        # Verify integrity if GitHub published a digest
        if [[ "$digest" == sha256:* ]]; then
          local expected="${digest#sha256:}" actual
          actual=$(sha256sum "$tmp_deb" | cut -d' ' -f1)
          if [[ "$expected" != "$actual" ]]; then
            echo "Error: sha256 mismatch (expected $expected, got $actual)." >&2
            return 1
          fi
          echo "Verified against GitHub digest."
        else
          if [[ "${HELIUM_REQUIRE_DIGEST:-0}" != (0|false|no) ]]; then
            echo "Error: no digest published by GitHub and HELIUM_REQUIRE_DIGEST is set." >&2
            return 1
          fi
          echo "Warning: no digest published by GitHub; skipping remote integrity check." >&2
        fi

        # SRI hash (--sri may be deprecated on newer nix, hence the fallback)
        local hash
        hash=$(nix hash file --type sha256 --sri "$tmp_deb" 2>/dev/null ||
               nix hash file --type sha256 "$tmp_deb" 2>/dev/null)
        if [[ "$hash" != sha256-* ]]; then
          echo "Error: failed to calculate SRI hash (is nix-command enabled?)." >&2
          return 1
        fi

        # Write to a temp file in the target directory, then move it atomically
        tmp_json=$(mktemp "${json_file}.XXXXXX") || {
          echo "Error: could not create temp file next to $json_file." >&2
          return 1
        }

        if jq --arg v "$version" --arg h "$hash" '.version = $v | .hash = $h' \
             "$json_file" > "$tmp_json" &&
           [[ -s "$tmp_json" ]] &&
           chmod --reference="$json_file" "$tmp_json" &&
           mv -- "$tmp_json" "$json_file"; then
          tmp_json=""   # moved into place, nothing left to clean up
          echo "Updated: $current -> $version ($hash)"
        else
          echo "Error: failed to update $json_file" >&2
          return 1
        fi
      } always {
        # Runs on success, error, return and interrupt
        rm -f "$tmp_deb" "$tmp_json"
      }
      ;;

    *)
      if ! (( $+commands[helium] )); then
        echo "helium: browser binary not found in PATH." >&2
        return 127
      fi
      command helium "$@"
      ;;
  esac
}

# Completion: subcommands plus files
_helium() {
  local -a subcommands=(
    'version:compare local version with latest release'
    'update:update helium.json to latest or a given version'
  )

  if (( CURRENT == 2 )); then
    _describe -t commands 'helium command' subcommands
    _files
  elif [[ "$words[2]" == update ]]; then
    return 0
  else
    _files
  fi
}

(( $+functions[compdef] )) && compdef _helium helium
