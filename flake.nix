{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";

    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    noctalia = {
      url = "github:noctalia-dev/noctalia/cachix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    noctalia-greeter = {
      url = "github:noctalia-dev/noctalia-greeter";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    umbriel = {
      url = "git+https://github.com/noctalia-dev/umbriel";
      inputs.nixpkgs.follows = "nixpkgs";
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
            flakeDir (toString ./.) points into the read-only Nix store
            copy of this flake, with no .git — flake evaluation is
            sandboxed, so ./. always resolves there. Right for values
            baked into the built config.

            flakeRoot is the real on-disk checkout at ~/nixos. Tools
            that run git (cfg diff/log/push) or write flake.lock
            (nixctl update, nh) need the actual git directory, so they
            must use flakeRoot instead.
          */
          flakeRoot = "/home/${host.username}/nixos";
        in
        lib.nixosSystem {
          inherit (host) system;

          specialArgs = {
            inherit inputs;
            username = host.username;
            flakeDir = toString ./.;
            inherit flakeRoot;
          };

          modules = host.modules ++ [
            {
              nixpkgs.overlays = [
                (final: prev: {
                  helium = prev.callPackage ./pkgs/helium.nix { };
                  morewaitaFiltered = prev.callPackage ./pkgs/morewaitaFiltered.nix { };
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
                flakeDir = toString ./.;
                inherit flakeRoot;
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
