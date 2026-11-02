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
      save-position-on-quit = true;
      resume-playback = true;
      watch-later-options = "start";
      script-opts-append = "youtube-resume-enabled=yes";
      network-timeout = 15;
      ytdl-raw-options = "force-ipv4=";
      ytdl-format = "bv[protocol^=m3u8]+ba[protocol^=m3u8]/b[protocol^=m3u8]/bv*+ba/b";
    };
  };

  xdg.configFile."mpv/scripts/youtube-resume.lua".source =
    pkgs.replaceVars ../../assets/noctalia/plugins/youtube-search/youtube-resume.lua
      {
        mkdir = "${pkgs.coreutils}/bin/mkdir";
        md5sum = "${pkgs.coreutils}/bin/md5sum";
      };
}
