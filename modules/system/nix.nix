{
  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];

  nix.optimise.automatic = true;
  nix.optimise.dates = [ "weekly" ];

  nix.settings = {
    # Limit concurrent builds and per-build parallelism to reduce memory pressure.
    max-jobs = 4;
    cores = 4;

    trusted-users = [
      "root"
    ];
    extra-substituters = [ "https://noctalia.cachix.org" ];
    extra-trusted-public-keys = [
      "noctalia.cachix.org-1:pCOR47nnMEo5thcxNDtzWpOxNFQsBRglJzxWPp3dkU4="
    ];
  };
}
