{ lib, pkgs }:
{
  name,
  marker,
  files,
}:
pkgs.writeShellApplication {
  inherit name;
  runtimeInputs = [
    pkgs.coreutils
    pkgs.util-linux
  ];
  text = ''
    generation=$1
    previous_generation=$2
    marker=${lib.escapeShellArg marker}
    marker_directory=$(dirname -- "$marker")

    lock_file() {
      local target=$1 directory lock fd
      directory=$(dirname -- "$target")
      lock="$directory/.$(basename -- "$target").lock"

      mkdir -p -- "$directory"
      if [[ -e "$lock" || -L "$lock" ]]; then
        if [[ ! -f "$lock" || -L "$lock" || ! -O "$lock" || $(stat -c %h -- "$lock") != 1 ]]; then
          printf 'Invalid lock file %s\n' "$lock" >&2
          exit 1
        fi
      fi
      # Keep each lock open until the whole reset finishes.
      exec {fd}>>"$lock"
      if ! flock -w 10 "$fd"; then
        printf 'Timed out locking %s\n' "$target" >&2
        exit 1
      fi
    }

    reset_file() (
      source=$1
      target=$2
      directory=$(dirname -- "$target")
      temporary=$(mktemp -- "$directory/.places-XXXXXXXXXX")
      trap 'rm -f -- "$temporary"' EXIT
      install -m 0600 -- "$source" "$temporary"
      sync -- "$temporary"
      mv -Tf -- "$temporary" "$target"
    )

    # An older generation can leave a marker from a previous activation intact.
    if [[ "$previous_generation" == "$generation" && $(readlink -- "$marker") == "$generation" ]]; then
      exit 0
    fi

    umask 077
    mkdir -p -- "$marker_directory"
    # Leave the reset pending if any of the following steps fails.
    rm -f -- "$marker"
    sync -- "$marker_directory"
    ${lib.concatMapStringsSep "\n" (file: "lock_file ${lib.escapeShellArg file.target}") files}
    ${lib.concatMapStringsSep "\n" (
      file: "reset_file ${lib.escapeShellArg file.source} ${lib.escapeShellArg file.target}"
    ) files}
    # Persist the renames and any new parent directories before marking success.
    sync -f -- "$marker_directory" ${lib.escapeShellArgs (map (file: dirOf file.target) files)}
    ln -sfnT -- "$generation" "$marker"
    if ! sync -- "$marker_directory"; then
      rm -f -- "$marker"
      exit 1
    fi
  '';
}
