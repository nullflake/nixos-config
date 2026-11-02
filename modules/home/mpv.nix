{ pkgs, ... }:
{
  programs.mpv = {
    enable = true;
    scripts = with pkgs.mpvScripts; [
      uosc
      mpris
    ];
    config = {
      keep-open = true;
    };
    /*
      Share the tested IPv4/HLS preference between the YouTube launcher and
      shell helper. Fall back to other formats when a video has no HLS stream.
    */
    profiles.youtube = {
      network-timeout = 15;
      ytdl-raw-options = "force-ipv4=";
      ytdl-format = "bv[protocol^=m3u8]+ba[protocol^=m3u8]/b[protocol^=m3u8]/bv*+ba/b";
    };
  };
}
