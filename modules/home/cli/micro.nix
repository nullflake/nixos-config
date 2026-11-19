{
  programs.micro = {
    enable = true;
    settings = {
      colorscheme = "noctalia";
      cursorline = false;
      hlsearch = true;
      hltrailingws = true;
      infobar = false;
      softwrap = true;
      wordwrap = true;
    };
  };

  home.sessionVariables = {
    EDITOR = "micro";
    VISUAL = "micro";
    MICRO_TRUECOLOR = "1";
  };
}
