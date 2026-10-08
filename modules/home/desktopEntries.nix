{
  xdg.desktopEntries = {
    "dev.noctalia.Noctalia" = {
      name = "Noctalia";
      exec = "noctalia --daemon";
      icon = "noctalia";
      noDisplay = true;
    };

    # Not a launcher: gives the Android emulator window the android-studio icon.
    emulator = {
      name = "Android Emulator";
      exec = "emulator";
      icon = "android-studio";
      noDisplay = true;
      settings.StartupWMClass = "Emulator";
    };

    micro = {
      name = "Micro";
      genericName = "Text Editor";
      comment = "Edit text files in a terminal";
      exec = "kitty --class micro -e micro %F";
      icon = "micro";
      categories = [
        "Utility"
        "TextEditor"
        "Development"
      ];
      startupNotify = false;
      settings.StartupWMClass = "micro";
    };

    protontricks = {
      name = "Protontricks";
      exec = "protontricks";
      icon = "protontricks";
      noDisplay = true;
      categories = [
        "Utility"
        "Game"
      ];
    };

    steam = {
      name = "Steam";
      genericName = "PC Gaming Platform";
      comment = "Application for managing and playing games on Steam";
      exec = "steam -gamepadui -windowed";
      icon = "steam";
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

    veracrypt = {
      name = "VeraCrypt";
      exec = "veracrypt %U";
      icon = "veracrypt";
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
      categories = [
        "Network"
        "InstantMessaging"
        "Chat"
      ];
      settings.StartupWMClass = "chrome-web.whatsapp.com__-Default";
    };
  };
}
