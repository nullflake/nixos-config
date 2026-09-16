{ flakeDir, ... }:
{
  xdg.desktopEntries = {
    micro = {
      name = "Micro Text Editor";
      genericName = "Text Editor";
      comment = "Modern and intuitive terminal-based text editor";
      exec = "kitty -e micro %U";
      terminal = false;
      icon = "micro";
      type = "Application";
      categories = [
        "Utility"
        "TextEditor"
        "Development"
      ];
      mimeType = [
        "text/plain"
        "application/x-zerosize"
        "inode/x-empty"
      ];
    };

    Emulator = {
      name = "Android Emulator";
      exec = "emulator";
      icon = "android-studio";
      type = "Application";
      settings = {
        StartupWMClass = "Emulator";
      };
    };

    Gmail = {
      name = "Gmail";
      genericName = "Mail Client";
      comment = "Google Workspace Mail PWA";
      exec = "helium --app=https://mail.google.com";
      terminal = false;
      icon = "${flakeDir}/assets/images/gmail.svg";
      type = "Application";
      categories = [
        "Network"
        "Email"
      ];
      mimeType = [ "x-scheme-handler/mailto" ];
      settings = {
        StartupWMClass = "chrome-mail.google.com__-Default";
      };
    };
  };
}
