# Command reference for the shell functions in scripts/*.zsh (help only)

# Show all reference guides
default:
    @just --list --unsorted

# System management (nixctl)
[group('system')]
nixctl:
    @echo "{{BOLD + BLUE}}nixctl (System Management){{NORMAL}}"
    @echo "nixctl boot              : Build and set next boot entry (nh os boot)"
    @echo "nixctl clean             : Remove old generations (defaults to keeping 1)"
    @echo "nixctl clean keep <N>    : Keep N generations (nh clean all --keep N)"
    @echo "nixctl diff              : Diff packages between current and previous generation"
    @echo "nixctl diff <gen>-<gen>  : Diff packages between two specific generations"
    @echo "nixctl find <query>      : Search Nix store for paths matching query"
    @echo "nixctl find <q> -fzf     : Interactive Nix store search via fzf; opens in Yazi"
    @echo "nixctl list              : List all system generations"
    @echo "nixctl rollback          : Switch back to the previous generation"
    @echo "nixctl switch            : Apply current configuration (nh os switch)"
    @echo "nixctl update            : Update flake inputs, try the Helium pin update, validate, then build and switch"
    @echo "nixctl verify            : Verify and repair the Nix store contents"
    @echo "ns                       : Alias for nixctl switch"

# Flake repository & Git operations (cfg)
[group('system')]
cfg:
    @echo "{{BOLD + GREEN}}cfg (Flake Repo Management){{NORMAL}}"
    @echo "cfg copy [raw]           : Concatenate all files into clipboard (file URI or text)"
    @echo "cfg discard              : Discard uncommitted changes (git reset --hard + clean)"
    @echo "cfg diff                 : Show uncommitted working tree changes"
    @echo "cfg edit                 : Open configuration repository in Yazi"
    @echo "cfg fmt                  : Format all Nix files using nix fmt"
    @echo "cfg log                  : Show one-line Git commit history"
    @echo "cfg push                 : Stage, commit (opens editor), rebase, and push"
    @echo "cfg rewind <commit>      : Hard reset branch to commit and force-push (asks for confirmation)"
    @echo "cfg status               : Show Git working tree status"
    @echo "cfg track                : Stage all changes (git add .)"
    @echo "cfg tree                 : Display repository directory tree (eza)"

# Network diagnostics, VPN & DPI bypass
[group('network')]
network:
    @echo "{{BOLD + CYAN}}Network, VPN & Zapret{{NORMAL}}"
    @echo "network                  : Display public IP, geo location, and active DNS resolver"
    @echo "vpn up [COUNTRY]         : Connect to ProtonVPN (default: CH)"
    @echo "vpn down                 : Disconnect ProtonVPN"
    @echo "vpn status               : Show ProtonVPN connection status"
    @echo "zapret up|down|status    : Start, stop, or check status of zapret DPI-desync service"
    @echo "triplist                 : Print reference list of trusted IPs (AWS, Quad9)"

# Window managers & terminal
[group('desktop')]
wm:
    @echo "{{BOLD + MAGENTA}}Window Managers (Hyprland / Umbriel){{NORMAL}}"
    @echo "hypr edit                : Open Hyprland config directory in Yazi"
    @echo "hypr tree                : Show Hyprland config tree"
    @echo "hypr copy                : Copy all Hyprland *.lua files to clipboard"
    @echo "hypr reload              : Reload Hyprland configuration"
    @echo "hypr clients             : List active Hyprland clients"
    @echo "umb edit                 : Open Umbriel config directory in Yazi"
    @echo "umb tree                 : Show Umbriel config tree"
    @echo "umb copy [raw]           : Copy Umbriel *.toml files to clipboard (file URI or text)"
    @echo "umb reload               : Reload Umbriel configuration"
    @echo "umb keybinds             : Open Umbriel keybindings cheatsheet"
    @echo "umb windows              : List active Umbriel windows"
    @echo "kitty opacity [VAL]      : Get or set Kitty background opacity (~/.config/kitty/opacity.conf)"

# Package helpers, encrypted storage & shell tools
[group('desktop')]
misc:
    @echo "{{BOLD + WHITE}}Miscellaneous Utilities{{NORMAL}}"
    @echo "helium [args]            : Launch Helium browser (arguments are passed through)"
    @echo "helium version           : Compare local Helium version with upstream release"
    @echo "helium update [version]  : Update version and hash in pkgs/helium.json"
    @echo "vault mount              : Mount VeraCrypt container to ~/Documents/veracrypt/vault"
    @echo "vault unmount            : Unmount VeraCrypt container"
    @echo "fn [dir]                 : List defined shell function names from *.zsh files"
    @echo "zsh history              : Open ~/.zsh_history in micro editor"
