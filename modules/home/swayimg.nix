{
  programs.swayimg = {
    enable = true;
    initLua = ''
      swayimg.imagelist.adjacent = true

      swayimg.viewer.on_key("right", function()
          swayimg.viewer.open("next")
      end)

      swayimg.viewer.on_key("left", function()
          swayimg.viewer.open("prev")
      end)
    '';
  };
}
