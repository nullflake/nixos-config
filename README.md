# NixOS Configuration

**NixOS + Home Manager** flake configuration with per-host system/home modules, custom packages, application assets, and Zsh shell functions.

## First build

After cloning the repository, run:

```bash
sudo nixos-rebuild switch --flake ~/nixos#wakizashi
```

The Noctalia substituter and trusted public key are configured in `modules/system/nix.nix`.

Hosts are auto-discovered from the `hosts/` directory (see `flake.nix`), so adding a new machine only requires creating a new `hosts/<name>/` subdirectory — no changes to `flake.nix` are needed.

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
cfg edit        # Open configuration in Yazi
cfg tree        # Show configuration tree
cfg status      # Show Git status
cfg diff        # Show changes
cfg log         # Show commit history
cfg copy        # Copy configuration files (with path headers) to clipboard as a file
cfg copy raw    # Copy configuration files (no headers) to clipboard as text
cfg track       # Stage changes
cfg discard     # Discard uncommitted changes (reset --hard + clean -fd)
cfg fmt         # Run `nix fmt` on the flake
cfg push        # Commit, rebase onto upstream, and push
cfg rewind <commit>  # Hard reset to a commit and force-push (rewrites remote history)
```

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
umb copy [raw]  # Copy Umbriel *.toml config files to clipboard
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

helium version      # Compare installed Helium version against latest GitHub release
helium update [ver] # Update pkgs/helium.json to a new version (fetches, verifies, hashes)

network   # Show current public IP, geo location, and active DNS resolver
phone <pin> [args]  # Unlock a connected Android device via adb and start scrcpy
triplist  # Print a small reference list of trusted IPs
fn [dir]  # List defined shell function names from *.zsh files in a directory
kitty opacity [VALUE]  # Get/set Kitty terminal background opacity
zsh history   # Open .zsh_history in the configured editor
```

## Structure

```text
hosts/      # Host-specific configuration (system + hardware + home entrypoint), auto-discovered by flake.nix
modules/
  system/   # Reusable NixOS modules (audio, boot, networking, DNS, greeter, Nvidia, window manager, zapret, ...)
  home/     # Reusable Home Manager modules (shell, editor, theming, packages, dotfile-managed apps, ...)
assets/     # Application configuration files (fastfetch, starship, ASCII art, images) consumed by home modules
pkgs/       # Custom packages (helium browser, filtered MoreWaita icon theme) exposed via a flake overlay
scripts/    # Zsh functions, concatenated into programs.zsh.initContent by modules/home/zsh.nix
```

### Current hosts

- **wakizashi** (`x86_64-linux`) — AMD/Nvidia desktop. Umbriel and Hyprland window managers with the Noctalia greeter, zsh shell, push-to-talk, and full unfree package access.
