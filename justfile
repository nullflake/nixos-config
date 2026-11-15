# Command reference for the shell functions in scripts/*.zsh (help only)

# Show all reference guides
default:
    @just --list --unsorted

# System management (nixctl)
[group('system')]
nixctl:
    @echo "{{BOLD + BLUE}}nixctl (System Management){{NORMAL}}"
    @printf '%-34s : %s\n' "nixctl boot" "Build and set next boot entry (nh os boot)"
    @printf '%-34s : %s\n' "nixctl clean" "Remove old generations (defaults to keeping 1)"
    @printf '%-34s : %s\n' "nixctl clean keep <N>" "Keep N generations (nh clean all --keep N)"
    @printf '%-34s : %s\n' "nixctl diff" "Diff packages between current and previous generation"
    @printf '%-34s : %s\n' "nixctl diff <gen>-<gen>" "Diff packages between two specific generations"
    @printf '%-34s : %s\n' "nixctl find <query>" "Search Nix store for paths matching query"
    @printf '%-34s : %s\n' "nixctl find <q> -fzf" "Interactive Nix store search via fzf; opens in Yazi"
    @printf '%-34s : %s\n' "nixctl list" "List all system generations"
    @printf '%-34s : %s\n' "nixctl livecheck [--details]" "Check inputs and pins; --details includes revisions and source refs"
    @printf '%-34s : %s\n' "nixctl rollback" "Switch back to the previous generation"
    @printf '%-34s : %s\n' "nixctl search <query>" "Search top-level packages + kdePackages locally (--limit N)"
    @printf '%-34s : %s\n' "  --all" "Search the entire package index"
    @printf '%-34s : %s\n' "  --stable" "Search stable (nixos-26.05) instead of the default unstable"
    @printf '%-34s : %s\n' "  --details" "Show package blocks with homepage and Nixpkgs source links"
    @printf '%-34s : %s\n' "  --set <set>" "Restrict search to a package set (e.g. python313Packages)"
    @printf '%-34s : %s\n' "  --top-level" "Search only top-level packages (--all/--set/--top-level are exclusive)"
    @printf '%-34s : %s\n' "nixctl search <query> --offline" "Search saved metadata without checking freshness"
    @printf '%-34s : %s\n' "nixctl search --status [--stable]" "Show refresh service status"
    @printf '%-34s : %s\n' "nixctl search --logs [--stable]" "Show the last 20 refresh log entries"
    @printf '%-34s : %s\n' "  Automatic update" "Each search checks the channel and waits for updates"
    @printf '%-34s : %s\n' "nixctl search --help" "Show all search options and examples"
    @printf '%-34s : %s\n' "nixctl switch" "Apply current configuration (nh os switch)"
    @printf '%-34s : %s\n' "nixctl update" "Update flake inputs, try the Helium pin update, validate, then build and switch"
    @printf '%-34s : %s\n' "nixctl verify" "Verify and repair the Nix store contents"
    @printf '%-34s : %s\n' "ns" "Alias for nixctl switch"

# Flake repository & Git operations (cfg)
[group('system')]
cfg:
    @echo "{{BOLD + GREEN}}cfg (Flake Repo Management){{NORMAL}}"
    @printf '%-34s : %s\n' "cfg copy [raw]" "Concatenate all files into clipboard (file URI or text)"
    @printf '%-34s : %s\n' "cfg discard" "Discard uncommitted changes (git reset --hard + clean)"
    @printf '%-34s : %s\n' "cfg diff" "Show staged and unstaged changes with Git colors and no pager"
    @printf '%-34s : %s\n' "cfg edit" "Open configuration repository in Yazi"
    @printf '%-34s : %s\n' "cfg fmt" "Format all Nix files using nix fmt"
    @printf '%-34s : %s\n' "cfg log" "Show one-line Git commit history"
    @printf '%-34s : %s\n' "cfg push" "Stage, commit (opens editor), rebase, and push"
    @printf '%-34s : %s\n' "cfg rewind <commit>" "Hard reset branch to commit and force-push (asks for confirmation)"
    @printf '%-34s : %s\n' "cfg status" "Show Git working tree status"
    @printf '%-34s : %s\n' "cfg track" "Stage all changes (git add .)"
    @printf '%-34s : %s\n' "cfg tree" "Display repository directory tree (eza)"

# Network diagnostics, VPN & DPI bypass
[group('network')]
network:
    @echo "{{BOLD + CYAN}}Network, VPN & Zapret{{NORMAL}}"
    @printf '%-34s : %s\n' "network" "Display public IP, location, DNS resolver, active interfaces and VPN status"
    @printf '%-34s : %s\n' "vpn up [COUNTRY]" "Connect to ProtonVPN (default: CH)"
    @printf '%-34s : %s\n' "vpn down" "Disconnect ProtonVPN"
    @printf '%-34s : %s\n' "vpn status" "Show ProtonVPN connection status"
    @printf '%-34s : %s\n' "zapret up|down|status" "Start, stop, or check status of zapret DPI-desync service"
    @printf '%-34s : %s\n' "triplist" "Print reference list of trusted IPs (AWS, Quad9)"

# Window managers & terminal
[group('desktop')]
wm:
    @echo "{{BOLD + MAGENTA}}Window Managers (Hyprland / Umbriel){{NORMAL}}"
    @printf '%-34s : %s\n' "hypr edit" "Open Hyprland config directory in Yazi"
    @printf '%-34s : %s\n' "hypr tree" "Show Hyprland config tree"
    @printf '%-34s : %s\n' "hypr copy [raw]" "Copy Hyprland *.lua files to clipboard (file URI or text)"
    @printf '%-34s : %s\n' "hypr reload" "Reload Hyprland configuration"
    @printf '%-34s : %s\n' "hypr clients" "List active Hyprland clients"
    @printf '%-34s : %s\n' "umb edit" "Open Umbriel config directory in Yazi"
    @printf '%-34s : %s\n' "umb tree" "Show Umbriel config tree"
    @printf '%-34s : %s\n' "umb copy [raw]" "Copy Umbriel *.toml files to clipboard (file URI or text)"
    @printf '%-34s : %s\n' "umb reload" "Reload Umbriel configuration"
    @printf '%-34s : %s\n' "umb keybinds" "Open Umbriel keybindings cheatsheet"
    @printf '%-34s : %s\n' "umb windows" "List active Umbriel windows"
    @printf '%-34s : %s\n' "kitty opacity [VAL]" "Get or set Kitty background opacity (~/.config/kitty/opacity.conf)"

# Package helpers, encrypted storage & shell tools
[group('desktop')]
misc:
    @echo "{{BOLD + WHITE}}Miscellaneous Utilities{{NORMAL}}"
    @printf '%-34s : %s\n' "helium [args]" "Launch Helium browser (arguments are passed through)"
    @printf '%-34s : %s\n' "helium version" "Compare local Helium version with upstream release"
    @printf '%-34s : %s\n' "helium update [version]" "Update version and hash in pkgs/helium.json"
    @printf '%-34s : %s\n' "vault mount" "Mount VeraCrypt container to ~/Documents/veracrypt/vault"
    @printf '%-34s : %s\n' "vault unmount" "Unmount VeraCrypt container"
    @printf '%-34s : %s\n' "fn [dir]" "List defined shell function names from *.zsh files"
    @printf '%-34s : %s\n' "zsh history" "Open ~/.zsh_history in micro editor"
