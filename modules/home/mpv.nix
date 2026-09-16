{ pkgs, ... }:
{
  programs.mpv = {
    enable = true;
    scripts = [ pkgs.mpvScripts.uosc ];
    config = {
      keep-open = true;
    };
  };
}
