# NixOS configuration

Personal desktop configuration based on nixos-unstable, with Umbriel and Hyprland
sessions and the Noctalia shell. Home Manager is integrated as a NixOS module,
so rebuilding the system also applies the user configuration.

## Repository layout

| Location | Contents |
| --- | --- |
| [`flake.nix`](flake.nix) | Flake inputs and system composition. |
| [`hosts/`](hosts) | Host configurations. |
| [`modules/system/`](modules/system) | NixOS modules. |
| [`modules/home/`](modules/home) | Home Manager modules. |
| [`scripts/`](scripts) | Shell helpers and Python utilities. |
| [`pkgs/`](pkgs) | Custom package definitions and source pins. |
| [`assets/`](assets) | Application configuration and visual assets. |
| [`flake.lock`](flake.lock) | Locked flake input revisions. |

Hosts are discovered automatically from `hosts/`, without adding flake entries.
Each `hosts/<name>/default.nix` selects system modules and imports the host's
`home.nix` for Home Manager. The directory name becomes both the hostname and
the `nixosConfigurations` key. The current host is
[`katana`](hosts/katana).

## First build

The checkout must be at `/home/<username>/nixos`, using the host's `username`.
This path is set by `flakeDir` in `flake.nix` and used by the shell helpers and
Umbriel's live configuration links.

Use `cfg track` to stage checkout changes so new source files are included in
the Git flake. Before the first activation, use `git add` instead, since the
helper is not installed yet. A commit is not required.

For a new account, configure authentication in the
[user module](modules/system/user.nix); it supplies no password. Home Manager
backs up conflicting managed files with a `.backup` suffix; resolve existing
backup-name conflicts before activation.

On an installed NixOS system with `nix-command` and `flakes` enabled, run from
the checkout. Use the host directory name after `#` (`katana` here):

```bash
sudo nixos-rebuild switch --flake .#katana
```

Start a new login session to load the shell helpers.

## Usage and maintenance

The [nixctl](scripts/zsh/nixctl.zsh) Zsh function provides the following subcommands
in the configured user's interactive shell. It uses the checkout and requests
sudo when needed.

| Task | Subcommand | Effect |
| --- | --- | --- |
| Search packages | `search` | Searches published channel package metadata for a supplied query. |
| Check updates | `livecheck` | Reports updates for flake inputs and the separate [Helium pin](pkgs/helium.json) without changing files. |
| Update and apply | `update` | Refreshes pins, evaluates the configuration, then builds and activates it. |
| Apply local edits | `switch` | Builds and activates the current system and Home Manager configuration. |

Package search is independent of `flake.lock`. The default scope is top-level
packages and `kdePackages`; `--all` includes other package sets, and `--offline`
uses the saved index.

## Desktop configuration

**Umbriel:** [`assets/umbriel/`](assets/umbriel) TOML files are linked directly
into `~/.config/umbriel/`. Edit existing files without rebuilding using
`umb edit`; `umb reload` reloads them and `umb keybinds` shows shortcuts.
Most settings reload live; some require a session restart.

Noctalia's [theme template](https://docs.noctalia.dev/noctalia/templates/official/umbriel/)
generates `~/.config/umbriel/noctalia.toml`. This file stays outside Nix-managed
links and is loaded through `config.toml`'s optional include.

**Noctalia:** Home Manager installs [`assets/noctalia/`](assets/noctalia) into
`~/.config/noctalia/`; edit the repository and rebuild to change this base.
GUI changes persist in `~/.local/state/noctalia/settings.toml` and
[override the base](https://docs.noctalia.dev/noctalia/configuration/#which-value-wins)
across rebuilds. Remove the relevant local override to use the repository value.

**Hyprland:** The session is enabled; its base configuration is not supplied
here. The `hypr` helper operates on `~/.config/hypr/`.

## Network

[System DNS](modules/system/network.nix) uses the local DNSCrypt proxy with
Anonymized DNSCrypt relays. No plaintext resolver fallback is configured;
system DNS fails if the proxy is unavailable.

[Zapret](modules/system/zapret.nix) processes outgoing TLS on TCP 443 across
domains for DPI evasion. Private/local address ranges are excluded; HTTP and
UDP processing are disabled. Its NetworkManager guard pauses it during
VPN/tunnel activity. `zapret down` stops the guard and Zapret; `zapret up`
re-enables automatic control. `zapret status` shows both services.

After [Proton VPN CLI sign-in](https://protonvpn.com/support/use-linux-cli#how-to-sign-in),
`vpn up` connects to CH by default, and `vpn down` disconnects.
`network` shows the public IP, configured DNS
resolver and interface/VPN state.

## Automatic services

- **[USB backup](modules/system/backup.nix):** A mounted volume labelled
  `Backup` triggers verified snapshots of selected home paths, repeating every
  24 hours while mounted and retaining the latest eight. Sources and mount
  exclusions are set in the host's `internal.backup`. Backups are postponed
  while configured VeraCrypt volumes are mounted.
- **[PTT](modules/system/ptt.nix):** A user service starts the default microphone
  muted and provides mouse-button push-to-talk. Device and button are set in
  the host's `internal.ptt`.
