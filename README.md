# NixOS Configuration

**NixOS + Home Manager** flake for a personal desktop: per-host system and home modules, custom packages, application assets, and Zsh shell functions.

> **Not sure which command to run? Run `just`.** The `justfile` is the command reference for every shell function in this repo (`nixctl`, `cfg`, `vpn`, ...).

## Overview

- Single flake. Hosts are auto-discovered from `hosts/`, and each host picks the modules it needs.
- System configuration lives in `modules/system/`, user configuration (Home Manager) in `modules/home/`.
- Typed `custom.*` options for choices every host must make explicitly.
- Hyprland and Noctalia user configuration is managed outside Nix (see [Externally managed configuration](#externally-managed-configuration)).

## Command reference

Day-to-day operations are Zsh functions in `scripts/*.zsh`, loaded into every interactive shell. The `justfile` documents them. It only prints help and runs nothing.

```bash
just            # list all groups
just nixctl     # show one group
```

`just` works from anywhere inside `~/nixos`.

| Group | Covers |
|---|---|
| `nixctl` | Rebuilds, generations, updates, store maintenance |
| `cfg` | This repository: git, formatting, snapshots |
| `network` | Public IP, VPN, zapret |
| `wm` | Hyprland, Umbriel, Kitty |
| `misc` | Helium, VeraCrypt vault, shell helpers |

When you add, remove or rename a function in `scripts/`, update the `justfile` as well. It is maintained by hand.

## Requirements

The checkout **must live at `~/nixos`**. `flakeDir` in `flake.nix` points there so that `nh` and the shell functions can run git and write `flake.lock`. Flake evaluation is sandboxed and would otherwise resolve to the read-only store copy, which has no `.git`. To use another location, change that one line.

## First build

```bash
sudo nixos-rebuild switch --flake ~/nixos#wakizashi
```

The Noctalia cache configuration in `modules/system/nix.nix` takes effect after the first activation; the first build may compile Noctalia from source. After that, use `nixctl switch`.

## Daily workflow

```bash
cfg fmt          # nix fmt (nixfmt-tree); run before committing
nixctl switch    # build and apply
cfg push         # stage, commit, rebase, push
nixctl update    # update inputs, try Helium update, validate, build, switch
```

`nixctl update` runs, in order: `nix flake update`, an attempt at `helium update` (a failure prints a warning and continues with the current pin), `nix flake check --no-build`, then builds and switches with `nh os switch`. A failed flake update or check stops the process before switching.

## Hosts

Each `hosts/<name>/default.nix` exports:

```nix
{
  system = "x86_64-linux";
  username = "...";
  modules = [ ./hardware.nix ../../modules/system/... ];  # system modules to import
  configuration = { ... };                                # options, home entrypoint, stateVersion
}
```

`flake.nix` passes `inputs`, `username` and `flakeDir` to both system and Home Manager modules.

### Adding a host

1. Create `hosts/<name>/` with `default.nix`, `hardware.nix` and `home.nix` (copy an existing host).
2. Replace `hardware.nix` with the output of `nixos-generate-config --show-hardware-config`.
3. Pick modules in `modules` and set the required `custom.*` options in `configuration`.
4. Build: `sudo nixos-rebuild switch --flake ~/nixos#<name>`.

No changes to `flake.nix` are needed. The directory name is the single source of truth for the hostname: `flake.nix` sets `networking.hostName` from it, because `nh` and `nixos-rebuild` pick the configuration by hostname.

### Current hosts

- **wakizashi** (`x86_64-linux`): AMD/Nvidia desktop with Umbriel and Hyprland, Noctalia greeter, zsh, push-to-talk and unrestricted unfree packages.

## Custom options

Options without a default must be set by every host that imports the module.

| Option | Module | Purpose |
|---|---|---|
| `custom.windowManager` | `windowManager.nix` | List of `hyprland` / `umbriel`; installs them and offers them at the greeter. |
| `custom.greeter.backend` | `greeter.nix` | Login greeter: `noctalia` or `tuigreet`. |
| `custom.user.shell` | `shell.nix` | Login shell: `zsh`, `bash` or `fish`. |
| `custom.unfree.mode` | `unfree.nix` | `all`, `none`, or `selected` (with `custom.unfree.packages`). |
| `modules.ptt.{enable,device,button}` | `ptt.nix` | Push-to-talk from an evdev button. |
| `custom.theme.icon.{name,package}` | `modules/home/theme.nix` | GTK icon theme (Home Manager). |

## Design notes

### Network and DNS

- DNS goes through `dnscrypt-proxy` on `127.0.0.1` / `::1` using **Anonymized DNSCrypt** (DoH disabled), requiring DNSSEC, no-log and no-filter resolvers.
- NetworkManager's DNS handling is disabled and there is **no fallback resolver on purpose**: if the proxy is down, DNS stops instead of leaking.
- Avahi is disabled. When enabled with `modules.homeAssistant.enable`, Home Assistant can still announce itself on the LAN through its own zeroconf (`default_config`). Its UI is restricted to this PC by an IPv4/IPv6 firewall rule blocking non-loopback TCP access to port `8123`, including on trusted interfaces; discovery and outbound cloud connections remain enabled. The restriction requires the firewall to be enabled with the `iptables` backend. If the HTTP port is changed in Home Assistant's UI, update `port` in `modules/system/homeAssistant.nix` as well.
- `zapret` (DPI bypass) is stopped when a `proton*` / `tun*` interface comes up and started again when it goes down.
- Passwordless `sudo` is limited to starting/stopping `zapret`.

### Push-to-talk

`modules.ptt` runs a hardened user service that reads one mouse button from `/dev/input/by-id/...` and unmutes the default audio source only while the button is held. It fails closed: the source is muted on startup, on device loss and on service stop. Manual mute changes from the sound settings are respected until the next button event. A udev rule grants the `ptt` group access to that one input device.

### Shell scripts

`modules/home/zsh.nix` syntax-checks every `scripts/*.zsh` with `zsh -n` during the build and sources the checked copies, so a parse error fails the build instead of reaching the system.

## Externally managed configuration

Not generated by Nix and not stored in this repository:

| What | Where |
|---|---|
| Hyprland (Lua) | `~/.config/hypr/` |
| Noctalia shell state | `~/.local/state/noctalia/` |
| Umbriel `noctalia.toml` | `~/.config/umbriel/` (written by Noctalia, optionally included by `config.toml`) |
| Kitty theme and opacity | `~/.config/kitty/themes/noctalia.conf`, `~/.config/kitty/opacity.conf` |
| VeraCrypt container | `~/Documents/veracrypt/veracrypt` |

The other Umbriel TOML files live in `assets/umbriel/` and are linked into `~/.config/umbriel/` by Home Manager. Every `.toml` except `noctalia.toml` is picked up automatically and linked with `mkOutOfStoreSymlink`, so edits in the repository apply without a rebuild.

On a fresh install, restore or recreate these files before expecting the desktop to look the same.

## Custom packages

`pkgs/` is exposed through a flake overlay:

- **helium**: Helium browser, repackaged from the upstream `.deb`. Version and hash live in `pkgs/helium.json`.
- **yaruCustom**: Yaru icon theme with extra application icons from the `desktop-icons` flake input.

## Structure

```text
hosts/      # Per-host configuration (system + hardware + home entrypoint), auto-discovered
modules/
  system/   # NixOS modules
  home/     # Home Manager modules
assets/     # Umbriel TOML, fastfetch, starship, ASCII art, images
pkgs/       # Custom packages exposed via a flake overlay
scripts/    # Zsh functions, syntax-checked and sourced by modules/home/zsh.nix
justfile    # Command reference (help only)
```
