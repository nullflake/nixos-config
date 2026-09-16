{
  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];

  nix.optimise.automatic = true;
  nix.optimise.dates = [ "weekly" ];

  nix.settings = {
    trusted-users = [
      "root"
    ];
    extra-substituters = [ "https://noctalia.cachix.org" ];
    extra-trusted-public-keys = [
      "noctalia.cachix.org-1:pCOR47nnMEo5thcxNDtzWpOxNFQsBRglJzxWPp3dkU4="
    ];
  };
}
