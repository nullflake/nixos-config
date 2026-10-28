# NixOS Configuration

Personal NixOS and Home Manager configuration based on `nixos-unstable`. One flake manages the operating system, user packages, desktop integration and shell tools, with separate modules selected by each host.

The current host is **[wakizashi](hosts/wakizashi/)**, an `x86_64-linux` AMD/Nvidia desktop running Umbriel or Hyprland with Noctalia. Its hardware, input devices and local services are configured for this machine.

Recreating the desktop also requires settings maintained outside Nix. Review the files below before setting up a new system.

## Before applying

The build commands assume an existing NixOS installation with flakes and `nix-command` enabled. For another machine, first [add a host](#adding-a-host) with its own hardware configuration.

Keep the checkout at **`~/nixos`** for the configured user. [flake.nix](flake.nix) sets `flakeDir` to `/home/<username>/nixos`; change it if using another location. The shell tools and `nh` use this writable checkout for Git operations and dependency updates. Home Manager also links Umbriel settings to files in this directory.

### Files to restore separately

These files are maintained outside the repository. Restore them from a backup or recreate them on a fresh installation.

| Files | Location |
| --- | --- |
| Hyprland configuration (Lua) | `~/.config/hypr/` |
| Noctalia settings and state | `~/.local/state/noctalia/` |
| Umbriel settings written by Noctalia | `~/.config/umbriel/noctalia.toml` |
| Kitty theme and opacity | `~/.config/kitty/themes/noctalia.conf`, `~/.config/kitty/opacity.conf` |
| VeraCrypt container used by `vault` | `~/Documents/veracrypt/veracrypt` |

Noctalia can regenerate its Umbriel and Kitty theme files. Kitty opacity is managed by `kitty opacity`. Umbriel's `noctalia.toml` is an optional include; the other Umbriel settings come from [assets/umbriel/](assets/umbriel/).

## First activation

To build and activate the configuration on `wakizashi`:

```bash
sudo nixos-rebuild switch --flake ~/nixos#wakizashi
```

This also applies the user's Home Manager configuration. The Noctalia binary cache in [nix.nix](modules/system/nix.nix) takes effect after activation, so the first build may compile Noctalia from source.

After activation, open a new Zsh session to use the shell functions below.

## Everyday use

| Command | Effect |
| --- | --- |
| `cfg fmt` | Format the Nix files with `nixfmt-tree`. |
| `cfg diff` | Review staged and unstaged changes against `HEAD`. |
| `nixctl switch` | Build and apply the configuration with `nh os switch`. |
| `nixctl boot` | Build the configuration and select it for the next boot. |
| `nixctl update` | Update dependencies, check the configuration, then build and apply it. |
| `nixctl rollback` | Activate the previous system generation. |
| `cfg push` | Stage all changes, commit, rebase on the upstream branch if configured, and push. |
| `network` | Show public IP, location, DNS resolver, active interfaces and VPN status. |

`nixctl update` updates `flake.lock`, tries to update the Helium pin in `pkgs/helium.json`, and runs `nix flake check --no-build` before calling `nh os switch`.

A Helium update failure prints a warning and keeps the current pin. A failed flake update or check stops the command before switching. Dependency changes remain in the checkout if a later step fails; review them with `cfg diff`.

### Command help

The commands above are Zsh functions loaded from [scripts/](scripts/). The [justfile](justfile) provides help for them; its recipes print reference text without performing the documented operations.

From anywhere inside `~/nixos`:

```bash
just            # list the available help topics
just nixctl     # system operations and generations
just cfg        # repository operations
just network    # network diagnostics, VPN and zapret
just wm         # Umbriel, Hyprland and Kitty
just misc       # Helium, VeraCrypt and shell helpers
```

When changing a shell function's interface, update its help in `justfile` too.

## Where to make changes

| Area | Location |
| --- | --- |
| Host identity, system imports and service settings | [hosts/wakizashi/default.nix](hosts/wakizashi/default.nix) |
| Hardware and filesystems | [hosts/wakizashi/hardware.nix](hosts/wakizashi/hardware.nix) |
| Home Manager imports and user settings | [hosts/wakizashi/home.nix](hosts/wakizashi/home.nix) |
| System services and shared options | [modules/system/](modules/system/) |
| User applications and desktop integration | [modules/home/](modules/home/), including [packages.nix](modules/home/packages.nix) |
| Umbriel settings and application assets | [assets/](assets/) |
| Shell functions | [scripts/](scripts/) |
| Custom package definitions | [pkgs/](pkgs/) |

Nix configuration changes take effect after rebuilding and activating the system. Shell scripts are checked with `zsh -n` during the build, and Zsh sources the checked copies from the Nix store.

[Flakes read Git-tracked files](https://nix.dev/concepts/flakes.html). When adding a file, run `git add <path>` before rebuilding so the flake can see it.

Existing Umbriel TOML files are linked directly to the checkout by [umbriel.nix](modules/home/umbriel.nix), except for Noctalia's `noctalia.toml`. Edit them in `assets/umbriel/` and run `umb reload` without rebuilding. Adding a new file requires activation to create its link and an entry in [config.toml](assets/umbriel/config.toml) to load it.

### Custom packages

[flake.nix](flake.nix) exposes two custom packages through an overlay:

| Package | Definition |
| --- | --- |
| `helium` | [Helium browser](pkgs/helium.nix), repackaged from the upstream amd64 `.deb`. Version and hash are stored in [helium.json](pkgs/helium.json) and updated by `helium update`. |
| `yaruCustom` | [Yaru icon theme](pkgs/yaruCustom.nix) extended with application icons from the `desktop-icons` flake input. |

## Adding a host

[flake.nix](flake.nix) discovers directories under `hosts/` automatically. Each host's `default.nix` exports `system`, `username`, `modules` and `configuration`. The directory name becomes both the flake configuration name and `networking.hostName`.

1. Copy `hosts/wakizashi/` to `hosts/<name>/`.
2. Replace `hardware.nix` with the target machine's `nixos-generate-config --show-hardware-config` output.
3. Set `username` and `system` in `default.nix`. Review system imports and settings there, then adjust the Home Manager imports and settings in `home.nix`.
4. Review the GPU modules, Umbriel output settings in `assets/umbriel/config.toml`, and device settings for push-to-talk and Home Assistant.
5. From the checkout, stage the new host with `git add hosts/<name>`.
6. Build and activate with `sudo nixos-rebuild switch --flake ~/nixos#<name>`.

The shared Umbriel assets apply to every host importing `modules/home/umbriel.nix`. Copying a host does not create a separate set of desktop assets.

### Host choices

Modules with options that have no default require an explicit value from the importing host. Set the system choices in `default.nix` and Home Manager choices in `home.nix`.

| Option | Choices or required values |
| --- | --- |
| [`custom.windowManager`](modules/system/windowManager.nix) | A list containing `hyprland`, `umbriel`, or both. |
| [`custom.greeter.backend`](modules/system/greeter.nix) | `noctalia` or `tuigreet`; this module requires exactly one selected window manager for `tuigreet`. |
| [`custom.user.shell`](modules/system/shell.nix) | `zsh`, `bash` or `fish`. The helpers documented above are loaded through Home Manager's Zsh module. |
| [`custom.unfree.mode`](modules/system/unfree.nix) | `all`, `none` or `selected`; `selected` also requires a nonempty `custom.unfree.packages` list. |
| [`custom.theme.cursor`](modules/system/theme.nix) | Theme `name` and `package`; `size` defaults to `24`. |
| [`custom.theme.icon`](modules/home/theme.nix) | Theme `name` and `package` in Home Manager. |

The flake passes `inputs`, `username` and `flakeDir` to both system and Home Manager modules.

## Service behavior

### Steam

[steam.nix](modules/system/steam.nix) adds `-gamepadui -windowed` to the Steam command so a new client starts in windowed Big Picture mode, including when launched by a game's desktop shortcut. The [desktop entry](modules/home/desktopEntries.nix) passes URLs through with `%U`.

### Networking

[network.nix](modules/system/network.nix) points the system resolver at `dnscrypt-proxy` on `127.0.0.1` and `::1`. It uses two selected dnscry.pt resolvers declaring DNSSEC, no logging and no filtering, each with a fixed relay operated by a different provider. DoH and direct certificate fallback are disabled; PQDNSCrypt is temporarily disabled due to large-response failures with version 2.1.18. NetworkManager's DNS handling is disabled, and no fallback resolver is configured. System DNS resolution depends on the proxy being available.

[zapret.nix](modules/system/zapret.nix) stops zapret when a `proton*` or `tun*` interface comes up and starts it again when that interface goes down. Its sudo rules allow the configured user to start and stop zapret without a password.

### Home Assistant

[homeAssistant.nix](modules/system/homeAssistant.nix) provides the service enabled on `wakizashi`. Local Yeelight devices are configured by IP under `modules.homeAssistant.devices`; keep LAN control enabled on the bulb and reserve its IP in the router.

The desktop launcher opens `http://homeassistant.local:8123`. A firewall rule blocks non-loopback TCP access to port `8123` over IPv4 and IPv6, including traffic from trusted interfaces. The module requires an enabled firewall with the `iptables` backend.

Avahi is disabled, but Home Assistant's own discovery and LAN announcements remain enabled through `default_config`. Outbound connections also remain available. If changing the HTTP port in Home Assistant's UI, update `port` in `homeAssistant.nix` and the URL in [desktopEntries.nix](modules/home/desktopEntries.nix) as well.

### Push-to-talk

[ptt.nix](modules/system/ptt.nix) runs a user service that controls the default microphone with one mouse button. Setting `modules.ptt.enable = true` requires a stable `/dev/input/by-id/...` device path and an evdev button code. A udev rule grants the `ptt` group access to that input device.

Pressing the button unmutes the microphone; releasing it mutes it. The service also requests mute on startup, device loss and shutdown. Manual mute changes on the same audio source are respected until the next button event. When the default source changes or is recreated, the watchdog clears that override and applies the held-button state to the new source on its next three-second check. An observed audio-service outage also clears the old source's mute baseline and override.
