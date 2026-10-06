# NixOS Configuration

**NixOS + Home Manager** flake configuration for a personal desktop, with per-host system/home modules, custom packages, application assets, and Zsh shell functions.

## Overview

- Single flake, hosts auto-discovered from `hosts/`; each host picks the modules it needs.
- System configuration in `modules/system/`, user configuration (Home Manager) in `modules/home/`.
- Typed `custom.*` options for choices that must be explicit per host (window managers, greeter, unfree policy, push-to-talk, ...).
- Day-to-day operations wrapped in two shell functions: `nixctl` (system) and `cfg` (the configuration repository).
- Hyprland, Umbriel and Noctalia user configuration is intentionally managed outside Nix (see [Externally managed configuration](#externally-managed-configuration)).

## Requirements

The checkout **must live at `~/nixos`**. `flakeDir` in `flake.nix` points there so that `nh`, `cfg` and `nixctl` can run git and write `flake.lock`; flake evaluation itself is sandboxed and would otherwise resolve to the read-only store copy, which has no `.git`. To use another location, change that one line.

## First build

After cloning the repository to `~/nixos`, run:

```bash
sudo nixos-rebuild switch --flake ~/nixos#wakizashi
```

The Noctalia substituter and trusted public key are configured in `modules/system/nix.nix`, so the first build already uses the binary cache.

After that, use `nixctl switch` (see below).

## Daily workflow

```bash
cfg fmt          # format Nix files
nixctl switch    # build and apply
cfg push         # stage, commit, rebase, push

nixctl update    # update flake inputs, validate, build, and switch
nixctl diff      # what changed between the last two generations
nixctl rollback  # go back if something broke
```

`nixctl update` runs `nix flake update`, then `nix flake check --no-build`, and only switches if both succeed.

## System commands

`nixctl` wraps common `nixos-rebuild` / `nh` operations.

```bash
nixctl boot                 # Build and set next boot entry (nh os boot)
nixctl clean                # Remove old generations (keeps 1 via nh clean)
nixctl clean keep <N>       # Keep N generations (nh clean all --keep N)
nixctl diff [<gen>-<gen>]   # Diff store paths between two generations
nixctl find <query>         # Search Nix store
nixctl find <query> -fzf    # Select a store path with fzf and open it in Yazi
nixctl list                 # List system generations
nixctl rollback             # Switch to previous generation
nixctl switch               # Apply current configuration (nh os switch)
nixctl update               # Update flake inputs, validate, build, and switch
nixctl verify               # Verify and repair the Nix store
```

## Configuration commands

`cfg` provides shortcuts for working with the configuration repository (`$FLAKE`).

```bash
cfg edit             # Open configuration in Yazi
cfg tree             # Show configuration tree
cfg status           # Show Git status
cfg diff             # Show changes
cfg log              # Show commit history
cfg copy             # Concatenate all non-hidden files (with path headers) and copy to clipboard as a file
cfg copy raw         # Same, without headers, copied as text
cfg track            # Stage changes
cfg discard          # Discard uncommitted changes (reset --hard + clean -fd)
cfg fmt              # Run `nix fmt` on the flake
cfg push             # Stage all, commit (opens editor), rebase onto upstream, and push
cfg rewind <commit>  # Hard reset the current branch to a commit and force-push
```

`cfg copy` replaces binary and image files with a placeholder line and writes the result to `/tmp/nixos-config.txt`.

`cfg rewind` rewrites remote history, so it is deliberately strict:

- Refuses to run with uncommitted changes or a detached `HEAD`.
- Lists the commits that will be dropped before asking for confirmation.
- Pushes first (`--force-with-lease`), then resets locally, so a failed push leaves the local branch untouched.

## Other shell functions

```bash
dns fix       # Diagnose and repair local DNS (dnscrypt-proxy), tiered fallback: restart -> DoH -> plaintext
dns restore   # Revert any DNS fallback and restore dnscrypt-proxy on 127.0.0.1
dns status    # Show dnscrypt-proxy status, active override, and resolv.conf

hypr edit     # Open Hyprland user config in Yazi
hypr tree     # Show Hyprland config tree
hypr copy     # Copy Hyprland *.lua config files to clipboard
hypr reload   # Reload Hyprland config
hypr clients  # List Hyprland clients

umb edit        # Open Umbriel user config in Yazi
umb tree        # Show Umbriel config tree
umb copy [raw]  # Copy Umbriel *.toml config files to clipboard (as a file, or as text with raw)
umb reload      # Reload Umbriel config
umb windows     # List Umbriel windows
umb keybinds    # Open Umbriel keybind cheatsheet

vpn up [COUNTRY]  # Connect ProtonVPN (default: CH)
vpn down          # Disconnect ProtonVPN
vpn status        # Show ProtonVPN status

zapret up|down|status  # Start/stop/status the zapret DPI-desync service
                       # (auto-toggled by a NetworkManager dispatcher when a VPN interface goes up/down)

vault mount    # Mount the VeraCrypt container
vault unmount  # Unmount the VeraCrypt container

helium                # Launch Helium (arguments are passed through)
helium version        # Compare installed Helium version against latest GitHub release
helium update [ver]   # Update pkgs/helium.json to a new version (fetches, verifies, hashes)

network   # Show current public IP, geo location, and active DNS resolver
triplist  # Print a small reference list of trusted IPs
fn [dir]  # List defined shell function names from *.zsh files in a directory
kitty opacity [VALUE]  # Get/set Kitty terminal background opacity
zsh history   # Open .zsh_history in the configured editor
```

All of these live in `scripts/*.zsh` and are loaded into every interactive zsh session.

## Hosts

Hosts are auto-discovered from the `hosts/` directory (see `flake.nix`).

### Host contract

Each `hosts/<name>/default.nix` exports:

```nix
{
  system = "x86_64-linux";
  username = "...";
  modules = [ ./hardware.nix ../../modules/system/... ];  # system modules to import
  configuration = { ... };                                # options, home entrypoint, stateVersion
}
```

### Adding a host

1. Create `hosts/<name>/` with `default.nix`, `hardware.nix` and `home.nix` (copy an existing host as a template).
2. Pick modules in `modules` and set the required `custom.*` options in `configuration`.
3. Build: `sudo nixos-rebuild switch --flake ~/nixos#<name>`.

No changes to `flake.nix` are needed. The directory name is the single source of truth for the hostname: `flake.nix` sets `networking.hostName` from it, because `nh` and `nixos-rebuild` pick the configuration by hostname.

### Current hosts

- **wakizashi** (`x86_64-linux`) — AMD/Nvidia desktop. Umbriel and Hyprland window managers with the Noctalia greeter, zsh shell, push-to-talk, and full unfree package access.

## Custom options

Options without a default must be set explicitly by every host that imports the module.

| Option | Module | Purpose |
|---|---|---|
| `custom.windowManager` | `windowManager.nix` | List of `hyprland` / `umbriel`; installs them and offers them at the greeter. |
| `custom.greeter.backend` | `greeter.nix` | Login greeter: `noctalia` or `tuigreet`. |
| `custom.user.shell` | `shell.nix` | Login shell: `zsh`, `bash` or `fish`. |
| `custom.unfree.mode` | `unfree.nix` | `all`, `none`, or `selected` (with `custom.unfree.packages`). |
| `custom.ptt.{enable,device,button}` | `ptt.nix` | Push-to-talk from an evdev button (see below). |
| `custom.theme.icon.{name,package}` | `modules/home/theme.nix` | GTK icon theme (Home Manager side). |

## System design notes

### Network and DNS

- DNS goes through `dnscrypt-proxy` on `127.0.0.1` / `::1` using **Anonymized DNSCrypt** (DNSCrypt only, DoH disabled), with DNSSEC, no-log and no-filter resolvers required.
- NetworkManager's DNS handling is disabled and there is **no fallback resolver on purpose**: if the proxy is down, DNS stops instead of leaking. `dns fix` is the recovery path; every downgrade (DoH, then plaintext) asks for confirmation, and the plaintext tier reverts itself after 30 minutes.
- mDNS (avahi) is disabled.
- `zapret` (DPI bypass) is stopped automatically when a `proton*` / `tun*` interface comes up and started again when it goes down (NetworkManager dispatcher).
- Passwordless `sudo` is limited to restarting `dnscrypt-proxy` and starting/stopping `zapret`.

### Push-to-talk

`custom.ptt` runs a hardened user service that reads one mouse button from `/dev/input/by-id/...` and unmutes the default audio source only while the button is held. It fails closed: the source is muted on startup, on device loss and on service stop. Changing the mute state manually from the sound settings is respected until the next button event. Access to the one input device is granted to the `ptt` group through a udev rule.

### Memory and storage

zram swap (zstd, 50% of RAM) plus an 8 GiB swapfile with random encryption at lower priority. Weekly store optimisation, periodic `nh clean` (`--keep-since 3d --keep 10`), `fstrim` enabled, systemd-boot keeping 10 generations.

### Graphics

Nvidia open kernel modules with the latest driver package from nixpkgs, paired with `linuxPackages_latest`; VA-API goes through `nvidia-vaapi-driver`.

## Externally managed configuration

These are intentionally **not** generated by Nix and live in `~/.config`:

| What | Where | Helper |
|---|---|---|
| Hyprland (Lua) | `~/.config/hypr/` | `hypr` |
| Umbriel (TOML) | `~/.config/umbriel/` | `umb` |
| Noctalia shell | managed by Noctalia itself | — |
| Kitty colors and opacity | `~/.config/kitty/themes/noctalia.conf`, `opacity.conf` | `kitty opacity` |

On a fresh install these files do not exist yet; copy them from a backup or recreate them before expecting the desktop to look the same.

## Custom packages

`pkgs/` is exposed through a flake overlay:

- **helium** — Helium browser, repackaged from the upstream `.deb`. Version and hash live in `pkgs/helium.json` and are updated with `helium update`.
- **yaruCustom** — Yaru icon theme with extra application icons taken from the `desktop-icons` flake input.

## Structure

```text
hosts/      # Host-specific configuration (system + hardware + home entrypoint), auto-discovered by flake.nix
modules/
  system/   # Reusable NixOS modules (audio, boot, networking, DNS, greeter, Nvidia, window manager, zapret, ...)
  home/     # Reusable Home Manager modules (shell, editor, theming, packages, dotfile-managed apps, ...)
assets/     # Application configuration files (fastfetch, starship, ASCII art, images) consumed by home modules
pkgs/       # Custom packages (helium browser, custom Yaru icon theme) exposed via a flake overlay
scripts/    # Zsh functions, concatenated into programs.zsh.initContent by modules/home/zsh.nix
```

## Formatting

`cfg fmt` runs `nix fmt` (`nixfmt-tree`). Run it before committing.
