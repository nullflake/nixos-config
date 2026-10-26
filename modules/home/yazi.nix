let
  mkOpener = run: desc: options: [
    ({ inherit run desc; } // options)
  ];
  rule = mime: use: { inherit mime use; };
in
{
  programs.yazi = {
    enable = true;
    settings = {
      preview.wrap = "yes";
      opener = {
        audio = mkOpener "mpv --no-video %s" "Play with mpv" { orphan = true; };
        edit = mkOpener "$EDITOR %s" "Edit" { block = true; };
        enter = mkOpener "ya emit cd %s1" "Enter directory" { };
        image = mkOpener "swayimg %s" "Open with swayimg" { orphan = true; };
        pdf = mkOpener "papers %s" "Open with Papers" { orphan = true; };
        video = mkOpener "mpv %s" "Play with mpv" { orphan = true; };
      };
      open.prepend_rules = [
        (rule "folder/*" "enter")
        # Media types
        (rule "application/pdf" "pdf")
        (rule "audio/*" "audio")
        (rule "image/*" "image")
        (rule "video/*" "video")
        # Text, structured data, and empty files
        (rule "application/{javascript,json,shellscript,toml,xml,yaml}" "edit")
        (rule "inode/empty" "edit")
        (rule "text/*" "edit")
      ];
    };
    keymap.mgr.prepend_keymap = [
      {
        on = [ "." ];
        run = "hidden toggle";
      }
    ];
  };
}
