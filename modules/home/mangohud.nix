# https://github.com/flightlessmango/MangoHud
{
  programs.mangohud = {
    enable = true;
    settings = {

      # display
      position = "top-left";
      font_size = 20;
      background_alpha = "0.0";

      # gpu
      gpu_stats = true;
      gpu_temp = true;

      # cpu
      cpu_stats = true;
      cpu_temp = true;

      # memory
      ram = true;

      # fps
      fps = true;
      frametime = false; # frame duration in ms
      frame_timing = false; # frame time line graph
      throttling_status = false; # GPU throttle warning

      # misc
      text_outline = true; # outline around text for readability
    };
  };
}
