{
  zramSwap = {
    enable = true;
    algorithm = "zstd";
    memoryPercent = 50;
    priority = 100;
  };

  swapDevices = [
    {
      device = "/swapfile";
      size = 8192;
      priority = 10;
      randomEncryption.enable = true;
    }
  ];
}
