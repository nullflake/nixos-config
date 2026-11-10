{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";

    /*
      Keep cached Codex 0.166.0: the affected 0.167.0 package lacks aws-lc,
      oniguruma, sqlite and zstd required by cargoSetupHook's system-lib policy
      (including AWS_LC_SYS_USE_SYSTEM=1), causing a build failure.
      https://github.com/NixOS/nixpkgs/issues/585124
      Upstream fix adds the missing buildInputs instead of disabling the policy:
      https://github.com/NixOS/nixpkgs/pull/584667
      Remove this input and its overlay once system nixpkgs includes that fix
      and its Codex binary is cached and verified here, avoiding a local rebuild.
    */
    nixpkgs-codex.url = "github:nixos/nixpkgs/f9a75f41be3a74eab55d3a7679d34ad6cc0da977";

    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    noctalia = {
      url = "github:noctalia-dev/noctalia/cachix";
    };

    noctalia-greeter = {
      url = "github:noctalia-dev/noctalia-greeter";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    umbriel = {
      url = "git+https://github.com/noctalia-dev/umbriel";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    desktop-icons = {
      url = "github:nullflake/desktop-icons";
      flake = false;
    };
  };

  outputs =
    inputs:
    let
      inherit (inputs.nixpkgs) lib;

      /*
        Auto-discover hosts by scanning the ./hosts directory.
        Adding a new host only requires creating a new subdirectory —
        no changes to this file are needed.
      */
      hosts = lib.filterAttrs (_: type: type == "directory") (builtins.readDir ./hosts);

      /*
        Build a NixOS system from a host directory.
        Each host exports: { system, username, modules, configuration }.
      */
      mkHost =
        name: _:
        let
          host = import ./hosts/${name};

          /*
            The real on-disk checkout at ~/nixos. Flake evaluation is
            sandboxed, so ./. would resolve to the read-only store copy
            with no .git. Tools that run git (cfg diff/log/push) or write
            flake.lock (nixctl update, nh) need this path instead.
          */
          flakeDir = "/home/${host.username}/nixos";
        in
        lib.nixosSystem {
          inherit (host) system;

          specialArgs = {
            inherit inputs;
            username = host.username;
            inherit flakeDir;
          };

          modules = host.modules ++ [
            {
              /*
                The directory name under ./hosts is the single source of
                truth for the hostname. nh and nixos-rebuild pick the
                configuration by hostname, so it must match the
                nixosConfigurations key.
              */
              networking.hostName = name;
            }

            {
              nixpkgs.overlays = [
                (final: prev: {
                  codex = inputs.nixpkgs-codex.legacyPackages.${prev.stdenv.hostPlatform.system}.codex;

                  helium = prev.callPackage ./pkgs/helium.nix { };

                  yaruCustom = prev.callPackage ./pkgs/yaruCustom.nix {
                    desktop-icons-src = inputs.desktop-icons;
                  };
                })
              ];
            }

            inputs.home-manager.nixosModules.home-manager

            {
              home-manager.useGlobalPkgs = true;
              home-manager.useUserPackages = true;
              home-manager.backupFileExtension = "backup";

              home-manager.extraSpecialArgs = {
                inherit inputs;
                username = host.username;
                inherit flakeDir;
              };
            }

            host.configuration
          ];
        };

      # Collect unique systems across all hosts for formatter registration.
      systems = lib.unique (lib.mapAttrsToList (name: _: (import ./hosts/${name}).system) hosts);
    in
    {
      nixosConfigurations = lib.mapAttrs mkHost hosts;

      # Run 'nix fmt' to format all Nix files in the repo.
      formatter = lib.genAttrs systems (system: inputs.nixpkgs.legacyPackages.${system}.nixfmt-tree);
    };
}
