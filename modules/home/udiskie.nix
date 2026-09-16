{
  services.udiskie = {
    enable = true;
    settings = {
      program_options = {
        # Open mounted drives in Nautilus by default
        file_manager = "nautilus";
      };
    };
  };

  systemd.user.services.udiskie.Service = {
    Restart = "on-failure";
    RestartSec = 2;
  };
}
