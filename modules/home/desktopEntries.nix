{
  xdg.desktopEntries = {
    micro = {
      name = "Micro Text Editor";
      genericName = "Text Editor";
      comment = "Modern and intuitive terminal-based text editor";
      exec = "kitty --class micro -e micro %U";
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
      settings = {
        StartupWMClass = "micro";
      };
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

    steam = {
      name = "Steam";
      genericName = "PC Gaming Platform";
      comment = "Application for managing and playing games on Steam";
      exec = "steam -tenfoot %U";
      icon = "steam";
      terminal = false;
      type = "Application";
      categories = [
        "Network"
        "FileTransfer"
        "Game"
      ];
      mimeType = [
        "x-scheme-handler/steam"
        "x-scheme-handler/steamlink"
      ];
    };

    protontricks = {
      name = "Protontricks";
      exec = "protontricks";
      icon = "protontricks";
      terminal = false;
      type = "Application";
      categories = [
        "Utility"
        "Game"
      ];
    };

    veracrypt = {
      name = "VeraCrypt";
      exec = "veracrypt %U";
      icon = "veracrypt";
      terminal = false;
      type = "Application";
      categories = [
        "Utility"
        "Security"
      ];
    };

    whatsapp = {
      name = "WhatsApp";
      genericName = "Messaging Client";
      comment = "WhatsApp Web Client";
      exec = "helium --app=https://web.whatsapp.com";
      icon = "whatsapp";
      terminal = false;
      type = "Application";
      categories = [
        "Network"
        "InstantMessaging"
        "Chat"
      ];
      settings = {
        StartupWMClass = "chrome-web.whatsapp.com__-Default";
      };
    };
  };
}
