{
  programs.starship = {
    enable = true;
    settings = fromTOML (builtins.readFile ../../assets/starship.toml);
  };
}
