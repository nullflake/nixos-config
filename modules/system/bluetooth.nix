{
  hardware.bluetooth = {
    enable = true;
    settings.General = {
      # Enable Multi Profile Specification support across multiple devices
      MultiProfile = "multiple";
      # Keep supported adapters fast-connectable, at increased power use
      FastConnectable = true;
      # Use LE device privacy mode with private addresses
      Privacy = "device";
    };
  };
}
